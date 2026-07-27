/* M2 regression kernel - the region-table hexDump write in restoreStateValue()
 * (saveRestoreBackup.c:696), sized by the count restoreCalc() reads out of
 * backup.cfg (:827-830). The count is a plain int32 from the file and was
 * multiplied into the very size argument that bounds the write, so the file
 * chose the bound on a write into a fixed-capacity table. ASan on 3c84890a1:
 * heap-buffer-overflow write 0 bytes after the 800-byte freeMemoryRegions, and
 * global-buffer-overflow 0 bytes after allocatedMemoryRegions (20000 bytes).
 *
 * The loop is verbatim from the hexDump branch, with the source digits modelled
 * as arbitrary bytes so only the destination bound is under test; -DFIXED passes
 * the room the destination has, as the shipped fix does.
 *
 * Note this is the bound that does NOT need a value check to hold: fixed mode
 * proves over the whole int32 count domain, count unconstrained. The companion
 * obligation - that the count itself stays inside the table, which freeList.c's
 * walks need - is the caller guard freelist_insert.c assumes.
 * Buggy: 1 out-of-bounds write. Fixed: proved.
 * Needs slevel > sizeof(freeMemoryRegions): the write loop runs that many times
 * and below it Eva widens and loses the buf/count relation. */
#include <stdint.h>
#include <stddef.h>
#include "__fc_builtin.h"

#define MAX_FREE_REGIONS 200
typedef struct { uint16_t blockAddress; uint16_t sizeInBlocks; } freeMemoryRegion_t;
static freeMemoryRegion_t freeMemoryRegions[MAX_FREE_REGIONS];
static int32_t numberOfFreeMemoryRegions;

static void restore_hexdump(void *buffer, uint32_t size, uint32_t fileByteCount) {
  uint32_t numberOfBytes = fileByteCount;                   /* saveRestoreBackup.c:677 */
  if(numberOfBytes > size) {
    numberOfBytes = size;
  }
  uint8_t *buf = (uint8_t *)buffer;
  for(uint32_t count = 0; count < numberOfBytes; count++, buf++) {
    *buf = (uint8_t)Frama_C_interval(0, 255);               /* saveRestoreBackup.c:696 */
  }
}

int main(void) {
  /* restoreStateValue(&numberOfFreeMemoryRegions, ..., "int32") - the file's, sign and all */
  numberOfFreeMemoryRegions    = Frama_C_interval(-2000000, 2000000);
  /* the file's own "freeMemoryRegions:hexDump:<n>" header */
  uint32_t fileByteCount       = (uint32_t)Frama_C_interval(0, 2000000);

#ifdef FIXED
  restore_hexdump(freeMemoryRegions, (uint32_t)sizeof(freeMemoryRegions), fileByteCount);
#else
  restore_hexdump(freeMemoryRegions,
                  (uint32_t)(sizeof(freeMemoryRegion_t) * (size_t)numberOfFreeMemoryRegions),
                  fileByteCount);
#endif
  return (int)freeMemoryRegions[0].sizeInBlocks;
}
