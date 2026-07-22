#!/usr/bin/env bash
# scripts/test/run-framac-nonterm.sh
#
# Frama-C Tier-D frontier gate (Milestone M4; see __DEV REPORT-15). Two things:
#
# 1. The unbounded integrator nesting REPORT-13 left open. Upstream supports
#    nested INT(INT) (integrate.c:309-310) with no depth guard in solver/, so a
#    self-nesting program recurses until the C stack overflows. Frama-C's honest
#    verdict: Eva REFUSES the unguarded recursion (`[eva:recursion]: cannot
#    bound`) - the unbounded-recursion signal - and PROVES the depth-guarded fix
#    shape bounds nesting (nestDepth <= MAX). This gate asserts the fix is
#    provable and records that the unguarded form is unbounded.
#
# 2. Index safety with the numeric libraries stubbed (distributions / solver /
#    matrix) was demonstrated in M2: real34_t / complex34_t modelled as opaque
#    blobs let Eva check pure index/pointer bounds while the decNumber VALUES stay
#    uninterpreted (inscol.c, eigenvalue.c, printregister.c). M4 records that the
#    technique carries; it adds no redundant harness here.
#
# Standalone. With no frama-c it exits 127 (SKIPPED, not passed).

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"

M4_DIR="$SCRIPT_DIR/tooling/framac/m4"
KERNEL="integrator_nesting.c"
MACHDEP="${FRAMAC_MACHDEP:-gcc_x86_64}"

framac_require() {
    if command -v opam > /dev/null 2>&1; then
        eval "$(opam env 2> /dev/null)" || true
    fi
    if ! command -v frama-c > /dev/null 2>&1; then
        harness_log "frama-c not found (no opam switch) - SKIP (not a failure)"
        exit 127
    fi
    harness_log "frama-c: $(frama-c -version 2> /dev/null)"
}

main() {
    harness_init
    local log="$LOG_DIR/framac-nonterm.log"
    {
        framac_require
        [[ -f "$M4_DIR/$KERNEL" ]] || harness_die "missing $M4_DIR/$KERNEL"
        local fail=0

        # (a) GUARDED: the fix must prove the nesting bound - 1 valid assertion, 0 alarms.
        local g
        g="$(cd "$M4_DIR" && frama-c -machdep "$MACHDEP" -eva -eva-no-show-progress \
            -eva-unroll-recursive-calls 12 -cpp-extra-args=-DGUARD "$KERNEL" 2>&1)" || true
        local alarms valid
        alarms="$(printf '%s\n' "$g" | grep -oE '[0-9]+ alarms? generated' | grep -oE '^[0-9]+' | head -1)"; alarms="${alarms:-1}"
        valid="$(printf '%s\n' "$g" | grep -oE 'Assertions[[:space:]]+[0-9]+ valid' | grep -oE '[0-9]+' | head -1)"; valid="${valid:-0}"
        if [[ "$alarms" == 0 && "$valid" -ge 1 ]]; then
            printf ' ok   guarded fix: nesting bound PROVED (%s assertion valid, 0 alarms)\n' "$valid"
        else
            printf ' FAIL guarded fix: expected the nesting bound proved (got alarms=%s valid=%s)\n' "$alarms" "$valid"
            fail=$((fail + 1))
        fi

        # (b) UNGUARDED: Eva must refuse the recursion (the unbounded signal). This
        # is documented, not a pass/fail - absence of the signal would be the surprise.
        local u
        u="$(cd "$M4_DIR" && frama-c -machdep "$MACHDEP" -eva -eva-no-show-progress "$KERNEL" 2>&1)" || true
        if printf '%s\n' "$u" | grep -qiE 'eva:recursion|cannot bound'; then
            printf ' note unguarded form: Eva cannot bound the recursion -> REPORT-13 bug CONFIRMED (needs a depth guard)\n'
        else
            printf ' FAIL unguarded form: expected the [eva:recursion] unbounded signal, absent\n'
            fail=$((fail + 1))
        fi

        harness_log "Tier-D frontier gate: $fail failure(s)"
        ((fail == 0)) || harness_die "frama-c nonterm/M4 gate FAILED"
        harness_log "FRAMAC NONTERM OK"
    } 2>&1 | tee "$log"
    harness_log "log written: $log"
}

main "$@"
