/* M2 regression kernel - the STATISTICAL_SUMS write in restoreOneSection()
 * (saveRestoreCalcState.c:1710 at 199477075), indexed by the count the same file
 * supplies two lines earlier. statisticalSumsPointer is ONE pool block of
 * NUMBER_OF_STATISTICAL_SUMS (28) reals, allocated by initStatisticalSums()
 * (stats.c:327), and the save side writes exactly 28 (:1691 of the save path).
 * The count is the file's, and nothing bounds the index against the block.
 *
 * ASan cannot see it - the block is inside the one pool malloc. The POOL_GUARD
 * canary of docs/05-debugging.md Section 5 reports it on a state file whose
 * STATISTICAL_SUMS count is 200 or 2000: "overrun of a 420-block region",
 * 420 * 4 = 1680 = 28 * sizeof(real75). A file with the honest count of 28
 * sweeps clean, which is the negative control for the canary itself.
 *
 * A real75 is modelled as its byte footprint only; the write is what is under
 * test, not the decimal conversion. -DFIXED adds the bound the guard commit puts
 * on the write - on the write and not on the loop, which must keep reading a
 * line per claimed entry to stay aligned with the file.
 * Buggy: out-of-bounds write. Fixed: proved.
 */
#include <stdint.h>
#include <stddef.h>
#include "__fc_builtin.h"

#define NUMBER_OF_STATISTICAL_SUMS 28
#define REAL75_SIZE_IN_BYTES       60          /* one pool region: 28 * 60 = 1680 bytes = 420 blocks */
typedef struct { uint8_t bytes[REAL75_SIZE_IN_BYTES]; } real75_t;
static real75_t statisticalSums[NUMBER_OF_STATISTICAL_SUMS];
static real75_t *statisticalSumsPointer = statisticalSums;

/* stringToReal(tmpString, statisticalSumsPointer + i, &ctxtReal75): the decimal
 * parse is irrelevant here, the destination write is not. */
static void stringToReal_modelled(real75_t *dest) {
  for(size_t b = 0; b < REAL75_SIZE_IN_BYTES; b++) {
    dest->bytes[b] = (uint8_t)Frama_C_interval(0, 255);
  }
}

int main(void) {
  /* numberOfRegs = toInt16(tmpString) - the file's own "STATISTICAL_SUMS\n<count>" line */
  int16_t numberOfRegs = (int16_t)Frama_C_interval(-32768, 32767);

  if(numberOfRegs > 0) {
    for(int16_t i = 0; i < numberOfRegs; i++) {
      /* readLine(tmpString, TMP_STR_LENGTH) - one line per claimed entry, always read */
      if(statisticalSumsPointer
#ifdef FIXED
         && i < (int16_t)NUMBER_OF_STATISTICAL_SUMS
#endif
        ) {
        stringToReal_modelled(statisticalSumsPointer + i);
      }
    }
  }
  return statisticalSums[0].bytes[0];
}
