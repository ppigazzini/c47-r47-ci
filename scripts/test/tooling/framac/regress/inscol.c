/* M2 regression kernel - insCol column overrun (matrix.c:2552).
 * Bug fb1f7f483: shift loop `j<cols+1` writes newMat[rows*(cols+1)] on the last
 * row, one past the rows*(cols+1) allocation (and reads one past the source).
 * "Neither ASan nor Valgrind sees it" (stays in the pool) - Eva does. Concrete
 * 3x3 shape triggers the last-row overrun. -DFIXED uses `j<cols`. */
#include <stdint.h>
typedef struct { uint32_t w[4]; } real34_t;
#define ROWS 3
#define COLS 3
int main(void) {
  unsigned beforeColNo = 0;
  real34_t src[ROWS * COLS];
  real34_t newMat[ROWS * (COLS + 1)];
  real34_t zero = { {0,0,0,0} };
  for(unsigned i = 0; i < ROWS; ++i) newMat[beforeColNo + i*(COLS+1)] = zero;
#ifdef FIXED
  for(unsigned j = beforeColNo; j < COLS; ++j)
#else
  for(unsigned j = beforeColNo; j < COLS + 1; ++j)
#endif
    for(unsigned i = 0; i < ROWS; ++i)
      newMat[(j+1) + i*(COLS+1)] = src[j + i*COLS];
  return 0;
}
