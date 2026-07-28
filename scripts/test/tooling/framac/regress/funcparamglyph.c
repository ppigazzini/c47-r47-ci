/* M2 regression kernel - the Norm key parameter recalled from a config register
 * (recall.c:282 at 199477075) and the glyph walk every consumer of that name
 * runs (stringGlyphLength, charString.c:501-517).
 *
 * The config register is a raw byte image of dtConfigDescriptor_t, so its
 * funcParam field need not be terminated inside the 16 bytes it occupies. The
 * first guard commit (7d0aba189) forced a terminator into the last byte, which
 * bounds the buffer but not the string: C47 encodes a glyph in one or two bytes,
 * lead byte 0x80 or above, so a cut at a fixed offset can leave the lead byte of
 * a two-byte glyph as the last byte of the name. stringGlyphLength then steps
 * str += 2 over it and reads one byte past the field. Measured on the simulator:
 * a register whose field holds 41 42 ... 4E 80 C0 recalls as
 * 'ABCDEFGHIJKLMN\x80' before the fix and 'ABCDEFGHIJKLMN' after.
 *
 * -DFIXED is the guard commit: walk the field glyph by glyph and cut at the last
 * boundary that fits with room for the terminator, so the name always ends on a
 * glyph boundary and the walk stays inside the field.
 * Buggy: out-of-bounds read. Fixed: proved.
 */
#include <stdint.h>
#include <stddef.h>
#include "__fc_builtin.h"

/* The field is char[16] in c47.h. It is modelled at 6 bytes here and every byte is drawn from the three
 * cases the walk distinguishes - terminator, one-byte glyph, lead byte of a two-byte glyph - so Eva
 * enumerates all 3^6 patterns instead of widening over 256^16. The loop indexes with sizeof(), so the
 * algorithm under test is the same one the 16-byte field runs. */
#define FIELD_SIZE 6
static char funcParam[FIELD_SIZE];

/* charString.c:501-517, verbatim */
static int32_t stringGlyphLength(const char *str) {
  int32_t len = 0;
  while(*str != 0) {
    if(*str & 0x80) { str += 2; len++; }
    else            { str += 1; len++; }
  }
  return len;
}

int main(void) {
  /* xcopy(Norm_Key_00.funcParam, configToRecall->Norm_Key_00.funcParam, sizeof(...)):
   * a raw image out of the register, any 16 bytes, terminator or not. */
  for(size_t i = 0; i < sizeof(funcParam); i++) {
    int which = Frama_C_interval(0, 2);
    funcParam[i] = (which == 0) ? (char)0 : (which == 1) ? (char)0x41 : (char)0x80;
  }

#ifdef FIXED
  {
    size_t cut = 0;
    while(cut < sizeof(funcParam) && funcParam[cut] != 0) {
      size_t next = cut + ((funcParam[cut] & 0x80) ? 2 : 1);
      if(next >= sizeof(funcParam)) { break; }
      cut = next;
    }
    funcParam[cut] = 0;
  }
#else
  funcParam[sizeof(funcParam) - 1] = 0;     /* terminate at a fixed offset: may halve a glyph */
#endif

  return (int)stringGlyphLength(funcParam);
}
