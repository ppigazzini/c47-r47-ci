/* M1 Eva/RTE harness - mask kernels of logicalOps/mask.c (fnMaskl/fnMaskr).
 * Audit basis: upstream ccafdfe51, mask.c:30-45 (MASKL) / :70-85 (MASKR).
 * Question: the mask build shifts by numberOfBits; is 1ULL<<numberOfBits ever
 * >= 64? Upstream added explicit guards (the ">= wordSize" branch, "avoid the
 * undefined 1ULL << 64"); this harness proves those guards are sufficient. */
#include "eva_common.h"

static uint64_t kernel_maskl(uint16_t numberOfBits) {
  uint64_t mask;
  if(numberOfBits > shortIntegerWordSize) return 0;          /* mask.c:19 guard */
  if(numberOfBits == 0) { mask = 0; }
  else if(numberOfBits >= shortIntegerWordSize) { mask = shortIntegerMask; }
  else { mask = (((1ULL << numberOfBits) - 1) & shortIntegerMask)
                 << (shortIntegerWordSize - numberOfBits); }
  return mask;
}
static uint64_t kernel_maskr(uint16_t numberOfBits) {
  uint64_t mask;
  if(numberOfBits > shortIntegerWordSize) return 0;
  if(numberOfBits == 0) { mask = 0; }
  else if(numberOfBits >= shortIntegerWordSize) { mask = shortIntegerMask; }
  else { mask = (1ULL << numberOfBits) - 1; }
  return mask;
}
int main(void) {
  model_word_size(1, 64);
  uint16_t n = any_u16();                 /* full uint16 - no precondition on n */
  volatile uint64_t sink = 0;
  sink += kernel_maskl(n);
  sink += kernel_maskr(n);
  return (int)sink;
}
