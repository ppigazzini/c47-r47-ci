/* M1 Eva/RTE harness - shift & rotate kernels of logicalOps/rotateBits.c.
 * Audit basis: upstream master ccafdfe51, rotateBits.c lines cited per kernel.
 * Each kernel is copied verbatim from the fn* body (the pure part, after
 * getShiftInput has produced `w` and before setShiftResult stores it).
 * Question under test: does any shift amount reach >= 64 (undefined in C)? */
#include "eva_common.h"

/* fnRr  rotateBits.c:~150 : w = (w>>1) | ((w&1) << (wordSize-1))
   fnRrc rotateBits.c:~230 : same shape with carry.
   Safe iff shortIntegerWordSize >= 1 (else wordSize-1 underflows to a huge shift). */
static uint64_t kernel_rr(uint64_t w, uint16_t numberOfShifts) {
  for(int32_t i = 1; i <= numberOfShifts; i++) {
    w = (w >> 1) | ((w & 1) << (shortIntegerWordSize - 1));
  }
  return w;
}

/* fnLj rotateBits.c:~300 : count = clzll(w) - (64 - wordSize); w <<= count.
   Safe iff w fits the word size (w <= shortIntegerMask), so clzll(w) >= 64-ws
   and 0 <= count <= ws-1 <= 63. */
static uint64_t kernel_lj(uint64_t w) {
  uint32_t count;
  if(w == 0) { count = shortIntegerWordSize; }
  else { count = __builtin_clzll(w) - (64 - shortIntegerWordSize); w <<= count; }
  return w + count;
}

/* fnRj rotateBits.c:~325 : count = ctzll(w | ~mask); w >>= count. */
static uint64_t kernel_rj(uint64_t w) {
  uint32_t count;
  if(w == 0) { count = shortIntegerWordSize; }
  else { count = __builtin_ctzll(w | ~shortIntegerMask); w >>= count; }
  return w + count;
}

/* fnAsr rotateBits.c:47 : loop of (w>>1)|sign. Shifts are by 1 - trivially safe;
   included to confirm the loop bound over numberOfShifts raises no alarm. */
static uint64_t kernel_asr(uint64_t w, uint16_t numberOfShifts) {
  uint64_t sign = w & shortIntegerSignBit;
  for(int32_t i = 1; i <= numberOfShifts; i++) { w = (w >> 1) | sign; }
  return w;
}

int main(void) {
  /* Preconditions AS STATED: word size in its real 1..64 domain, and the
     register value fits the word size. With these, every kernel must be
     alarm-free. Widen either interval below to see the alarm reappear. */
  model_word_size(1, 64);
  uint64_t w  = Frama_C_interval_ull(0, shortIntegerMask);   /* w <= mask     */
  uint16_t ns = (uint16_t)Frama_C_interval(0, 65535);        /* full uint16   */

  volatile uint64_t sink = 0;
  sink += kernel_rr(w, ns);
  sink += kernel_lj(w);
  sink += kernel_rj(w);
  sink += kernel_asr(w, ns);
  return (int)sink;
}
