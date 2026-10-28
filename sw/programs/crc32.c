// Benchmark: bitwise CRC-32 (IEEE) over 4 KB, checked against the known CRC of the same data
// computed with a different (table-driven) algorithm.
#include "lib.h"

#define LEN 4096
static uint8_t buf[LEN];
static uint32_t table[256];

static uint32_t crc_bitwise(const uint8_t* p, int n) {
    uint32_t crc = 0xffffffffu;
    for (int i = 0; i < n; ++i) {
        crc ^= p[i];
        for (int b = 0; b < 8; ++b) crc = (crc >> 1) ^ (0xedb88320u & (0u - (crc & 1)));
    }
    return ~crc;
}

static uint32_t crc_table(const uint8_t* p, int n) {
    for (uint32_t i = 0; i < 256; ++i) {
        uint32_t c = i;
        for (int b = 0; b < 8; ++b) c = (c & 1) ? (c >> 1) ^ 0xedb88320u : c >> 1;
        table[i] = c;
    }
    uint32_t crc = 0xffffffffu;
    for (int i = 0; i < n; ++i) crc = table[(crc ^ p[i]) & 0xff] ^ (crc >> 8);
    return ~crc;
}

int main(void) {
    for (int i = 0; i < LEN; ++i) buf[i] = (uint8_t)(i * 31 + (i >> 3));
    perf_t s = perf_read();
    uint32_t a = crc_bitwise(buf, LEN);
    perf_report("crc32", s);
    uint32_t b = crc_table(buf, LEN);
    printf_("crc32: %08x (%s)\n", a, a == b ? "verified" : "MISMATCH");
    return a == b ? 0 : 1;
}
