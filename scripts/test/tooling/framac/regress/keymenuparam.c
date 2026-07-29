/* M2 regression kernel - the KEY / 42KEY key number a program step supplies,
 * written into programmableMenu.itemParam[keyNum - 1] with no lower bound
 * (programmableMenu.c:225 and :232 at 4697e526a).
 *
 * The item declares tamMinMax = (1 << TAM_MAX_BITS) | 21, so a key number is 1
 * to 21. Both indirect paths hand that minimum to indirectAddressing()
 * (lblGtoXeq.c:329, :345), but the direct path tests only the maximum -
 * `opParam <= (indexOfItems[op].tamMinMax & TAM_MAX_MASK)` at lblGtoXeq.c:427 -
 * so a step carrying the parameter byte 0 reaches fnKeyGtoXeq(0), and keyGto /
 * keyXeq index the 21-entry table at -1. TAM refuses 0 interactively
 * (tam.c:261), and the program-file screening pass checks the opcode and the
 * label length but no parameter range, so a loaded .p47 delivers it.
 *
 * Measured on 4697e526a with a crafted .p47 (LBL 'KT'; a 14-byte caption;
 * KEY 18 XEQ 05; KEY 00 XEQ 05): gdb at programmableMenu.c:232 takes
 * keyNum = 0, and &itemParam[-1] is &itemName[17][14] - the write turns that
 * caption's terminator into 05 80, leaving the 16-byte name unterminated. The
 * name then measures 58 bytes, the whole itemParam array read as text, which is
 * what initVariableSoftmenu()'s ITM_MENU case copies and renders
 * (softmenus.c:1850). Both arrays are members of one struct, so ASan and
 * Valgrind see nothing; the wall models each as its own object, the technique
 * the pool-overrun rows already use.
 *
 * -DFIXED adds the missing lower bound at the direct path, which is where the
 * whole tamMin class is decided - dSTACK, ERR, MSG, RSD, SIM_EQ, nDUP, nSWAP,
 * nDROP, # and the two grouping items all reach their handlers below their
 * declared minimum through the same test.
 * Buggy: out-of-bounds write. Fixed: proved.
 */
#include <stdint.h>
#include "__fc_builtin.h"

#define TAM_MAX_BITS      14
#define TAM_MAX_MASK      0x3fff
#define INDIRECT_REGISTER 254
#define INDIRECT_VARIABLE 255

/* items.c:3323 (KEY) and :4662 (42KEY): minimum 1, maximum 21. */
#define KEY_TAM_MIN_MAX   ((1u << TAM_MAX_BITS) | 21u)

/* typeDefinitions.h:642-646. Modelled as separate objects so the write past the
 * table's own bounds is visible; in the product both live in one struct and the
 * -1 lands in itemName[17][14..15]. */
static char     itemName[18][16];
static uint16_t itemParam[21];

/* programmableMenu.c:223-233, the two callers of the same write. */
static void keyGto(uint16_t keyNum, uint16_t label) {
  itemParam[keyNum - 1] = label & 0x7fff;
}

static void keyXeq(uint16_t keyNum, uint16_t label) {
  itemParam[keyNum - 1] = label | 0x8000;
}

int main(void) {
  /* _executeOp(): opParam = *(paramAddress++) - the step's parameter byte. */
  uint8_t opParam = (uint8_t)Frama_C_interval(0, 255);
  /* _get2ndParamOfKey(): a local label from the embedded GTO / XEQ step. */
  uint16_t label = (uint16_t)Frama_C_interval(0, 109);
  uint16_t isXeq = (uint16_t)Frama_C_interval(0, 1);

  itemName[17][14] = 0;

  /* lblGtoXeq.c:426-439, case PARAM_NUMBER_8. */
  if(opParam <= (KEY_TAM_MIN_MAX & TAM_MAX_MASK)) {
#ifdef FIXED
    if(opParam < (KEY_TAM_MIN_MAX >> TAM_MAX_BITS)) {
      return 0; /* below the declared minimum: not a valid parameter */
    }
#endif
    /* reallyRunFunction(op, opParam) -> fnKeyGtoXeq(opParam) */
    if(isXeq) {
      keyXeq(opParam, label);
    }
    else {
      keyGto(opParam, label);
    }
  }
  else if(opParam == INDIRECT_REGISTER || opParam == INDIRECT_VARIABLE) {
    /* indirectAddressing() is given tamMinMax >> TAM_MAX_BITS, so the indirect
     * paths already refuse a value below the minimum. */
  }
  return itemParam[0];
}
