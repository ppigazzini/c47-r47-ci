/* M2 regression kernel - updateShortIntegerMasks undefined shifts (config.c:706,709).
 * shortIntegerWordSize is a uint8_t the state-file and backup.cfg restores assign
 * unchecked, and the mask derivation shifts by it and by one less, so 0 shifts by
 * -1 and 65..255 shift past the width. The function is verbatim from config.c;
 * -DFIXED bounds the value as the shipped guard does at the restore sites.
 * Buggy: 2 invalid shifts. Fixed: proved safe over every uint8_t. */
#include <stdint.h>
#include "__fc_builtin.h"
#define MAX_SHORT_INTEGER_WORD_SIZE 64

static uint8_t  shortIntegerWordSize;
static uint64_t shortIntegerMask, shortIntegerSignBit;

static void updateShortIntegerMasks(void) {                 /* config.c:698 */
  if(shortIntegerWordSize == 64) {
    shortIntegerMask    = -1;
  }
  else {
    shortIntegerMask    = ((uint64_t)1 << shortIntegerWordSize) - 1;
  }
  shortIntegerSignBit = (uint64_t)1 << (shortIntegerWordSize - 1);
}

int main(void) {
  shortIntegerWordSize = (uint8_t)Frama_C_interval(0, 255); /* toUint8 of a file line */
#ifdef FIXED
  if(shortIntegerWordSize < 1 || shortIntegerWordSize > MAX_SHORT_INTEGER_WORD_SIZE) {
    shortIntegerWordSize = MAX_SHORT_INTEGER_WORD_SIZE;
  }
#endif
  updateShortIntegerMasks();
  return (int)(shortIntegerMask ^ shortIntegerSignBit);
}
