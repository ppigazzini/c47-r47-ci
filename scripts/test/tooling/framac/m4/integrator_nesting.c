/* M4 kernel - the unbounded integrator nesting from REPORT-13.
 * Upstream supports nested integration INT(INT) (integrate.c:309-310) with NO
 * nesting-depth guard anywhere in solver/. A program that re-enters the
 * integrator every step (the pathological `LBL A: PGMINT A`) recurses without
 * bound and overflows the C stack - REPORT-13's open crash.
 *
 * What Frama-C shows, honestly:
 *  - UNGUARDED: Eva REFUSES the analysis with `[eva:recursion] ... cannot bound`
 *    - it cannot assign a terminating spec. That refusal is the signal that the
 *    recursion is unbounded; it is not a proof of non-termination (no tool bounds
 *    C-stack depth here).
 *  - GUARDED (-DGUARD, the fix shape - a nesting counter): Eva analyses cleanly
 *    and PROVES `nestDepth <= MAX_INTEGRATION_NESTING`, i.e. the guard bounds the
 *    nesting. The gate proves the FIX; the bug itself is a code-inspection verdict.
 * Run: frama-c -machdep gcc_x86_64 -eva -eva-unroll-recursive-calls 12 \
 *              -cpp-extra-args=-DGUARD integrator_nesting.c                       */

#define MAX_INTEGRATION_NESTING 8
static int nestDepth = 0;

void integrator(void);
static void run_program(void) { integrator(); }   /* the integrand re-enters */

void integrator(void) {
#ifdef GUARD
  if(nestDepth >= MAX_INTEGRATION_NESTING) return; /* the fix: cap nesting    */
  nestDepth++;
  //@ assert nesting_bounded: 0 < nestDepth <= MAX_INTEGRATION_NESTING;
  run_program();
  nestDepth--;
#else
  run_program();                                   /* unbounded: Eva refuses  */
#endif
}

int main(void) { integrator(); return 0; }
