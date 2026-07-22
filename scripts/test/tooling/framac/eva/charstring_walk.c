/* M1 Eva/RTE harness - UTF-8 byte walk stringNextGlyphNoEndCheck_JM.
 * Audit basis: upstream ccafdfe51, charString.c:355-377 (copied verbatim).
 * The function's own comment: "Not checking for beyond terminator. Use only if
 * no risk for pos > length(str)". This harness makes that precondition precise:
 * it reads str[pos+2], so on a NUL-terminated buffer whose last non-NUL byte has
 * the high bit set, it reads one past the end. Expect an out-of-bounds alarm -
 * this is the documented-unsafe path, not a clean proof. */
#include "eva_common.h"

int16_t stringNextGlyphNoEndCheck_JM(const char *str, int16_t pos) {
  int16_t posinc = 0;
  if(str[pos] == 0) { return pos; }
  if(str[pos] & 0x80) {
    posinc = 2;
    if(str[pos+2] == 0) { return pos+2; }
  } else {
    posinc = 1;
    if(str[pos+1] == 0) { return pos+1; }
  }
  pos += posinc;
  return pos;
}

#define BUFSZ 8
int main(void) {
  char buf[BUFSZ];
  for(int i = 0; i < BUFSZ - 1; i++) buf[i] = (char)Frama_C_interval(-128, 127);
  buf[BUFSZ - 1] = 0;                       /* a valid NUL-terminated C string  */
  int16_t pos = (int16_t)Frama_C_interval(0, BUFSZ - 1);  /* pos in bounds of buf */
  volatile int16_t r = stringNextGlyphNoEndCheck_JM(buf, pos);
  return r;
}
