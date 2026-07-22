#!/usr/bin/env bash
# scripts/test/run-framac-wp.sh
#
# Frama-C WP deductive-proof gate (Milestone M3; see __DEV REPORT-15). Proves
# functional LAWS (not just runtime safety) about small non-bitwise c43 integer
# helpers, via ACSL contracts discharged to Z3. Each driver under
# scripts/test/tooling/framac/wp/ is an extracted kernel carrying `/*@ */`
# contracts, so c43 source stays untouched (upstream-governance friendly).
#
# The gate requires EVERY goal in EVERY driver proved (Proved goals: N / N). Any
# unproved goal - a timeout, an unknown, or a real counter-example - fails it.
# A counter-example Z3 returns is a filed bug, per the M3 exit criterion.
#
# Standalone (no upstream clone, no build). Needs frama-c AND a prover (Z3); with
# neither it exits 127 (SKIPPED, not passed), like fcfish's wp gate.

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"

WP_DIR="$SCRIPT_DIR/tooling/framac/wp"
MANIFEST="$WP_DIR/manifest.txt"
MACHDEP="${FRAMAC_MACHDEP:-gcc_x86_64}"
PROVER="${FRAMAC_WP_PROVER:-z3}"
TIMEOUT="${FRAMAC_WP_TIMEOUT:-30}"

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
    if ! frama-c -wp-detect 2> /dev/null | grep -qi "$PROVER"; then
        harness_log "WP prover '$PROVER' not registered (why3 config detect?) - SKIP"
        exit 127
    fi
    harness_log "frama-c: $(frama-c -version 2> /dev/null); prover: $PROVER"
}

main() {
    harness_init
    local log="$LOG_DIR/framac-wp.log"
    {
        framac_require
        [[ -f "$MANIFEST" ]] || harness_die "missing $MANIFEST"
        harness_log "WP gate over $(grep -cvE '^\s*(#|$)' "$MANIFEST") drivers (prover=$PROVER)"

        local fail=0 d out proved total
        while IFS= read -r d; do
            d="$(trim "$d")"
            [[ -z "$d" || "$d" == \#* ]] && continue
            [[ -f "$WP_DIR/$d" ]] || harness_die "driver not found: $d"

            out="$(cd "$WP_DIR" && frama-c -machdep "$MACHDEP" -wp -wp-prover "$PROVER" \
                -wp-rte -wp-timeout "$TIMEOUT" "$d" 2>&1)" || true
            # "Proved goals:   N / M"
            proved="$(printf '%s\n' "$out" | grep -oE 'Proved goals:[[:space:]]*[0-9]+' | grep -oE '[0-9]+$' | tail -1)"
            total="$(printf '%s\n' "$out" | grep -oE 'Proved goals:[[:space:]]*[0-9]+[[:space:]]*/[[:space:]]*[0-9]+' | grep -oE '[0-9]+$' | tail -1)"
            proved="${proved:-0}"; total="${total:-0}"

            if [[ "$total" != 0 && "$proved" == "$total" ]]; then
                printf ' ok   %-22s %s/%s goals proved\n' "$d" "$proved" "$total"
            else
                printf ' FAIL %-22s %s/%s goals proved\n' "$d" "$proved" "$total"
                printf '%s\n' "$out" | grep -iE 'Timeout|Unknown|Failed|Counter' | sed 's/^/        /' | head -4
                fail=$((fail + 1))
            fi
        done < "$MANIFEST"

        harness_log "WP gate: $fail driver(s) with unproved goals"
        ((fail == 0)) || harness_die "frama-c WP gate FAILED: $fail driver(s) not fully proved"
        harness_log "FRAMAC WP OK"
    } 2>&1 | tee "$log"
    harness_log "log written: $log"
}

main "$@"
