/* M1 Eva/RTE harness - pure bitwise kernels: and/or/xor/countBits.
 * Audit basis: logicalOps/{and,or,xor}.c bodies + countBits.c:34
 * (__builtin_popcountll). These are total functions on two words; the only
 * runtime-error surface is the masking and the builtin. Expect 0 alarms. */
#include "eva_common.h"
static uint64_t k_and(uint64_t a, uint64_t b){ return (a & b) & shortIntegerMask; }
static uint64_t k_or (uint64_t a, uint64_t b){ return (a | b) & shortIntegerMask; }
static uint64_t k_xor(uint64_t a, uint64_t b){ return (a ^ b) & shortIntegerMask; }
static uint64_t k_popcount(uint64_t a){ return __builtin_popcountll(a); }
int main(void) {
  model_word_size(1, 64);
  uint64_t a = any_u64_upto(shortIntegerMask), b = any_u64_upto(shortIntegerMask);
  volatile uint64_t sink = 0;
  sink += k_and(a,b); sink += k_or(a,b); sink += k_xor(a,b); sink += k_popcount(a);
  return (int)sink;
}
