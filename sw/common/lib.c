#include "lib.h"

#include <stdarg.h>

void putchar_(char c) { UART_TX = (uint32_t)(uint8_t)c; }

void puts_(const char* s) {
    while (*s) putchar_(*s++);
}

static void print_uint(uint32_t v, unsigned base, int width, char pad) {
    char buf[12];
    int n = 0;
    do {
        unsigned d = v % base;  // base is 10 or 16: libgcc's __umodsi3 on RV32I
        buf[n++] = (char)(d < 10 ? '0' + d : 'a' + d - 10);
        v /= base;
    } while (v);
    while (n < width--) putchar_(pad);
    while (n) putchar_(buf[--n]);
}

int printf_(const char* fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    int r = vprintf_(fmt, ap);
    va_end(ap);
    return r;
}

int vprintf_(const char* fmt, va_list ap) {
    for (; *fmt; ++fmt) {
        if (*fmt != '%') {
            putchar_(*fmt);
            continue;
        }
        ++fmt;
        char pad = ' ';
        int width = 0;
        if (*fmt == '0') { pad = '0'; ++fmt; }
        while (*fmt >= '0' && *fmt <= '9') width = width * 10 + (*fmt++ - '0');
        while (*fmt == 'l') ++fmt;  // long is 32 bits on RV32
        switch (*fmt) {
            case 'd': {
                int v = va_arg(ap, int);
                if (v < 0) { putchar_('-'); --width; print_uint((uint32_t)-v, 10, width, pad); }
                else print_uint((uint32_t)v, 10, width, pad);
                break;
            }
            case 'u': print_uint(va_arg(ap, uint32_t), 10, width, pad); break;
            case 'x': print_uint(va_arg(ap, uint32_t), 16, width, pad); break;
            case 's': puts_(va_arg(ap, const char*)); break;
            case 'c': putchar_((char)va_arg(ap, int)); break;
            case '%': putchar_('%'); break;
            default: putchar_('?');
        }
    }
    return 0;
}

perf_t perf_read(void) {
    perf_t p;
    p.cycles = CYCLE_LO;
    p.instret = INSTRET_LO;
    p.stalls = STALL_CYCLES;
    p.flushes = FLUSHES;
    return p;
}

void perf_report(const char* name, perf_t s) {
    perf_t e = perf_read();
    uint32_t cyc = e.cycles - s.cycles, ins = e.instret - s.instret;
    uint32_t cpi_x1000 = ins ? (uint32_t)(((uint64_t)cyc * 1000) / ins) : 0;
    printf_("%s: %u cycles, %u instructions, CPI %u.%03u, load-use stalls %u, flushes %u\n", name, cyc, ins,
            cpi_x1000 / 1000, cpi_x1000 % 1000, e.stalls - s.stalls, e.flushes - s.flushes);
}

void* memset(void* d, int c, size_t n) {
    uint8_t* p = d;
    while (n--) *p++ = (uint8_t)c;
    return d;
}

void* memcpy(void* d, const void* s, size_t n) {
    uint8_t* dp = d;
    const uint8_t* sp = s;
    while (n--) *dp++ = *sp++;
    return d;
}

size_t strlen(const char* s) {
    size_t n = 0;
    while (s[n]) ++n;
    return n;
}
