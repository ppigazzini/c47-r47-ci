/* M1 Eva/RTE harness - the sorted-insert into freeMemoryRegions[] in
 * core/freeList.c (freeListFree new-block path, lines ~250-270; the same shape
 * appears in freeListReduce). Audit basis: upstream ccafdfe51.
 * Question: does the insert (shift elements up by one, then write slot i) ever
 * touch freeMemoryRegions[MAX_FREE_REGIONS] or beyond? The guard
 * `numberOfFreeMemoryRegions == MAX_FREE_REGIONS -> exit` should make it safe.
 * xcopy (a memmove) is modelled here as an explicit descending copy so every
 * element access is visible to Eva. Expect 0 alarms. */
#include "eva_common.h"

#define MAX_FREE_REGIONS 200
typedef struct { uint16_t blockAddress; uint16_t sizeInBlocks; } freeMemoryRegion_t;
static freeMemoryRegion_t freeMemoryRegions[MAX_FREE_REGIONS];
static int32_t numberOfFreeMemoryRegions;

static void insert_new_free_block(uint16_t C47RamPtr, uint16_t sizeInBlocks) {
  /* precondition from the caller's guard: never called at capacity */
  if(numberOfFreeMemoryRegions == MAX_FREE_REGIONS) return;   /* freeList.c guard */

  int32_t i = 0;
  while(i < numberOfFreeMemoryRegions && freeMemoryRegions[i].blockAddress < C47RamPtr) {
    i++;
  }
  if(i < numberOfFreeMemoryRegions) {
    /* xcopy(freeMemoryRegions+i+1, freeMemoryRegions+i, (n-i)*sizeof(elt)) */
    for(int32_t k = numberOfFreeMemoryRegions - 1; k >= i; k--) {
      freeMemoryRegions[k + 1] = freeMemoryRegions[k];
    }
  }
  freeMemoryRegions[i].blockAddress = C47RamPtr;
  freeMemoryRegions[i].sizeInBlocks = sizeInBlocks;
  numberOfFreeMemoryRegions++;
}

int main(void) {
  /* precondition: the array holds 0..MAX-1 sorted regions (the == MAX case
     exits before the insert), and the contents are arbitrary. */
  numberOfFreeMemoryRegions = Frama_C_interval(0, MAX_FREE_REGIONS - 1);
  for(int32_t j = 0; j < numberOfFreeMemoryRegions; j++) {
    freeMemoryRegions[j].blockAddress = (uint16_t)Frama_C_interval(0, 65535);
    freeMemoryRegions[j].sizeInBlocks = (uint16_t)Frama_C_interval(0, 65535);
  }
  insert_new_free_block((uint16_t)Frama_C_interval(0, 65535),
                        (uint16_t)Frama_C_interval(0, 65535));
  return 0;
}
