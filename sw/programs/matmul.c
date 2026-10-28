// Benchmark: 24x24 integer matrix multiply, verified against a second ordering of the loops.
// RV32I has no multiply instruction, so every product goes through libgcc's software __mulsi3.
#include "lib.h"

#define N 24
static int A[N][N], B[N][N], C[N][N];

int main(void) {
    for (int i = 0; i < N; ++i)
        for (int j = 0; j < N; ++j) {
            A[i][j] = (i * 7 + j * 3) % 17 - 8;
            B[i][j] = (i * 5 + j * 11) % 13 - 6;
        }
    perf_t s = perf_read();
    for (int i = 0; i < N; ++i)
        for (int j = 0; j < N; ++j) {
            int acc = 0;
            for (int k = 0; k < N; ++k) acc += A[i][k] * B[k][j];
            C[i][j] = acc;
        }
    perf_report("matmul", s);
    // verify with i-k-j ordering into a scratch row
    for (int i = 0; i < N; ++i) {
        int row[N];
        for (int j = 0; j < N; ++j) row[j] = 0;
        for (int k = 0; k < N; ++k)
            for (int j = 0; j < N; ++j) row[j] += A[i][k] * B[k][j];
        for (int j = 0; j < N; ++j)
            if (row[j] != C[i][j]) { puts_("matmul: MISMATCH\n"); return 1; }
    }
    puts_("matmul: verified\n");
    return 0;
}
