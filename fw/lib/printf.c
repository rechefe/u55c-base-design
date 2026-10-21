// Small printf: supports %d %i %u %x %X %p %s %c %% with optional
// '-' / '0' flags, width, and 'l' / 'll' length modifiers.
#include "u55c.h"

typedef void (*emit_fn)(char c, void *ctx);

static int format(emit_fn emit, void *ctx, const char *fmt, va_list ap)
{
    int count = 0;
#define OUT(ch) do { emit((ch), ctx); count++; } while (0)

    for (; *fmt; fmt++) {
        if (*fmt != '%') {
            OUT(*fmt);
            continue;
        }
        fmt++;
        int left = 0, zero = 0, width = 0, lng = 0;
        for (;; fmt++) {
            if (*fmt == '-') left = 1;
            else if (*fmt == '0') zero = 1;
            else break;
        }
        while (*fmt >= '0' && *fmt <= '9')
            width = width * 10 + (*fmt++ - '0');
        while (*fmt == 'l') {
            lng++;
            fmt++;
        }

        char tmp[24];
        const char *s = tmp;
        int len = 0, neg = 0;
        unsigned long long v;

        switch (*fmt) {
        case 'd': case 'i': {
            long long sv = lng >= 2 ? va_arg(ap, long long)
                         : lng == 1 ? va_arg(ap, long) : va_arg(ap, int);
            neg = sv < 0;
            v = neg ? -(unsigned long long)sv : (unsigned long long)sv;
            goto dec;
        }
        case 'u':
            v = lng >= 2 ? va_arg(ap, unsigned long long)
              : lng == 1 ? va_arg(ap, unsigned long) : va_arg(ap, unsigned int);
        dec:
            do { tmp[sizeof tmp - 1 - len++] = '0' + v % 10; v /= 10; } while (v);
            s = tmp + sizeof tmp - len;
            break;
        case 'p':
            OUT('0'); OUT('x');
            v = (uintptr_t)va_arg(ap, void *);
            width = 8; zero = 1;
            goto hex;
        case 'x': case 'X':
            v = lng >= 2 ? va_arg(ap, unsigned long long)
              : lng == 1 ? va_arg(ap, unsigned long) : va_arg(ap, unsigned int);
        hex: {
            const char *digits = *fmt == 'X' ? "0123456789ABCDEF" : "0123456789abcdef";
            do { tmp[sizeof tmp - 1 - len++] = digits[v & 15]; v >>= 4; } while (v);
            s = tmp + sizeof tmp - len;
            break;
        }
        case 's':
            s = va_arg(ap, const char *);
            if (!s) s = "(null)";
            len = (int)strlen(s);
            zero = 0;
            break;
        case 'c':
            tmp[0] = (char)va_arg(ap, int);
            len = 1;
            break;
        case '%':
            tmp[0] = '%';
            len = 1;
            break;
        default:
            OUT('%');
            if (!*fmt) return count;
            OUT(*fmt);
            continue;
        }

        int pad = width - len - neg;
        if (!left && !zero) while (pad-- > 0) OUT(' ');
        if (neg) OUT('-');
        if (!left && zero) while (pad-- > 0) OUT('0');
        for (int i = 0; i < len; i++) OUT(s[i]);
        if (left) while (pad-- > 0) OUT(' ');
    }
    return count;
#undef OUT
}

static void emit_console(char c, void *ctx)
{
    (void)ctx;
    console_putc(c);
}

struct sbuf { char *p; size_t left; };

static void emit_buf(char c, void *ctx)
{
    struct sbuf *b = ctx;
    if (b->left > 1) {
        *b->p++ = c;
        b->left--;
    }
}

int vprintf(const char *fmt, va_list ap)
{
    return format(emit_console, 0, fmt, ap);
}

int printf(const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    int n = vprintf(fmt, ap);
    va_end(ap);
    return n;
}

int vsnprintf(char *buf, size_t size, const char *fmt, va_list ap)
{
    struct sbuf b = { buf, size };
    int n = format(emit_buf, &b, fmt, ap);
    if (size)
        *b.p = 0;
    return n;
}

int snprintf(char *buf, size_t size, const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    int n = vsnprintf(buf, size, fmt, ap);
    va_end(ap);
    return n;
}
