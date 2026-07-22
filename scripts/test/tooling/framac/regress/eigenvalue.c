/* M2 regression kernel - eigenvalue previousDiagonal overrun (matrix.c:6625).
 * Bug b9e4f7519: the shared init zeroed previousDiagonal in the eig/q/r loop
 * bounded by size*size*2, but previousDiagonal is only size*2 reals -> overruns
 * by 2*size*(size-1) reals into the pool. "ASan and Valgrind ... miss it." Eva
 * catches it with previousDiagonal sized to its real size*2 allocation.
 * -DFIXED zeroes it in its own size*2 loop. size=3 triggers. */
#include <stdint.h>
typedef struct { uint32_t w[4]; } real_t;      /* opaque real */
static void realSetZero(real_t *p) { p->w[0] = 0; }
#define SIZE 3
int main(void) {
  real_t previousDiagonal[SIZE * 2];            /* real allocation: size*2 */
#ifdef FIXED
  for(int i = 0; i < SIZE * 2; i++) realSetZero(&previousDiagonal[i]);
#else
  for(int i = 0; i < SIZE * SIZE * 2; i++) realSetZero(&previousDiagonal[i]);
#endif
  return 0;
}
