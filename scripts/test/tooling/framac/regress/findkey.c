/* M2 regression kernel - findKey2ndParam OOB (nextStep.c:307).
 * Bug 886d26ce3 / REPORT-13: op decodes to [0,0x7fff] but the master guard only
 * rejects op==0x7fff, then indexes indexOfItems[op] (LAST_ITEM+1 slots).
 * -DFIXED uses `op >= LAST_ITEM`. Buggy: OOB read. Fixed: proved safe. */
#include <stdint.h>
#include "__fc_builtin.h"
#define LAST_ITEM 2870
typedef struct { uint16_t status; } item_t;
static item_t indexOfItems[LAST_ITEM + 1];
int main(void) {
  unsigned char b0 = Frama_C_interval(0, 255), b1 = Frama_C_interval(0, 255);
  uint16_t op = b0;
  if(op & 0x80) { op &= 0x7f; op <<= 8; op |= b1; }
#ifdef FIXED
  if(op >= LAST_ITEM) return 0;
#else
  if(op == 0x7fff) return 0;
#endif
  return indexOfItems[op].status & 0x0e00;
}
