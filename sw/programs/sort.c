// Benchmark: quicksort 2,048 pseudo-random integers, then verify the result.
#include "lib.h"

#define N 2048
static int data[N];

static void quicksort(int* a, int lo, int hi) {
    while (lo < hi) {
        int p = a[(lo + hi) >> 1], i = lo, j = hi;
        while (i <= j) {
            while (a[i] < p) ++i;
            while (a[j] > p) --j;
            if (i <= j) {
                int t = a[i];
                a[i++] = a[j];
                a[j--] = t;
            }
        }
        // recurse into the smaller half, loop on the larger (bounded stack)
        if (j - lo < hi - i) { quicksort(a, lo, j); lo = i; }
        else { quicksort(a, i, hi); hi = j; }
    }
}

int main(void) {
    uint32_t x = 12345;
    for (int i = 0; i < N; ++i) {
        x ^= x << 13; x ^= x >> 17; x ^= x << 5;  // xorshift32
        data[i] = (int)(x >> 8) - (1 << 23);
    }
    perf_t s = perf_read();
    quicksort(data, 0, N - 1);
    perf_report("sort", s);
    for (int i = 1; i < N; ++i)
        if (data[i - 1] > data[i]) { puts_("sort: NOT SORTED\n"); return 1; }
    puts_("sort: verified\n");
    return 0;
}
