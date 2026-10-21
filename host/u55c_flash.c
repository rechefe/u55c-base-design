// u55c-flash: program the U55C configuration flash over PCIe.
//
// Talks to the AXI Quad SPI core at BAR0 + 0x40000 (the same layout AMD's
// xbflash2 expects) and drives the Micron MT25QU01G with the same command set
// xbflash2 uses: 3-byte addresses + extended address register, quad page
// program (0x32), quad output read (0x6B), and 64 KB sector erase (0xD8).
//
//   sudo ./u55c-flash [-d BDF] id
//   sudo ./u55c-flash [-d BDF] program <image.mcs|image.bin> [-a ADDR]
//   sudo ./u55c-flash [-d BDF] verify  <image.mcs|image.bin> [-a ADDR]
//   sudo ./u55c-flash [-d BDF] read    <out.bin> <ADDR> <LEN>
//   sudo ./u55c-flash [-d BDF] erase   <ADDR> <LEN>
//
// Build: make -C host        Test against a simulated flash: make -C host test
#define _GNU_SOURCE
#include <dirent.h>
#include <errno.h>
#include <signal.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#define VENDOR_ID     0x10ee
#define DEVICE_ID     0x903f
#define BAR_SIZE      0x100000
#define MAGIC_REG     0x0000
#define MAGIC         0x55C0F00Du

#define FLASH_SIZE    (128u << 20)   // MT25QU01G: 1 Gbit
#define SECTOR_SIZE   0x10000u       // 64 KB erase unit
#define PAGE_SIZE     256u
#define CHUNK         128u           // bytes per program/read transaction (as xbflash2)

// ---------------------------------------------------------------- AXI Quad SPI (PG153)
#define QSPI_BASE     0x40000
#define Q_SRR         0x40           // software reset (write 0x0A)
#define Q_CR          0x60
#define Q_SR          0x64
#define Q_DTR         0x68
#define Q_DRR         0x6C
#define Q_SSR         0x70
#define Q_RFO         0x78

#define CR_SPE        (1u << 1)
#define CR_MASTER     (1u << 2)
#define CR_TXRST      (1u << 5)
#define CR_RXRST      (1u << 6)
#define CR_MANUAL_SS  (1u << 7)
#define CR_INHIBIT    (1u << 8)

#define SR_RX_EMPTY   (1u << 0)
#define SR_TX_EMPTY   (1u << 2)
#define SR_CMD_ERR    (1u << 10)

// ---------------------------------------------------------------- MT25Q commands
#define F_WREN        0x06
#define F_RDSR        0x05
#define F_RDFSR       0x70
#define F_CLFSR       0x50
#define F_RDID        0x9F
#define F_WREAR       0xC5           // write extended address register (bank of 16 MB)
#define F_SE64K       0xD8
#define F_SE4K        0x20
#define F_QPP         0x32           // quad input fast program
#define F_QOFR        0x6B           // quad output fast read (8 dummy clocks)
#define QOFR_DUMMY    4              // dummy FIFO bytes for 0x6B in quad mode (as xbflash2)

// ---------------------------------------------------------------- register access
#ifdef FLASH_SIM
uint32_t sim_rd(uint32_t off);
void     sim_wr(uint32_t off, uint32_t v);
static inline uint32_t rd(uint32_t off)             { return sim_rd(off); }
static inline void     wr(uint32_t off, uint32_t v) { sim_wr(off, v); }
#else
static volatile uint32_t *bar;
static inline uint32_t rd(uint32_t off)             { return bar[off / 4]; }
static inline void     wr(uint32_t off, uint32_t v) { bar[off / 4] = v; }
#endif
static inline uint32_t qrd(uint32_t r)             { return rd(QSPI_BASE + r); }
static inline void     qwr(uint32_t r, uint32_t v) { wr(QSPI_BASE + r, v); }

static void die(const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    fprintf(stderr, "error: ");
    vfprintf(stderr, fmt, ap);
    fprintf(stderr, "\n");
    va_end(ap);
    exit(1);
}

static double now(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec + ts.tv_nsec * 1e-9;
}

// ---------------------------------------------------------------- SPI transaction
// Sends n bytes (n <= 256, the FIFO depth) with chip select held low, and
// returns the n bytes clocked in. rx may be NULL.
static int quiet_cmd_err;               // set while probing for 0xD8 support

static int spi_xfer(const uint8_t *tx, uint8_t *rx, unsigned n)
{
    const uint32_t base = CR_SPE | CR_MASTER | CR_MANUAL_SS;
    qwr(Q_CR, base | CR_INHIBIT | CR_TXRST | CR_RXRST);
    for (unsigned i = 0; i < n; i++)
        qwr(Q_DTR, tx[i]);
    qwr(Q_SSR, ~1u);                     // select flash 0
    qwr(Q_CR, base);                     // un-inhibit: transfer starts

    // The transfer is complete once all n bytes have been clocked back into
    // the RX FIFO (TX_EMPTY alone only means the last byte left the FIFO and
    // is still shifting out). Same rule as xbflash2's finalTransfer().
    int ok = 1;
    double t0 = now();
    unsigned got = 0;
    while (got < n) {
        uint32_t sr = qrd(Q_SR);
        if (sr & SR_CMD_ERR) break;      // command rejected: nothing will be clocked
        if (sr & SR_RX_EMPTY) {
            if (now() - t0 > 1.0) { ok = 0; goto out; }
            continue;
        }
        uint8_t b = (uint8_t)qrd(Q_DRR);
        if (rx) rx[got] = b;
        got++;
    }
out:
    qwr(Q_SSR, ~0u);                     // deselect
    qwr(Q_CR, base | CR_INHIBIT);
    if (!ok) {
        fprintf(stderr, "error: SPI transfer timeout (cmd 0x%02x, SR=0x%08x, %u/%u bytes)\n",
                tx[0], qrd(Q_SR), got, n);
        qwr(Q_SRR, 0x0A);                // clear the controller state for the next command
        return -1;
    }
    if (qrd(Q_SR) & SR_CMD_ERR) {
        if (!quiet_cmd_err)
            fprintf(stderr, "error: flash controller rejected command 0x%02x\n", tx[0]);
        qwr(Q_SRR, 0x0A);
        return -1;
    }
    return 0;
}

static int cmd1(uint8_t c)
{
    return spi_xfer(&c, NULL, 1);
}

static int read_status(uint8_t c, uint8_t *v)
{
    uint8_t tx[2] = { c, 0 }, rx[2];
    if (spi_xfer(tx, rx, 2)) return -1;
    *v = rx[1];
    return 0;
}

// Wait for program/erase to finish. MT25Q 1 Gbit is two stacked dies, so poll
// both the status register (WIP) and the flag status register (ready bit).
static int wait_ready(double timeout_s)
{
    double t0 = now();
    uint8_t sr, fsr;
    for (;;) {
        if (read_status(F_RDSR, &sr)) return -1;
        if (!(sr & 0x01)) {
            if (read_status(F_RDFSR, &fsr)) return -1;
            if (fsr & 0x80) break;
        }
        if (now() - t0 > timeout_s) {
            fprintf(stderr, "error: flash busy timeout\n");
            return -1;
        }
    }
    if (fsr & 0x32) {                    // erase / program / protection error
        fprintf(stderr, "error: flash reported failure, flag status 0x%02x%s\n", fsr,
                (fsr & 0x02) ? " (sector protected)" : "");
        cmd1(F_CLFSR);
        return -1;
    }
    return 0;
}

static int cur_bank = -1;

static int set_bank(uint32_t addr)
{
    int bank = (int)(addr >> 24);
    if (bank == cur_bank) return 0;
    uint8_t tx[2] = { F_WREAR, (uint8_t)bank };
    if (cmd1(F_WREN) || spi_xfer(tx, NULL, 2) || wait_ready(1.0)) return -1;
    cur_bank = bank;
    return 0;
}

// The extended address register must be 0 when the FPGA next configures from
// flash (it reads address 0 with 3-byte addressing first). Restore it on every
// exit path, including errors and Ctrl-C.
static volatile sig_atomic_t stop_requested;
static int device_open;

static void on_signal(int sig)
{
    (void)sig;
    stop_requested = 1;
}

static void restore_bank(void)
{
    if (!device_open) return;
    device_open = 0;
    cur_bank = -1;
    if (set_bank(0))
        fprintf(stderr, "WARNING: could not reset the flash extended address register; "
                        "run `u55c-flash id` before reloading the FPGA\n");
}

static void check_stop(void)
{
    if (stop_requested) {
        fprintf(stderr, "\ninterrupted\n");
        exit(130);                       // atexit -> restore_bank()
    }
}

static int flash_init(uint8_t id[5])
{
    qwr(Q_SRR, 0x0A);                    // reset the controller
    usleep(1000);
    // The first SPI clocks after configuration are swallowed by STARTUPE3,
    // so read the ID twice and use the second result (as xbflash2 does).
    uint8_t tx[5] = { F_RDID, 0, 0, 0, 0 }, rx[5];
    for (int i = 0; i < 2; i++)
        if (spi_xfer(tx, rx, 5)) return -1;
    memcpy(id, rx + 1, 4);
    id[4] = 0;
    cmd1(F_CLFSR);                       // clear stale error flags from earlier tools
    cur_bank = -1;                       // force a write: the register may be non-zero
    if (set_bank(0)) return -1;
    return 0;
}

static int erase_sector(uint32_t addr, uint8_t cmd)
{
    if (set_bank(addr)) return -1;
    uint8_t tx[4] = { cmd, (uint8_t)(addr >> 16), (uint8_t)(addr >> 8), (uint8_t)addr };
    if (cmd1(F_WREN) || spi_xfer(tx, NULL, 4)) return -1;
    return wait_ready(cmd == F_SE64K ? 5.0 : 2.0);
}

static int program_chunk(uint32_t addr, const uint8_t *data, unsigned n)
{
    uint8_t tx[4 + CHUNK];
    if (set_bank(addr)) return -1;
    tx[0] = F_QPP;
    tx[1] = (uint8_t)(addr >> 16);
    tx[2] = (uint8_t)(addr >> 8);
    tx[3] = (uint8_t)addr;
    memcpy(tx + 4, data, n);
    if (cmd1(F_WREN) || spi_xfer(tx, NULL, 4 + n)) return -1;
    return wait_ready(1.0);
}

static int read_chunk(uint32_t addr, uint8_t *data, unsigned n)
{
    uint8_t tx[4 + QOFR_DUMMY + CHUNK], rx[4 + QOFR_DUMMY + CHUNK];
    if (set_bank(addr)) return -1;
    memset(tx, 0, sizeof tx);
    tx[0] = F_QOFR;
    tx[1] = (uint8_t)(addr >> 16);
    tx[2] = (uint8_t)(addr >> 8);
    tx[3] = (uint8_t)addr;
    if (spi_xfer(tx, rx, 4 + QOFR_DUMMY + n)) return -1;
    memcpy(data, rx + 4 + QOFR_DUMMY, n);
    return 0;
}

// ---------------------------------------------------------------- image files
struct image {
    uint32_t base;
    uint32_t len;
    uint8_t *data;
};

static int hexval(const char *s, int n)
{
    int v = 0;
    for (int i = 0; i < n; i++) {
        char c = s[i];
        int d = (c >= '0' && c <= '9') ? c - '0' :
                (c >= 'A' && c <= 'F') ? c - 'A' + 10 :
                (c >= 'a' && c <= 'f') ? c - 'a' + 10 : -1;
        if (d < 0) return -1;
        v = v * 16 + d;
    }
    return v;
}

// Intel-hex .mcs as written by Vivado write_cfgmem (record types 00, 01, 04).
static void load_mcs(const char *path, struct image *img)
{
    FILE *f = fopen(path, "r");
    if (!f) die("cannot open %s: %s", path, strerror(errno));
    uint32_t hi = 0, lo = UINT32_MAX, top = 0;
    char line[600];
    // pass 1: find the address range
    for (int pass = 0; pass < 2; pass++) {
        rewind(f);
        hi = 0;
        int lineno = 0;
        while (fgets(line, sizeof line, f)) {
            lineno++;
            size_t l = strcspn(line, "\r\n");
            line[l] = 0;
            if (!l) continue;
            if (line[0] != ':' || l < 11) die("%s:%d: not an MCS/Intel-hex record", path, lineno);
            int cnt = hexval(line + 1, 2), off = hexval(line + 3, 4), typ = hexval(line + 7, 2);
            if (cnt < 0 || off < 0 || typ < 0 || l < (size_t)(11 + 2 * cnt))
                die("%s:%d: malformed record", path, lineno);
            if (typ == 4) {
                hi = (uint32_t)hexval(line + 9, 4) << 16;
            } else if (typ == 0) {
                uint32_t a = hi + (uint32_t)off;
                if (pass == 0) {
                    if (a < lo) lo = a;
                    if (a + cnt > top) top = a + cnt;
                } else {
                    for (int i = 0; i < cnt; i++)
                        img->data[a - lo + i] = (uint8_t)hexval(line + 9 + 2 * i, 2);
                }
            } else if (typ == 1) {
                break;
            }
        }
        if (pass == 0) {
            if (lo == UINT32_MAX) die("%s: no data records", path);
            if (top > FLASH_SIZE) die("%s: image extends past the 128 MB flash", path);
            img->base = lo;
            img->len  = top - lo;
            img->data = malloc(img->len);
            if (!img->data) die("out of memory");
            memset(img->data, 0xFF, img->len);
        }
    }
    fclose(f);
}

static void load_bin(const char *path, uint32_t base, struct image *img)
{
    FILE *f = fopen(path, "rb");
    if (!f) die("cannot open %s: %s", path, strerror(errno));
    fseek(f, 0, SEEK_END);
    long n = ftell(f);
    rewind(f);
    if (n <= 0 || (uint64_t)base + n > FLASH_SIZE) die("%s: bad size %ld for address 0x%x", path, n, base);
    img->base = base;
    img->len  = (uint32_t)n;
    img->data = malloc(n);
    if (!img->data || fread(img->data, 1, n, f) != (size_t)n) die("cannot read %s", path);
    fclose(f);
}

static void load_image(const char *path, uint32_t base, int have_base, struct image *img)
{
    size_t l = strlen(path);
    if (l > 4 && !strcasecmp(path + l - 4, ".mcs")) {
        load_mcs(path, img);
        if (have_base) die("-a cannot be used with .mcs files (they carry their own addresses)");
    } else {
        load_bin(path, base, img);
    }
}

// ---------------------------------------------------------------- high-level operations
static void progress(const char *what, uint64_t done, uint64_t total, double t0)
{
    static double last;
    double t = now();
    if (done != total && t - last < 0.5) return;
    last = t;
    fprintf(stderr, "\r%-8s %6.1f / %.1f MB  (%3d%%, %.0f s)", what,
            done / 1048576.0, total / 1048576.0, total ? (int)(100 * done / total) : 100, t - t0);
    if (done == total) fprintf(stderr, "\n");
}

static int do_erase(uint32_t addr, uint32_t len)
{
    uint32_t start = addr & ~(SECTOR_SIZE - 1);
    uint32_t end   = (addr + len + SECTOR_SIZE - 1) & ~(SECTOR_SIZE - 1);
    static int use_4k;
    double t0 = now();
    for (uint32_t a = start; a < end; a += SECTOR_SIZE) {
        quiet_cmd_err = 1;
        int rc = use_4k ? -1 : erase_sector(a, F_SE64K);
        quiet_cmd_err = 0;
        if (rc) {
            // fall back to 4 KB subsector erase if the controller rejects 0xD8
            if (!use_4k)
                fprintf(stderr, "note: 64 KB sector erase not accepted, using 4 KB erase (slower)\n");
            use_4k = 1;
            for (uint32_t s = a; s < a + SECTOR_SIZE; s += 0x1000)
                if (erase_sector(s, F_SE4K)) return -1;
        }
        progress("erase", a + SECTOR_SIZE - start, end - start, t0);
        check_stop();
    }
    return 0;
}

static int all_ff(const uint8_t *p, unsigned n)
{
    for (unsigned i = 0; i < n; i++)
        if (p[i] != 0xFF) return 0;
    return 1;
}

static int do_program(const struct image *img)
{
    double t0 = now();
    for (uint32_t off = 0; off < img->len;) {
        uint32_t a = img->base + off;
        // never cross a 256-byte page inside one program command
        uint32_t n = CHUNK - (a % CHUNK);
        if (n > img->len - off) n = img->len - off;
        if (!all_ff(img->data + off, n) && program_chunk(a, img->data + off, n)) {
            fprintf(stderr, "\nerror: program failed at 0x%08x\n", a);
            return -1;
        }
        off += n;
        progress("program", off, img->len, t0);
        check_stop();
    }
    return 0;
}

static int do_verify(const struct image *img)
{
    uint8_t buf[CHUNK];
    double t0 = now();
    for (uint32_t off = 0; off < img->len;) {
        uint32_t a = img->base + off;
        uint32_t n = CHUNK - (a % CHUNK);    // aligned: never crosses a 16 MB bank
        if (n > img->len - off) n = img->len - off;
        if (read_chunk(a, buf, n)) return -1;
        for (uint32_t i = 0; i < n; i++) {
            if (buf[i] != img->data[off + i]) {
                fprintf(stderr, "\nVERIFY FAILED at 0x%08x: flash 0x%02x, image 0x%02x\n",
                        a + i, buf[i], img->data[off + i]);
                return -1;
            }
        }
        off += n;
        progress("verify", off, img->len, t0);
        check_stop();
    }
    return 0;
}

// ---------------------------------------------------------------- device access
#ifndef FLASH_SIM
static int read_hex_file(const char *path, unsigned *v)
{
    FILE *f = fopen(path, "r");
    if (!f) return -1;
    int ok = fscanf(f, "%x", v) == 1;
    fclose(f);
    return ok ? 0 : -1;
}

static void find_device(char *bdf, size_t size)
{
    DIR *d = opendir("/sys/bus/pci/devices");
    struct dirent *e;
    int found = 0;
    if (!d) die("cannot list /sys/bus/pci/devices");
    while ((e = readdir(d))) {
        char p[512];
        unsigned ven, dev;
        if (e->d_name[0] == '.') continue;
        snprintf(p, sizeof p, "/sys/bus/pci/devices/%s/vendor", e->d_name);
        if (read_hex_file(p, &ven) || ven != VENDOR_ID) continue;
        snprintf(p, sizeof p, "/sys/bus/pci/devices/%s/device", e->d_name);
        if (read_hex_file(p, &dev) || dev != DEVICE_ID) continue;
        if (found++) die("several U55C RISC-V cards found; pick one with -d BDF");
        snprintf(bdf, size, "%.63s", e->d_name);
    }
    closedir(d);
    if (!found)
        die("no device %04x:%04x found (lspci -d %04x:). Is the image loaded and the host rebooted?",
            VENDOR_ID, DEVICE_ID, VENDOR_ID);
}

static void open_device(const char *bdf_arg)
{
    char bdf[64], p[512];
    if (!bdf_arg)
        find_device(bdf, sizeof bdf);
    else if (strchr(bdf_arg, ':') == strrchr(bdf_arg, ':'))
        snprintf(bdf, sizeof bdf, "0000:%.50s", bdf_arg);   // "01:00.0" -> "0000:01:00.0"
    else
        snprintf(bdf, sizeof bdf, "%.63s", bdf_arg);

    // make sure memory decoding is enabled (PCI command register bit 1)
    snprintf(p, sizeof p, "/sys/bus/pci/devices/%s/config", bdf);
    int cfd = open(p, O_RDWR);
    if (cfd < 0) die("cannot open %s: %s (run with sudo)", p, strerror(errno));
    uint16_t cmd;
    if (pread(cfd, &cmd, 2, 4) == 2 && !(cmd & 0x2)) {
        cmd |= 0x2;
        if (pwrite(cfd, &cmd, 2, 4) != 2) die("cannot enable memory decoding");
    }
    close(cfd);

    snprintf(p, sizeof p, "/sys/bus/pci/devices/%s/resource0", bdf);
    int fd = open(p, O_RDWR | O_SYNC);
    if (fd < 0) die("cannot open %s: %s (run with sudo)", p, strerror(errno));
    void *m = mmap(NULL, BAR_SIZE, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (m == MAP_FAILED) die("cannot map BAR0: %s", strerror(errno));
    bar = m;
    uint32_t magic = rd(MAGIC_REG);
    if (magic != MAGIC)
        die("BAR0 magic is 0x%08x, expected 0x%08x -- wrong device or image", magic, MAGIC);
    fprintf(stderr, "device %s\n", bdf);
}
#else
static void open_device(const char *bdf_arg) { (void)bdf_arg; }
#endif

static void usage(void)
{
    fprintf(stderr,
        "usage: u55c-flash [-d BDF] <command>\n"
        "  id                          read the flash JEDEC ID\n"
        "  program <img.mcs|img.bin>   erase, program and verify (.bin at -a ADDR, default 0)\n"
        "  verify  <img.mcs|img.bin>   compare flash contents with an image\n"
        "  read    <out.bin> ADDR LEN  dump flash contents\n"
        "  erase   ADDR LEN            erase the 64 KB sectors covering a range\n"
        "options: -d BDF   PCI address (default: auto-detect %04x:%04x)\n"
        "         -a ADDR  flash address for .bin images\n", VENDOR_ID, DEVICE_ID);
    exit(2);
}

int main(int argc, char **argv)
{
    const char *bdf = NULL;
    uint32_t addr = 0;
    int have_addr = 0;
    char *pos[8];
    int npos = 0;

    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "-d") && i + 1 < argc) bdf = argv[++i];
        else if (!strcmp(argv[i], "-a") && i + 1 < argc) { addr = strtoul(argv[++i], 0, 0); have_addr = 1; }
        else if (!strcmp(argv[i], "-h") || !strcmp(argv[i], "--help")) usage();
        else if (npos < 8) pos[npos++] = argv[i];
        else usage();
    }
    if (npos < 1) usage();
    const char *cmd = pos[0];

    open_device(bdf);
    signal(SIGINT, on_signal);
    signal(SIGTERM, on_signal);
    signal(SIGHUP, on_signal);
    device_open = 1;
    atexit(restore_bank);
    uint8_t id[5];
    if (flash_init(id)) die("flash controller not responding");
    fprintf(stderr, "flash JEDEC ID %02x %02x %02x %02x", id[0], id[1], id[2], id[3]);
    if (id[0] == 0x20 && id[2] == 0x21) fprintf(stderr, " (Micron MT25Q 1 Gbit)\n");
    else fprintf(stderr, " (unexpected: the U55C uses a Micron MT25QU01G, 20 BB 21)\n");
    if (id[0] == 0x00 || id[0] == 0xFF) die("no flash response -- check the image and the SPI wiring");

    int rc = 0;
    if (!strcmp(cmd, "id")) {
        printf("%02x %02x %02x %02x\n", id[0], id[1], id[2], id[3]);
    } else if (!strcmp(cmd, "program") && npos == 2) {
        struct image img;
        load_image(pos[1], addr, have_addr, &img);
        fprintf(stderr, "image %s: %u bytes at flash 0x%08x\n", pos[1], img.len, img.base);
        double t0 = now();
        rc = do_erase(img.base, img.len) || do_program(&img) || do_verify(&img);
        if (!rc) fprintf(stderr, "DONE in %.0f s: flash programmed and verified.\n", now() - t0);
    } else if (!strcmp(cmd, "verify") && npos == 2) {
        struct image img;
        load_image(pos[1], addr, have_addr, &img);
        rc = do_verify(&img);
        if (!rc) fprintf(stderr, "flash matches %s\n", pos[1]);
    } else if (!strcmp(cmd, "read") && npos == 4) {
        uint32_t a = strtoul(pos[2], 0, 0), n = strtoul(pos[3], 0, 0);
        if ((uint64_t)a + n > FLASH_SIZE) die("range past end of flash");
        uint8_t *buf = malloc(n ? n : 1);
        double t0 = now();
        for (uint32_t off = 0, k; off < n && !rc; off += k) {
            k = CHUNK - ((a + off) % CHUNK);     // aligned: never crosses a 16 MB bank
            if (k > n - off) k = n - off;
            rc = read_chunk(a + off, buf + off, k);
            progress("read", off + k, n, t0);
            check_stop();
        }
        FILE *f = fopen(pos[1], "wb");
        if (!rc && (!f || fwrite(buf, 1, n, f) != n)) die("cannot write %s", pos[1]);
        if (f) fclose(f);
    } else if (!strcmp(cmd, "erase") && npos == 3) {
        rc = do_erase(strtoul(pos[1], 0, 0), strtoul(pos[2], 0, 0));
    } else {
        usage();
    }
    restore_bank();
    return rc ? 1 : 0;
}
