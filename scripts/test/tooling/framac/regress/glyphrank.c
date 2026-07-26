/* M2 regression kernel - compareString glyph rank OOB (sort.c:202,208,237,243).
 * findGlyph() answers a miss with a negative not-found code (-1 for standardFont,
 * whose id is 1), and the master rank lookups index standardFont.glyphs[] with it,
 * so a code point the font lacks reads glyphs[-1]. findGlyph/findGlyphExact are
 * verbatim from fonts.c:40-80; the font is modelled because the real one is
 * generated data. -DFIXED resolves a glyph instead, as charString.c:274,
 * screen.c:1182 and print.c:616 do, so the wall gates the shape that ships.
 * Buggy: OOB read. Fixed: proved safe over every uint16_t. */
#include <stdint.h>
#include "__fc_builtin.h"

typedef struct { uint16_t charCode; int16_t rank1; } glyph_t;
typedef struct { int8_t id; uint16_t numberOfGlyphs; glyph_t glyphs[8]; } font_t;

/* id 1 is standardFont's, so a miss returns -1. Codes ascend, as findGlyphExact's
 * binary search requires; 0x0001 is absent, which is what x->alpha can produce. */
static const font_t standardFont = {
  .id = 1, .numberOfGlyphs = 8,
  .glyphs = {{0x0020, 1}, {0x0041, 11}, {0x0042, 12}, {0x0043, 13},
             {0x007f, 40}, {0x80a1, 50}, {0x80a2, 51}, {0x80a3, 52}}
};

static int16_t findGlyphExact(const font_t *font, uint16_t charCode) {   /* fonts.c:40 */
  int16_t first = 0, middle, last = font->numberOfGlyphs - 1;
  middle = (first + last) / 2;
  while(last > first + 1) {
    if(charCode < font->glyphs[middle].charCode) { last = middle; } else { first = middle; }
    middle = (first + last) / 2;
  }
  if(font->glyphs[first].charCode == charCode) { return first; }
  if(font->glyphs[last].charCode == charCode) { return last; }
  return -1;
}

static int16_t findGlyph(const font_t *font, uint16_t charCode) {        /* fonts.c:67 */
  int16_t id = findGlyphExact(font, charCode);
  if(id >= 0) { return id; }
  if(font->id == 1) { return -1; }
  if(font->id == 0) { return -2; }
  return 0;
}

#ifdef FIXED
static const glyph_t unmappedGlyph = {0x0000, 0};

static const glyph_t *collationGlyph(uint16_t charCode) {
  const int16_t glyphId = findGlyph(&standardFont, charCode);
  return (glyphId < 0) ? &unmappedGlyph : &standardFont.glyphs[glyphId];
}
#endif

int main(void) {
  uint16_t charCode = (uint16_t)Frama_C_interval(0, 65535);
#ifdef FIXED
  return collationGlyph(charCode)->rank1;
#else
  return standardFont.glyphs[findGlyph(&standardFont, charCode)].rank1;  /* sort.c:202 */
#endif
}
