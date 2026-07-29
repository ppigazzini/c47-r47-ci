/* M2 regression kernel - the conversion-pair partner softkey, read out of
 * userMenuItems[] / userMenus[].menuItem[] at dynamicMenuItem ^ 1 with no range
 * test (conversionUnits.c:822-826 at 4697e526a).
 *
 * The two halves of a conversion pair sit on neighbouring softkeys, so
 * executionConversionPartner() takes the partner's item from the softkey index
 * dynamicMenuItem ^ 1. dynamicMenuItem is -1 whenever no softkey picked the
 * item - "-1: no dynamic menu item is selected" (c47.c:256), the value
 * determineItem() and every engine entry restore - and -1 ^ 1 is -2. Both
 * tables hold 18 entries (c47.h:341, typeDefinitions.h:634), so the read lands
 * before the start of whichever table the current menu selects. The
 * programmable menu also leaves 18, 19 or 20 in the variable (keyboard.c:4506,
 * :4724, :3733), which puts the partner past the end.
 *
 * Measured on 4697e526a with a three-step .p47 (LBL 'C'; 5; km->mi) run from
 * the factory-reset machine, whose top softmenu is MyMenu:
 *   conversionUnits.c:824:74: runtime error: index -2 out of bounds for type
 *     'userMenuItem_t [18]'
 *   AddressSanitizer: global-buffer-overflow READ in
 *     executionConversionPartner <- reallyRunFunction (items.c:564)
 *     <- runFunction <- executeOneStep <- runProgram <- fnExecute
 *   40 bytes before global variable 'userMenuItems'
 * The read is off a global, so ASan and UBSan both see it; Frama-C closes it
 * over the whole domain of dynamicMenuItem instead of one witness.
 *
 * -DFIXED adds the range test the caller never makes, returning the 0 the
 * menu-mismatch arm already returns for "no custom pair".
 * Buggy: out-of-bounds read. Fixed: proved.
 */
#include <stdint.h>
#include "__fc_builtin.h"

#define MNU_MyMenu  1349                                   /* items.h:1394 */
#define MNU_DYNAMIC 1857                                   /* items.h, the user-menu pseudo item */

#define USER_MENU_ITEMS 18                                 /* c47.h:341, typeDefinitions.h:634 */
#define USER_MENUS       2                                 /* two defined user menus is enough to index one */

/* typeDefinitions.h:622-635, values immaterial: only the index is under test. */
typedef struct {
  int16_t item;
  int16_t unused;
  char    argumentName[16];
} userMenuItem_t;

typedef struct {
  char           menuName[16];
  userMenuItem_t menuItem[USER_MENU_ITEMS];
} userMenu_t;

static userMenuItem_t userMenuItems[USER_MENU_ITEMS];      /* c47.c:83, a global */
static userMenu_t     userMenusStore[USER_MENUS];
static userMenu_t    *userMenus = userMenusStore;           /* c47.c:85, a pointer */

int main(void) {
  /* c47.c:256 - -1 when no softkey selected an item; 0..17 from a softkey
   * (keyboard.c:43); 18, 19 and 20 from the programmable menu. */
  int16_t dynamicMenuItem = (int16_t)Frama_C_interval(-1, 20);
  int16_t currentUserMenu = (int16_t)Frama_C_interval(0, USER_MENUS - 1);
  /* -softmenu[softmenuStack[0].softmenuId].menuItem: the two menus that select
   * a table, plus one that selects neither. */
  int16_t curMenu = (int16_t)Frama_C_interval(0, 2) == 0 ? MNU_MyMenu
                  : (int16_t)Frama_C_interval(0, 1) == 0 ? MNU_DYNAMIC
                  : 0;

  int16_t i;
  for(i = 0; i < USER_MENU_ITEMS; i++) {
    userMenuItems[i].item              = 0;
    userMenusStore[0].menuItem[i].item = 0;
    userMenusStore[1].menuItem[i].item = 0;
  }

  /* conversionUnits.c:822-826. */
  const int16_t softKeyIx = dynamicMenuItem ^ 1;
  int16_t softKeyPartner;
#ifdef FIXED
  if(softKeyIx < 0) {
    softKeyPartner = 0;
  }
  else if(curMenu == MNU_MyMenu && softKeyIx < USER_MENU_ITEMS) {
    softKeyPartner = userMenuItems[softKeyIx].item;
  }
  else if(curMenu == MNU_DYNAMIC && softKeyIx < USER_MENU_ITEMS) {
    softKeyPartner = userMenus[currentUserMenu].menuItem[softKeyIx].item;
  }
  else {
    softKeyPartner = 0;
  }
#else
  softKeyPartner = (curMenu == MNU_MyMenu)  ? userMenuItems[softKeyIx].item
                 : (curMenu == MNU_DYNAMIC) ? userMenus[currentUserMenu].menuItem[softKeyIx].item
                 : 0;
#endif
  return softKeyPartner;
}
