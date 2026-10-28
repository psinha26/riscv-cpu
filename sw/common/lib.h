// Tiny bare-metal support library: UART output, a small printf, and the SoC's hardware counters.
#pragma once

#include <stdarg.h>
#include <stddef.h>
#include <stdint.h>

#define MMIO(off) (*(volatile uint32_t*)(0x20000000u + (off)))
#define UART_TX       MMIO(0x00)
#define LEDS          MMIO(0x10)
#define CYCLE_LO      MMIO(0x20)
#define CYCLE_HI      MMIO(0x24)
#define INSTRET_LO    MMIO(0x28)
#define INSTRET_HI    MMIO(0x2c)
#define STALL_CYCLES  MMIO(0x30)
#define FLUSHES       MMIO(0x34)

void putchar_(char c);
void puts_(const char* s);
int printf_(const char* fmt, ...);  // supports %d %u %x %08x %s %c %% (and l modifiers)
int vprintf_(const char* fmt, va_list ap);

// Snapshot of the hardware performance counters.
typedef struct {
    uint32_t cycles, instret, stalls, flushes;
} perf_t;
perf_t perf_read(void);
// Print the counters accumulated since `start` as "name: cycles, instret, CPI, hazards".
void perf_report(const char* name, perf_t start);

void* memset(void* d, int c, size_t n);
void* memcpy(void* d, const void* s, size_t n);
size_t strlen(const char* s);
