/* M2 regression kernel - the hexDump body read in restoreStateValue()
 * (saveRestoreBackup.c:689-694). saveStateValue() writes each dump line as
 * "%05x  " then 32 groups of "%02x ", so the two hex digits of byte b sit at
 * offset 7 + 3*b. The reader took those offsets on trust: it set v to
 * paramCurrent->param + 7 and walked 96 bytes forward whatever the line's real
 * length, and the lines come from the file. ASan on 3c84890a1, one globalFlags
 * dump line replaced by the two characters "ab": heap-buffer-overflow read
 * 4 bytes after the 3-byte region malloc'd for that line.
 *
 * restoreCalc() allocates each line with malloc(strlen(line) + 1) (:793), so the
 * buffer here is sized to exactly that for a short line rather than to the
 * 139-byte line a full dump would have produced - Eva cannot model a
 * variable-size allocation, and a buffer sized to the maximum would hide the
 * very read under test. The length chosen, 10, is past the fixed offset 7 but
 * short of the 103 the loop walks to, so the buggy mode reads one legal digit
 * pair before leaving the object: a length of 2 would fail on the first read and
 * never exercise the loop. Contents are arbitrary printable bytes.
 * -DFIXED bounds the read by the line's own length, as the shipped fix does.
 * Buggy: >=1 out-of-bounds read. Fixed: proved. */
#include <stdint.h>
#include <stddef.h>
#include "__fc_builtin.h"

#define BYTES_PER_DUMP_LINE 32
#define DUMP_LINE_LENGTH    10                      /* strlen of the short line */

static uint8_t line[DUMP_LINE_LENGTH + 1];          /* malloc(strlen + 1), saveRestoreBackup.c:793 */
static uint8_t out[BYTES_PER_DUMP_LINE];

int main(void) {
  for(size_t k = 0; k < DUMP_LINE_LENGTH; k++) {
    line[k] = (uint8_t)Frama_C_interval(0x20, 0x7e);
  }
  line[DUMP_LINE_LENGTH] = 0;

  uint8_t hi, lo;

#ifdef FIXED
  const size_t lineLength = DUMP_LINE_LENGTH;       /* strlen(paramCurrent->param) */
  size_t digit = 7;
  for(uint32_t count = 0; count < BYTES_PER_DUMP_LINE; count++) {
    if(digit + 1 >= lineLength) {                   /* the line ends before this digit pair */
      break;
    }
    hi = line[digit]     - (line[digit]     <= '9' ? '0' : 'a' - 10);
    lo = line[digit + 1] - (line[digit + 1] <= '9' ? '0' : 'a' - 10);
    digit += 3;
    out[count] = (hi << 4) | lo;
  }
#else
  uint8_t *v = line + 7;                            /* saveRestoreBackup.c:689 */
  for(uint32_t count = 0; count < BYTES_PER_DUMP_LINE; count++) {
    hi = *v - (*v <= '9' ? '0' : 'a' - 10);         /* saveRestoreBackup.c:692 */
    v++;
    lo = *v - (*v <= '9' ? '0' : 'a' - 10);         /* saveRestoreBackup.c:694 */
    v += 2;
    out[count] = (hi << 4) | lo;
  }
#endif

  return (int)out[0];
}
