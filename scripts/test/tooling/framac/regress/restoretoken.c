/* M2 regression kernel - readToken() / readComplexToken(), the .d47 data-file
 * element readers (saveRestoreCalcState.c:1117-1160 at 199477075). Both walk the
 * open file one byte at a time into the caller's buffer with no end at all:
 * `while(*p != <separator> && !ioEof()) restore(++p, 1);`. Every caller passes
 * the global tmpString, which is TMP_STR_LENGTH = 2560 bytes (config.c:1558; on
 * DMCP it is aux_buf_ptr(), the same 2560). A data file holding one token longer
 * than that writes past the buffer, one byte per loop turn.
 *
 * ASan on 199477075, a 1x1 Rema whose single element is 3000 bytes:
 * heap-buffer-overflow, write of size 1, 0 bytes after the 2560-byte region,
 * inside fread <- ioFileRead (io.c:272) <- restore (:73).
 *
 * restore() is modelled as "writes one arbitrary byte at p"; ioEof() as a
 * nondeterministic end that the analysis must not rely on, which is exactly the
 * caller's situation - the file decides. -DFIXED is the guard commit: stop at
 * the last writable slot and then drain to the separator, the shape readLine()
 * has always used, so the file position still lands on the next element.
 * Buggy: out-of-bounds write. Fixed: proved.
 * Needs slevel > TMP_STR_LENGTH: the walk runs that many times and below it Eva
 * widens and loses the p/end relation.
 */
#include <stdint.h>
#include <stddef.h>
#include "__fc_builtin.h"

#define TMP_STR_LENGTH 2560
static char tmpString[TMP_STR_LENGTH];

static int ioEof(void)               { return Frama_C_interval(0, 1); }
static void restore(void *p, uint32_t size) {
  (void)size;
  *(char *)p = (char)Frama_C_interval(-128, 127);
}

static char *readToken(char *tok, size_t maxLen) {
  char *p = tok;
#ifdef FIXED
  char *const end = (maxLen == 0) ? tok : tok + maxLen - 1;
  if(maxLen != 0 && !ioEof()) {
#else
  (void)maxLen;
  if(!ioEof()) {
#endif
    restore(p, 1);
    while((*p == ' ' || *p == '\t' || *p == '\n' || *p == '\r') && !ioEof()) {
      restore(p, 1);
    }
#ifdef FIXED
    while(p < end && *p != ' ' && *p != '\t' && *p != '\n' && *p != '\r' && !ioEof()) {
      restore(++p, 1);
    }
    while(*p != ' ' && *p != '\t' && *p != '\n' && *p != '\r' && !ioEof()) {
      restore(p, 1);                    /* drain to the separator: the next read resyncs */
    }
#else
    while(*p != ' ' && *p != '\t' && *p != '\n' && *p != '\r' && !ioEof()) {
      restore(++p, 1);
    }
#endif
  }
  *p = 0;
  return tok;
}

int main(void) {
  readToken(tmpString, TMP_STR_LENGTH);
  return tmpString[0];
}
