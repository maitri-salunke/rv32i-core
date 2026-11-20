// util.h - replacement for riscv-tests benchmarks/common/util.h.
// setStats(1) snapshots mcycle/minstret at the start of the timed region,
// setStats(0) prints the deltas; scripts/cpi.py parses that line.
#ifndef DHRY_UTIL_H
#define DHRY_UTIL_H
#include <stdio.h>
#include "rv_csr.h"
#define debug_printf printf
static unsigned long stat_c0, stat_i0;
static void setStats(int enable) {
  unsigned long c = read_csr(mcycle), i = read_csr(minstret);
  if (enable) { stat_c0 = c; stat_i0 = i; }
  else printf("STATS mcycle=%lu minstret=%lu runs=%d\n", c - stat_c0, i - stat_i0, NUMBER_OF_RUNS);
}
#endif
