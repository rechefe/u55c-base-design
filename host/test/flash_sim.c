// Software model of the AXI Quad SPI core (register level) and a Micron
// MT25QU01G flash, linked into u55c-flash for `make -C host test`.
//
// The flash contents live in a file (SIM_FLASH_FILE) so several tool runs can
// share one "chip". SIM_REJECT_D8=1 makes the controller reject 64 KB sector
// erase, to exercise the 4 KB fallback.
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

#define FLASH_SIZE (128u << 20)

static uint8_t *mem;
static uint8_t txf[256], rxf[1024];
static unsigned txn, txh, rxh, rxt;     // TX FIFO holds txf[txh..txn)
static int inflight = -1;               // byte in the shift register, or -1
static uint32_t cr = 0x180, ssr = ~0u, sr_err;
static int cs_low, first_xfer = 1;

// flash state
static uint8_t  tr[600];                 // bytes of the current CS-low transaction
static unsigned trn;
static int      wel, busy;
static uint8_t  ear, fsr = 0x80;

static void init(void)
{
    if (mem) return;
    const char *path = getenv("SIM_FLASH_FILE");
    if (!path) { fprintf(stderr, "SIM_FLASH_FILE not set\n"); exit(3); }
    int fd = open(path, O_RDWR | O_CREAT, 0644);
    off_t sz = lseek(fd, 0, SEEK_END);
    if (sz != FLASH_SIZE) {
        ftruncate(fd, FLASH_SIZE);
        mem = mmap(0, FLASH_SIZE, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
        memset(mem, 0xFF, FLASH_SIZE);
    } else {
        mem = mmap(0, FLASH_SIZE, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    }
}

static uint32_t a24(void) { return ((uint32_t)ear << 24) | (tr[1] << 16) | (tr[2] << 8) | tr[3]; }

// response byte for the byte just shifted in at position trn-1
static uint8_t respond(void)
{
    unsigned i = trn - 1;
    if (first_xfer) return 0x00;         // STARTUPE3 swallows the first clocks
    switch (tr[0]) {
    case 0x9F: { static const uint8_t id[] = { 0xFF, 0x20, 0xBB, 0x21, 0x10, 0x44 };
                 return i < sizeof id ? id[i] : 0; }
    case 0x05: return (busy ? 1 : 0) | (wel ? 2 : 0);
    case 0x70: return busy ? (fsr & 0x7F) : (fsr | 0x80);
    case 0x6B: return i >= 8 ? mem[(a24() + (i - 8)) % FLASH_SIZE] : 0xFF;
    default:   return 0xFF;
    }
}

static void end_transaction(void)
{
    if (first_xfer) { first_xfer = 0; trn = 0; return; }
    if (!trn) return;
    uint8_t c = tr[0];
    if (busy && c != 0x05 && c != 0x70) {
        fprintf(stderr, "SIM: command 0x%02x issued while busy\n", c);
        exit(4);
    }
    if (busy) busy--;                    // stay busy for a few status polls
    switch (c) {
    case 0x06: wel = 1; break;
    case 0x50: fsr = 0x80; break;
    case 0xC5: if (wel) ear = tr[1] & 7; wel = 0; break;
    case 0xD8: case 0x20: {
        if (!wel) { fsr |= 0x20; break; }
        uint32_t sz = c == 0xD8 ? 0x10000 : 0x1000;
        uint32_t a = a24() & ~(sz - 1);
        memset(mem + a, 0xFF, sz);
        wel = 0; busy = 3;
        break;
    }
    case 0x32: {
        if (!wel) { fsr |= 0x10; break; }
        uint32_t a = a24();
        for (unsigned i = 4; i < trn; i++) {
            uint32_t p = (a & ~0xFFu) | ((a + i - 4) & 0xFF);   // wraps inside the page
            mem[p] &= tr[i];
        }
        wel = 0; busy = 2;
        break;
    }
    default: break;
    }
    trn = 0;
}

static int enabled(void) { return (cr & 0x2) && !(cr & 0x100) && ssr != ~0u; }

// Like the real core, a byte leaves the TX FIFO into the shift register first
// and reaches the RX FIFO one register access later. TX_EMPTY can therefore be
// set while the last byte is still shifting out.
static void step(void)
{
    if (inflight >= 0) {
        if (trn < sizeof tr) tr[trn++] = (uint8_t)inflight;
        rxf[rxt++ % sizeof rxf] = respond();
        inflight = -1;
    }
    if (enabled() && txh < txn) {
        if (!cs_low) { cs_low = 1; trn = 0; }
        if (getenv("SIM_REJECT_D8") && trn == 0 && txf[txh] == 0xD8) {
            sr_err = 1 << 10;
            txh = txn = 0;
            return;
        }
        inflight = txf[txh++];
        if (txh == txn) txh = txn = 0;
    }
}

static void run(void) { step(); }

uint32_t sim_rd(uint32_t off)
{
    init();
    step();
    if (off == 0) return 0x55C0F00D;
    switch (off - 0x40000) {
    case 0x60: return cr;
    case 0x64: return (rxh == rxt ? 1 : 0) | (txn == txh ? 4 : 0) | (txn >= 256 ? 8 : 0) | sr_err;
    case 0x6C: return rxh == rxt ? 0 : rxf[rxh++ % sizeof rxf];
    case 0x70: return ssr;
    case 0x74: return txn - txh ? txn - txh - 1 : 0;
    case 0x78: return rxt - rxh ? rxt - rxh - 1 : 0;
    default:   return 0;
    }
}

void sim_wr(uint32_t off, uint32_t v)
{
    init();
    switch (off - 0x40000) {
    case 0x40:
        if (v == 0x0A) { cr = 0x180; ssr = ~0u; txn = txh = 0; inflight = -1; rxh = rxt = 0; sr_err = 0; cs_low = 0; trn = 0; }
        break;
    case 0x60:
        cr = v & 0x3FF;
        if (v & 0x20) txn = txh = 0;
        if (v & 0x40) rxh = rxt = 0;
        cr &= ~0x60u;
        run();
        break;
    case 0x68:
        if (txn < 256) txf[txn++] = (uint8_t)v;
        run();
        break;
    case 0x70:
        if (v == ~0u && cs_low) {
            if (inflight >= 0 || txh < txn) {
                fprintf(stderr, "SIM: chip select raised while a byte was still shifting\n");
                exit(5);
            }
            cs_low = 0;
            ssr = v;
            end_transaction();
        }
        ssr = v;
        run();
        break;
    default: break;
    }
}
