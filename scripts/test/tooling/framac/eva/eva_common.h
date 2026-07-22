/* eva_common.h - shared modelling for the M1 Eva/RTE harnesses.
 * STANDALONE extracted kernels (fcfish's eva_harness.c pattern): each reproduces
 * a c43 kernel verbatim with its globals modelled, and cites the exact source
 * lines it mirrors. They do NOT include the c43 tree, so they run under Frama-C
 * anywhere. Fidelity is by line-for-line copy; the citation is the audit basis. */
#ifndef EVA_COMMON_H
#define EVA_COMMON_H
#include <stdint.h>
#include "__fc_builtin.h"   /* Frama_C_*_interval builtins */

/* short-integer engine state (c47.h:411,579,580). Real domains:
 *   shortIntegerWordSize : uint8_t, word size 1..64 (set by fnSetWordSize)
 *   shortIntegerMask     : (1<<ws)-1, low ws bits set
 *   shortIntegerSignBit  : 1<<(ws-1)                                        */
static uint8_t  shortIntegerWordSize;
static uint64_t shortIntegerMask;
static uint64_t shortIntegerSignBit;

/* Establish a consistent (wordSize, mask, signBit) triple over the given
 * word-size interval, exactly as fnSetWordSize would leave them. */
static void model_word_size(int lo, int hi) {
  shortIntegerWordSize = (uint8_t)Frama_C_interval(lo, hi);
  shortIntegerMask     = (shortIntegerWordSize >= 64)
                          ? ~0ULL : ((1ULL << shortIntegerWordSize) - 1);
  shortIntegerSignBit  = 1ULL << (shortIntegerWordSize - 1);
}
static uint64_t any_u64_upto(uint64_t hi) { return Frama_C_unsigned_long_long_interval(0, hi); }
static uint16_t any_u16(void) { return (uint16_t)Frama_C_interval(0, 65535); }
#endif
