/*
 * CoreMark port for the RV32I SoC (based on EEMBC's barebones port, Apache License 2.0).
 *
 * Ticks are clock cycles from the SoC's cycle counter, with EE_TICKS_PER_SEC set to a nominal
 * 1 MHz so that "Iterations/Sec" reads as CoreMark/MHz. A simulated run is far shorter than the
 * 10 seconds the official run rules require, so CoreMark prints its "must execute for at least
 * 10 secs" notice; the CRC checks still validate that the work was done correctly. Results are
 * a simulation measurement, not an official CoreMark score.
 */
#include "coremark.h"
#include "lib.h"

#if VALIDATION_RUN
volatile ee_s32 seed1_volatile = 0x3415;
volatile ee_s32 seed2_volatile = 0x3415;
volatile ee_s32 seed3_volatile = 0x66;
#endif
#if PERFORMANCE_RUN
volatile ee_s32 seed1_volatile = 0x0;
volatile ee_s32 seed2_volatile = 0x0;
volatile ee_s32 seed3_volatile = 0x66;
#endif
#if PROFILE_RUN
volatile ee_s32 seed1_volatile = 0x8;
volatile ee_s32 seed2_volatile = 0x8;
volatile ee_s32 seed3_volatile = 0x8;
#endif
volatile ee_s32 seed4_volatile = ITERATIONS;
volatile ee_s32 seed5_volatile = 0;

#define EE_TICKS_PER_SEC 1000000u  /* nominal 1 MHz: ticks are cycles */

static CORETIMETYPE start_time_val, stop_time_val;
static perf_t start_perf;

void start_time(void) {
    start_perf = perf_read();
    start_time_val = start_perf.cycles;
}

void stop_time(void) { stop_time_val = CYCLE_LO; }

CORE_TICKS get_time(void) { return (CORE_TICKS)(stop_time_val - start_time_val); }

secs_ret time_in_secs(CORE_TICKS ticks) { return (secs_ret)(ticks / EE_TICKS_PER_SEC); }

ee_u32 default_num_contexts = 1;

void portable_init(core_portable *p, int *argc, char *argv[]) {
    (void)argc;
    (void)argv;
    if (sizeof(ee_ptr_int) != sizeof(ee_u8 *)) ee_printf("ERROR! ee_ptr_int must hold a pointer!\n");
    if (sizeof(ee_u32) != 4) ee_printf("ERROR! ee_u32 must be 32 bits!\n");
    p->portable_id = 1;
}

void portable_fini(core_portable *p) {
    p->portable_id = 0;
    /* Precise CoreMark/MHz with integer math: iterations * 1e6 / cycles, 3 decimals. */
    CORE_TICKS cycles = get_time();
    uint64_t milli = ((uint64_t)ITERATIONS * 1000000000ull) / cycles;
    ee_printf("CoreMark/MHz     : %u.%03u (%u iterations in %u cycles, simulation)\n", (unsigned)(milli / 1000),
              (unsigned)(milli % 1000), (unsigned)ITERATIONS, (unsigned)cycles);
    perf_report("coremark (timed region)", start_perf);
}

int ee_printf(const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    int r = vprintf_(fmt, ap);
    va_end(ap);
    return r;
}
