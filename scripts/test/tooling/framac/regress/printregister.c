/* M2 regression kernel - complex-matrix dump OOB read (registers.c:1738).
 * Bug 1754a7808: offset (r*matrixRows + c) uses ROWS as the row stride instead
 * of COLS; for a rows>cols matrix the index exceeds rows*cols. -DFIXED uses
 * (r*matrixColumns + c). Shape 3x2 (rows>cols) triggers. */
#include <stdint.h>
typedef struct { uint32_t re[4], im[4]; } complex34_t;
#define ROWS 3
#define COLS 2
int main(void) {
  complex34_t mat[ROWS * COLS];
  for(unsigned k = 0; k < ROWS * COLS; ++k) { mat[k].re[0] = 0; mat[k].im[0] = 0; }
  volatile uint32_t sink = 0;
  for(unsigned r = 0; r < ROWS; ++r)
    for(unsigned c = 0; c < COLS; ++c) {
#ifdef FIXED
      unsigned idx = r * COLS + c;
#else
      unsigned idx = r * ROWS + c;            /* the bug: ROWS instead of COLS */
#endif
      sink += mat[idx].re[0] + mat[idx].im[0];
    }
  return (int)sink;
}
