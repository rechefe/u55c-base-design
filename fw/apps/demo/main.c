// Demo firmware: prints a banner and a heartbeat, runs a tiny command shell
// on the console, and serves mailbox requests from the host.
#include "u55c.h"

// Mailbox protocol (host side: `u55c mbox call CMD [ARG1 [ARG2]]`):
//   host writes arguments to MBOX1..MBOX7, then the command to MBOX0;
//   firmware runs it, writes the result to MBOX1 and clears MBOX0 (= done).
enum {
    MBOX_CMD_PING = 1,   // MBOX1 = MBOX1 + 1
    MBOX_CMD_ADD  = 2,   // MBOX1 = MBOX1 + MBOX2
    MBOX_CMD_PEEK = 3,   // MBOX1 = *(uint32_t *)MBOX1
    MBOX_CMD_TIME = 4,   // MBOX1 = milliseconds since FPGA configuration
};

static uint32_t heartbeat_s = 10;

static void print_uptime(void)
{
    uint32_t ms = time_ms();
    printf("[%5u.%03u] ", (unsigned)(ms / 1000), (unsigned)(ms % 1000));
}

static void mailbox_poll(void)
{
    uint32_t cmd = SHM_MBOX(0);
    if (!cmd)
        return;
    uint32_t a = SHM_MBOX(1), b = SHM_MBOX(2), r;
    switch (cmd) {
    case MBOX_CMD_PING: r = a + 1; break;
    case MBOX_CMD_ADD:  r = a + b; break;
    case MBOX_CMD_PEEK: r = REG32(a & ~3u); break;
    case MBOX_CMD_TIME: r = time_ms(); break;
    default:            r = 0xFFFFFFFFu; break;
    }
    SHM_MBOX(1) = r;
    SHM_MBOX(0) = 0;     // done -- must be written last
}

static void help(void)
{
    puts("commands:\n"
         "  help              this text\n"
         "  uptime            time since FPGA configuration\n"
         "  hb <seconds>      heartbeat period (0 = off)\n"
         "  mbox              show the 8 mailbox registers\n"
         "  peek <addr>       read a 32-bit word\n"
         "  poke <addr> <val> write a 32-bit word\n"
         "  led <val>         set the 6 QSFP LEDs\n"
         "  echo <text>       print text\n"
         "  trap              execute an illegal instruction (tests trap reporting)");
}

static const char *arg(const char *s)
{
    while (*s && *s != ' ') s++;
    while (*s == ' ') s++;
    return s;
}

static void run_command(const char *line)
{
    char *end;
    if (!line[0]) {
        return;
    } else if (!strcmp(line, "help")) {
        help();
    } else if (!strcmp(line, "uptime")) {
        print_uptime();
        printf("up, boot #%u\n", (unsigned)SHM_FW_BOOTS);
    } else if (!strncmp(line, "hb", 2)) {
        heartbeat_s = strtoul(arg(line), 0, 0);
        printf("heartbeat every %u s\n", (unsigned)heartbeat_s);
    } else if (!strcmp(line, "mbox")) {
        for (int i = 0; i < 8; i++)
            printf("MBOX%d = 0x%08x\n", i, (unsigned)SHM_MBOX(i));
    } else if (!strncmp(line, "peek", 4)) {
        uint32_t a = strtoul(arg(line), 0, 0) & ~3u;
        printf("[0x%08x] = 0x%08x\n", (unsigned)a, (unsigned)REG32(a));
    } else if (!strncmp(line, "poke", 4)) {
        uint32_t a = strtoul(arg(line), &end, 0) & ~3u;
        uint32_t v = strtoul(end, 0, 0);
        REG32(a) = v;
        printf("[0x%08x] <= 0x%08x\n", (unsigned)a, (unsigned)v);
    } else if (!strncmp(line, "led", 3)) {
        IO_LED = strtoul(arg(line), 0, 0);
    } else if (!strncmp(line, "echo", 4)) {
        puts(arg(line));
    } else if (!strcmp(line, "trap")) {
        puts("executing an illegal instruction; u55c status will show TRAP");
        __asm__ volatile(".word 0x00000000");
    } else {
        printf("unknown command '%s' (try 'help')\n", line);
    }
}

int main(void)
{
    console_init();
    puts("");
    puts("=== U55C PicoRV32 demo firmware ===");
    printf("boot #%u, CPU clock %u Hz, RAM %u KB\n",
           (unsigned)SHM_FW_BOOTS, (unsigned)IO_CLK_HZ, (unsigned)(RAM_SIZE / 1024));
    puts("type 'help' and press Enter");
    printf("> ");

    char line[96];
    uint32_t next_hb = time_ms() + heartbeat_s * 1000;
    uint32_t beats = 0;

    for (;;) {
        mailbox_poll();

        if (console_readline(line, sizeof line)) {
            run_command(line);
            printf("> ");
        }

        if (heartbeat_s && (int32_t)(time_ms() - next_hb) >= 0) {
            next_hb += heartbeat_s * 1000;
            print_uptime();
            printf("heartbeat %u\n", (unsigned)++beats);
        }
    }
}
