/* M2 regression kernel - the MYMENU / MYALPHA / USER_MENUS item writes in
 * restoreOneSection() (saveRestoreCalcState.c:1848, :1873, :1920 at 199477075),
 * each indexed by the entry count the same file supplies two lines earlier.
 * userMenuItems and userAlphaItems are 18-element globals; a user menu holds 18
 * items and userMenus is ONE pool block holding every menu, so the same index
 * runs over the menus that follow and then out of the block.
 *
 * ASan on 199477075, MYMENU count 500: global-buffer-overflow, write of size 2,
 * 0 bytes after userMenuItems (360 bytes). The USER_MENUS write is pool memory
 * and ASan cannot see it; the POOL_GUARD canary reports it as an overrun of the
 * 188-block (752-byte) userMenus region, caught at the next createMenu realloc.
 *
 * The three loops are one shape, modelled once with the array sized to the real
 * allocation. -DFIXED adds the bound the guard commit puts on the write - on the
 * write and not on the loop, which must keep reading a line per claimed entry to
 * stay aligned with the file.
 * Buggy: out-of-bounds writes. Fixed: proved.
 */
#include <stdint.h>
#include <stddef.h>
#include "__fc_builtin.h"

#define NBR_OF_MENU_ITEMS 18
typedef struct { int16_t item; int16_t unused; char argumentName[16]; } userMenuItem_t;
static userMenuItem_t userMenuItems[NBR_OF_MENU_ITEMS];

int main(void) {
  /* numberOfRegs = toInt16(tmpString) - the file's own "MYMENU\n<count>" line */
  int16_t numberOfRegs = (int16_t)Frama_C_interval(-32768, 32767);

  for(int16_t i = 0; i < numberOfRegs; i++) {
    /* readLine(tmpString, TMP_STR_LENGTH) - one line per claimed entry, always read */
#ifdef FIXED
    if(i < (int16_t)(sizeof(userMenuItems) / sizeof(userMenuItems[0]))) {
#else
    {
#endif
      userMenuItems[i].item            = (int16_t)Frama_C_interval(-32768, 32767);
      userMenuItems[i].argumentName[0] = 0;
    }
  }
  return userMenuItems[0].item;
}
