#!/usr/bin/env bash
# scripts/test/run-framac-regress.sh
#
# Frama-C regression wall (Milestone M2; see __DEV REPORT-15). A permanent corpus
# of extracted-kernel harnesses, one per historic c43 out-of-bounds bug. Each
# kernel reproduces the cited access with buffers sized to the real allocation,
# and encodes both the pre-fix logic (default) and the shipped fix (-DFIXED).
#
# For each kernel the gate asserts BOTH:
#   buggy mode  (no -DFIXED) -> >= 1 Eva alarm   (the detector fires: a gate that
#                                                 never fires is not a gate)
#   fixed mode  (-DFIXED)    -> 0 Eva alarms      (the fix closes the hole)
# A kernel that stops firing in buggy mode, or that alarms in fixed mode, FAILS.
#
# Three of the four bugs (inscol, eigenvalue, printregister) are pool-internal
# overruns that ASan and Valgrind cannot see; Eva catches them by modelling the
# buffer as a sized object rather than as part of the one `ram` malloc.
#
# Standalone (no upstream clone, no build). Optional infrastructure: with no
# frama-c it exits 127 (SKIPPED, not passed).

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"

REG_DIR="$SCRIPT_DIR/tooling/framac/regress"
MANIFEST="$REG_DIR/manifest.txt"
MACHDEP="${FRAMAC_MACHDEP:-gcc_x86_64}"

trim() {
    local s="$1"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

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

# Echo the Eva alarm count for one kernel; $2 non-empty selects the -DFIXED build.
eva_alarms() {
    local kernel="$1" fixed="$2" slevel="$3" out extra=()
    [[ -n "$fixed" ]] && extra=(-cpp-extra-args=-DFIXED)
    out="$(cd "$REG_DIR" && frama-c -machdep "$MACHDEP" -rte -eva -eva-no-show-progress \
        -eva-slevel "$slevel" "${extra[@]}" "$kernel" 2>&1)" || true
    printf '%s\n' "$out" | grep -oE '[0-9]+ alarms? generated' | grep -oE '^[0-9]+' | head -1
}

main() {
    harness_init
    local log="$LOG_DIR/framac-regress.log"
    {
        framac_require
        [[ -f "$MANIFEST" ]] || harness_die "missing $MANIFEST"
        harness_log "regression wall over $(grep -cvE '^\s*(#|$)' "$MANIFEST") historic OOB bugs"

        local fail=0 k slevel fix note buggy fixed
        while IFS='|' read -r k slevel fix note; do
            k="$(trim "$k")"
            [[ -z "$k" || "$k" == \#* ]] && continue
            slevel="$(trim "$slevel")"; fix="$(trim "$fix")"
            [[ -f "$REG_DIR/$k" ]] || harness_die "kernel not found: $k"

            buggy="$(eva_alarms "$k" "" "$slevel")";      buggy="${buggy:-0}"
            fixed="$(eva_alarms "$k" 1 "$slevel")";       fixed="${fixed:-0}"

            if ((buggy >= 1 && fixed == 0)); then
                printf ' ok   %-16s buggy=%s fixed=%s  fix %s\n' "$k" "$buggy" "$fixed" "$fix"
            else
                printf ' FAIL %-16s buggy=%s fixed=%s  (want buggy>=1, fixed=0)\n' "$k" "$buggy" "$fixed"
                fail=$((fail + 1))
            fi
        done < "$MANIFEST"

        harness_log "regression wall: $fail failure(s)"
        ((fail == 0)) || harness_die "frama-c regression wall FAILED on $fail kernel(s)"
        harness_log "FRAMAC REGRESS OK"
    } 2>&1 | tee "$log"
    harness_log "log written: $log"
}

main "$@"
