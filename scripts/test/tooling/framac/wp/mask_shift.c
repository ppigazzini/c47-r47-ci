/* M3 WP proof - the mask-shift precondition M1 handed off (logicalOps/mask.c:
 * fnMaskl). MASKL computes ((1<<n)-1 & mask) << (ws - n); the second shift is
 * safe only if 1 <= ws-n <= 63. Eva's non-relational domain could not close it
 * (M1 PRECISION-WP); WP is relational and proves the guard chain implies it.
 * Prove:  frama-c -wp -wp-prover z3 -wp-rte mask_shift.c                        */
#include <stdint.h>

/*@ requires 1 <= ws <= 64;                      // fnSetWordSize domain
    requires 0 <= n;
    assigns \nothing;
*/
uint64_t maskl_shift_amount(unsigned n, unsigned ws) {
  if(n > ws) return 0;                           // mask.c:19 guard
  if(n == 0) return 0;                           //   -> shift not reached
  if(n >= ws) return ~0ULL;                      //   -> shift not reached
  /* here 1 <= n < ws <= 64, so ws-n in [1,63]: the shift below is in bounds */
  //@ assert shift_in_bounds: 1 <= ws - n <= 63;
  unsigned amount = ws - n;
  return 1ULL << amount;
}
