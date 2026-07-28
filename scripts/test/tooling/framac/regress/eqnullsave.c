/* M2 regression kernel - the equation save loop in doSave()
 * (saveRestoreCalcState.c:852-856 at 10ccf8904). fnEqNew() creates a formula
 * whose pointerToFormulaData stays C47_NULL until text is typed into it
 * (equation.c:124, :144), TO_PCMEMPTR() maps that sentinel to NULL, and the
 * save loop hands the result to stringToUtf8() -> stringGlyphLength(), which
 * dereferences it.
 *
 * Two keystrokes on the simulator: `xeq EQ.NEW; savest st.sav` gives
 * "AddressSanitizer: SEGV on unknown address 0x000000000000" in
 * stringGlyphLength (charString.c:504) <- stringToUtf8 (:666) <- doSave (:853).
 *
 * The pointer table and the sentinel are modelled exactly; the string walk is
 * stringGlyphLength verbatim, since that is the function that faults.
 * stringToUtf8's own conversion is irrelevant here and is reduced to the read.
 * -DFIXED is the guard commit: a formula with no text has no representation in
 * the state file - a blank line would make the reader take the next section
 * header for its text - so it is skipped, and the count follows. "No text" is
 * both ways a formula can hold none: the C47_NULL sentinel, and the empty string
 * a restore leaves when its count outran the file. The kernel models the guard
 * as the branch writes it, formulaHasText().
 * Buggy: NULL dereference. Fixed: proved.
 */
#include <stdint.h>
#include <stddef.h>
#include "__fc_builtin.h"

#define C47_NULL      65535
#define RAM_BYTES     64
#define MAX_FORMULAE  4

static uint8_t ram[RAM_BYTES];
typedef struct { uint16_t pointerToFormulaData; uint16_t sizeInBlocks; } formulaHeader_t;
static formulaHeader_t allFormulae[MAX_FORMULAE];
static uint16_t numberOfFormulae;

#define TO_PCMEMPTR(p) ((void *)((p) == C47_NULL ? (void *)0 : ram + (p)))

/* charString.c:501-517, verbatim - the walk that faults on a NULL argument */
static int32_t stringGlyphLength(const char *str) {
  int32_t len = 0;
  while(*str != 0) {
    if(*str & 0x80) { str += 2; len++; }
    else            { str += 1; len++; }
  }
  return len;
}

/* stringToUtf8(str, utf8) reads str through stringGlyphLength before writing anything */
static void stringToUtf8_modelled(const char *str) { (void)stringGlyphLength(str); }

/* saveRestoreCalcState.c, the predicate the guard commit adds - verbatim */
static int formulaHasText(uint16_t id) {
  const char *text;

  if(allFormulae[id].pointerToFormulaData == C47_NULL) {
    return 0;
  }
  text = (const char *)TO_PCMEMPTR(allFormulae[id].pointerToFormulaData);
  return text[0] != 0;
}

int main(void) {
  for(size_t b = 0; b < RAM_BYTES - 1; b++) { ram[b] = (uint8_t)Frama_C_interval(1, 127); }
  ram[RAM_BYTES - 1] = 0;                          /* every modelled formula is NUL-terminated */

  numberOfFormulae = (uint16_t)Frama_C_interval(0, MAX_FORMULAE);
  for(uint16_t i = 0; i < MAX_FORMULAE; i++) {     /* each slot: text, or the C47_NULL a new equation carries */
    if(Frama_C_interval(0, 1)) {                   /* if/else, not a ternary: the ternary merges the sentinel into
                                                    * the offset interval before the store and the model then claims
                                                    * ram + 65534 is reachable, which is the harness lying, not c43 */
      allFormulae[i].pointerToFormulaData = (uint16_t)C47_NULL;
    }
    else {
      allFormulae[i].pointerToFormulaData = (uint16_t)Frama_C_interval(0, RAM_BYTES - 1);
    }
    allFormulae[i].sizeInBlocks = 0;
  }

  uint16_t counted = 0;
  for(uint16_t i = 0; i < numberOfFormulae; i++) {
#ifdef FIXED
    if(formulaHasText(i)) { counted++; }
#else
    counted++;
#endif
  }

  for(uint16_t i = 0; i < numberOfFormulae; i++) {
#ifdef FIXED
    if(!formulaHasText(i)) { continue; }
#endif
    stringToUtf8_modelled(TO_PCMEMPTR(allFormulae[i].pointerToFormulaData));
  }
  return (int)counted;
}
