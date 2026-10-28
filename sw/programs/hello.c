// Hello world over the simulated UART, plus the hardware counters.
#include "lib.h"

int main(void) {
    perf_t start = perf_read();
    puts_("Hello, world! This is a 5-stage RV32I CPU written in SystemVerilog.\n");
    for (int i = 1; i <= 5; ++i) {
        LEDS = (uint32_t)i;
        printf_("  %d squared is %d\n", i, i * i);
    }
    perf_report("hello", start);
    return 0;
}
