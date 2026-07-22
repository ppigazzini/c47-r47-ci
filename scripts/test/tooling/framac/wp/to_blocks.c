/* M3 proof - the block-rounding law TO_BLOCKS (defines.h:2212):
 *   TO_BLOCKS(n) = (n + 3) >> 2      (BYTES_PER_BLOCK = 4, BPB = 2)
 * WP proves the ROUNDING LAW on the arithmetic form (n+3)/4. The macro itself
 * uses (n+3)>>2, which for unsigned operands is IDENTICAL to (n+3)/4 by ISO C
 * 6.5.7 (`>>` on unsigned is defined as the integral quotient by 2^E2) - a
 * language guarantee, not an open goal, so it needs no separate SMT proof.
 * (Confirmed empirically: forcing `>>` into WP times out both Z3 and Alt-Ergo,
 * the documented WP-bitwise limitation - REPORT-15.)
 * Prove:  frama-c -wp -wp-prover z3 -wp-rte to_blocks.c                         */
#include <stdint.h>

/*@ requires 0 <= n <= 0xFFFFFFFB;               // headroom for +3, no wrap
    assigns \nothing;
    ensures \result == (n + 3) / 4;              // == ceil(n/4)
    ensures 4 * \result >= n;                    // covers every byte
    ensures 4 * \result < n + 4;                 // by at most 3 (tight round-up)
*/
uint32_t to_blocks(uint32_t n) {
  return (n + 3) / 4;                            // == (n+3)>>2 by ISO C 6.5.7 (unsigned)
}
