/* M2 regression kernel - the c47Ptr conversions in restoreCalc()
 * (saveRestoreBackup.c:884-939). Each of fifteen fields is a block index read
 * off a file line by stringToUint32 and handed to TO_PCMEMPTR(), which is
 * ram + p and has no range of its own; four of them then add a second
 * file-supplied uint32 byte offset. ASan on 3c84890a1, one line changed to
 * block 65534: heap-buffer-overflow read in isAtEndOfPrograms (manage.c:67) and
 * an 8-byte write in scanLabelsAndPrograms (manage.c:167), 0 bytes after the
 * 262136-byte pool.
 *
 * The kernel dereferences the converted pointer once, which is what
 * scanLabelsAndPrograms() does with it immediately. -DFIXED range-checks the
 * two integers before the pointer exists, as restoredPoolPointer() does.
 *
 * A note on the sentinel, because it decides whether this fires at all: a block
 * address of 1000000 is the more dangerous pointer and reports NOTHING under
 * ASan, since at that distance ram + p lands on unrelated live allocations.
 * Eva has no such blind spot - it refutes the whole interval - which is the
 * point of gating this here as well as in the fuzz lane.
 * Buggy: >=1 out-of-bounds access. Fixed: proved over every uint32 pair. */
#include <stdint.h>
#include <stddef.h>
#include "__fc_builtin.h"

#define RAM_SIZE_IN_BLOCKS 65534u                   /* defines.h:2066 */
#define C47_NULL           65535u                   /* defines.h:2230 */
#define TO_BYTES(n)        (((uint32_t)(n)) << 2)

static uint32_t ram[RAM_SIZE_IN_BLOCKS];            /* config.c:1533 mallocs exactly this many blocks */

int main(void) {
  /* restoreStateValue(&ramPtr, ..., "beginOfProgramMemory", "c47Ptr") and the
     matching "...Offset" uint32 - both straight off a file line */
  const uint32_t blockAddress = (uint32_t)Frama_C_unsigned_int_interval(0, 4294967295u);
  const uint32_t byteOffset   = (uint32_t)Frama_C_unsigned_int_interval(0, 4294967295u);
  uint8_t *beginOfProgramMemory = (uint8_t *)ram;   /* never read unset; keeps the merged state free of UNINITIALIZED */

#ifdef FIXED
  if(blockAddress == C47_NULL && byteOffset == 0) {
    return 0;                                       /* the file's own null */
  }
  /* The shipped guard, verbatim. saveCalc() splits a pointer with TO_C47MEMPTR(),
     which divides by the block size and stores the remainder as the offset, so an
     offset is never TO_BYTES(1) or more; bounding it by the pool instead would
     admit 65534 times the offsets the writer can emit. The result is required to
     be strictly inside the pool: the one-past-the-end position is a pointer C
     defines, but every consumer here dereferences what it is given, and letting
     one through was measured to walk isAtEndOfPrograms() off the end.
     Each number is bounded against a constant, so there is no relation for Eva to
     carry and the sum cannot overflow. */
  if(blockAddress >= RAM_SIZE_IN_BLOCKS || byteOffset >= TO_BYTES(1)) {
    return 0;                                       /* file refused */
  }
  beginOfProgramMemory = (uint8_t *)ram + TO_BYTES(blockAddress) + byteOffset;
#else
  beginOfProgramMemory = (uint8_t *)ram + TO_BYTES(blockAddress);   /* TO_PCMEMPTR, defines.h:2231 */
  beginOfProgramMemory += byteOffset;                               /* saveRestoreBackup.c:921 */
#endif

  return (int)*beginOfProgramMemory;                /* isAtEndOfPrograms, manage.c:67 */
}
