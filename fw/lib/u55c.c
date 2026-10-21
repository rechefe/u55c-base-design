// Console, timer and small libc helpers for the U55C RISC-V firmware.
#include "u55c.h"

// ---------------------------------------------------------------- console
// Output goes to two places at once:
//   1. the log ring in SHM, which the host reads over PCIe (u55c console)
//   2. the FPGA UARTs (/dev/ttyUSB2 or ttyUSB3 on the host, 115200 8N1)
// Input comes from the host's input ring in SHM or from either UART.

void console_init(void)
{
    SHM_LOG_WR = 0;              // host notices the reset and resynchronizes
    SHM_IN_RD  = shm_read(&SHM_IN_WR);   // drop input that arrived before we started
    SHM_FW_BOOTS = SHM_FW_BOOTS + 1;
    SHM_FW_MAGIC = FW_MAGIC;
}

static void uart_putc(char c)
{
    // Wait for room. If nothing drains the UART (it always drains at 115200),
    // this blocks at most ~22 us per byte once the 256-byte FIFO is full.
    while (IO_UART_STAT & UART_TX_FULL)
        ;
    IO_UART_DATA = (uint8_t)c;
}

static void log_putc(char c)
{
    uint32_t wr = SHM_LOG_WR;
    SHM_LOG_BUF[wr % SHM_LOG_SIZE] = (uint8_t)c;
    SHM_LOG_WR = wr + 1;         // publish after the data byte is written
}

void console_putc(char c)
{
    if (c == '\n') {
        log_putc('\r');
        uart_putc('\r');
    }
    log_putc(c);
    uart_putc(c);
}

void console_write(const char *s, size_t n)
{
    while (n--)
        console_putc(*s++);
}

int console_getc(void)
{
    uint32_t rd = SHM_IN_RD;
    if (rd != shm_read(&SHM_IN_WR)) {
        int c = shm_read8(&SHM_IN_BUF[rd % SHM_IN_SIZE]);
        SHM_IN_RD = rd + 1;
        return c;
    }
    uint32_t v = IO_UART_DATA;   // reading pops one byte if present
    if (v & 0x80000000u)
        return (int)(v & 0xFF);
    return -1;
}

int console_readline(char *buf, size_t size)
{
    static size_t len;
    int c;
    while ((c = console_getc()) >= 0) {
        if (c == '\r' || c == '\n') {
            console_putc('\n');
            buf[len] = 0;
            len = 0;
            return 1;
        } else if (c == 0x08 || c == 0x7F) {     // backspace
            if (len) {
                len--;
                console_write("\b \b", 3);
            }
        } else if (len + 1 < size && c >= 0x20) {
            buf[len++] = (char)c;
            console_putc((char)c);               // echo
        }
    }
    return 0;
}

int putchar(int c)
{
    console_putc((char)c);
    return c;
}

int puts(const char *s)
{
    console_write(s, strlen(s));
    console_putc('\n');
    return 0;
}

// ---------------------------------------------------------------- time
uint64_t time_ticks(void)
{
    uint32_t hi, lo;
    do {
        hi = IO_TIME_HI;
        lo = IO_TIME_LO;
    } while (hi != IO_TIME_HI);
    return ((uint64_t)hi << 32) | lo;
}

uint32_t time_ms(void)
{
    return (uint32_t)(time_ticks() / 100000u);
}

void delay_us(uint32_t us)
{
    uint64_t end = time_ticks() + (uint64_t)us * 100u;
    while (time_ticks() < end)
        ;
}

// ---------------------------------------------------------------- libc bits
void *memset(void *d, int c, size_t n)
{
    uint8_t *p = d;
    while (n--)
        *p++ = (uint8_t)c;
    return d;
}

void *memcpy(void *d, const void *s, size_t n)
{
    uint8_t *p = d;
    const uint8_t *q = s;
    while (n--)
        *p++ = *q++;
    return d;
}

size_t strlen(const char *s)
{
    size_t n = 0;
    while (s[n])
        n++;
    return n;
}

int strcmp(const char *a, const char *b)
{
    while (*a && *a == *b) {
        a++;
        b++;
    }
    return (uint8_t)*a - (uint8_t)*b;
}

int strncmp(const char *a, const char *b, size_t n)
{
    for (; n; n--, a++, b++) {
        if (*a != *b || !*a)
            return (uint8_t)*a - (uint8_t)*b;
    }
    return 0;
}

unsigned long strtoul(const char *s, char **end, int base)
{
    unsigned long v = 0;
    while (*s == ' ')
        s++;
    if ((base == 0 || base == 16) && s[0] == '0' && (s[1] == 'x' || s[1] == 'X')) {
        s += 2;
        base = 16;
    }
    if (base == 0)
        base = 10;
    for (;; s++) {
        int d;
        if (*s >= '0' && *s <= '9') d = *s - '0';
        else if (*s >= 'a' && *s <= 'f') d = *s - 'a' + 10;
        else if (*s >= 'A' && *s <= 'F') d = *s - 'A' + 10;
        else break;
        if (d >= base)
            break;
        v = v * base + d;
    }
    if (end)
        *end = (char *)s;
    return v;
}
