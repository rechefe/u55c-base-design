// U55C RISC-V firmware support library: register map and console API.
// The same SHM layout is used by host/u55c.py -- keep the two in sync.
#ifndef U55C_H
#define U55C_H

#include <stdint.h>
#include <stddef.h>
#include <stdarg.h>

#define REG32(addr) (*(volatile uint32_t *)(uintptr_t)(addr))

// ---------------------------------------------------------------- memory map
#define RAM_BASE      0x00000000u   // 256 KB program RAM (code, data, stack)
#define RAM_SIZE      0x00040000u
#define SHM_BASE      0x10000000u   // 16 KB RAM shared with the host (BAR0 + 0x10000)
#define IO_BASE       0x20000000u

// ---------------------------------------------------------------- IO registers
#define IO_UART_DATA  REG32(IO_BASE + 0x00)  // W: send byte  R: bit31 valid, [7:0] byte
#define IO_UART_STAT  REG32(IO_BASE + 0x04)  // bit0 TX full, bit1 RX avail, bit2 TX idle
#define IO_TIME_LO    REG32(IO_BASE + 0x08)  // 100 MHz free-running counter
#define IO_TIME_HI    REG32(IO_BASE + 0x0C)
#define IO_LED        REG32(IO_BASE + 0x10)  // [5:0] QSFP LEDs
#define IO_CLK_HZ     REG32(IO_BASE + 0x14)  // 100000000
#define IO_SIM_EXIT   REG32(IO_BASE + 0xF0)  // simulation only

#define UART_TX_FULL  (1u << 0)
#define UART_RX_AVAIL (1u << 1)
#define UART_TX_IDLE  (1u << 2)

// ---------------------------------------------------------------- shared memory (SHM)
// Offsets are relative to SHM_BASE (CPU) or BAR0 + 0x10000 (host).
#define SHM_MBOX(n)   REG32(SHM_BASE + 0x00 + 4 * (n))  // 8 mailbox words, n = 0..7
#define SHM_LOG_WR    REG32(SHM_BASE + 0x20)  // bytes written to the log ring (firmware)
#define SHM_LOG_RD    REG32(SHM_BASE + 0x24)  // bytes consumed by the host (host, informational)
#define SHM_IN_WR     REG32(SHM_BASE + 0x28)  // bytes written to the input ring (host)
#define SHM_IN_RD     REG32(SHM_BASE + 0x2C)  // bytes consumed by the firmware (firmware)
#define SHM_FW_MAGIC  REG32(SHM_BASE + 0x30)  // FW_MAGIC once the console is initialized
#define SHM_FW_BOOTS  REG32(SHM_BASE + 0x34)  // incremented at every firmware start

#define SHM_IN_BUF    ((volatile uint8_t *)(SHM_BASE + 0x1000))
#define SHM_IN_SIZE   0x1000u
#define SHM_LOG_BUF   ((volatile uint8_t *)(SHM_BASE + 0x2000))
#define SHM_LOG_SIZE  0x2000u

#define FW_MAGIC      0xC0DE0001u

// Read SHM data the host may be writing at the same moment. The SHM is a
// dual-clock block RAM: a read that collides with a write from the other port
// returns undefined data, so read until two consecutive reads agree.
static inline uint32_t shm_read(volatile uint32_t *p)
{
    uint32_t a, b;
    do {
        a = *p;
        b = *p;
    } while (a != b);
    return a;
}

static inline uint8_t shm_read8(volatile uint8_t *p)
{
    uint8_t a, b;
    do {
        a = *p;
        b = *p;
    } while (a != b);
    return a;
}

// ---------------------------------------------------------------- API
void     console_init(void);
void     console_putc(char c);           // log ring + UART
void     console_write(const char *s, size_t n);
int      console_getc(void);             // next input byte (ring or UART), -1 if none
int      console_readline(char *buf, size_t size); // non-blocking line editor; 1 = line ready

uint64_t time_ticks(void);               // 100 MHz ticks since FPGA configuration
uint32_t time_ms(void);
void     delay_us(uint32_t us);

int  printf(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
int  vprintf(const char *fmt, va_list ap);
int  snprintf(char *buf, size_t size, const char *fmt, ...) __attribute__((format(printf, 3, 4)));
int  vsnprintf(char *buf, size_t size, const char *fmt, va_list ap);
int  puts(const char *s);
int  putchar(int c);

// small libc replacements (no newlib)
void  *memset(void *d, int c, size_t n);
void  *memcpy(void *d, const void *s, size_t n);
size_t strlen(const char *s);
int    strcmp(const char *a, const char *b);
int    strncmp(const char *a, const char *b, size_t n);
unsigned long strtoul(const char *s, char **end, int base);

#endif
