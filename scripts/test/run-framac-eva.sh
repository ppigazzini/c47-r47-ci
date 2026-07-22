#!/usr/bin/env bash
# scripts/test/run-framac-eva.sh
#
# Frama-C Eva/RTE runtime-safety gate (Milestone M1; see __DEV REPORT-15).
# Runs the extracted-kernel harnesses under scripts/test/tooling/framac/eva/ and
# holds each to the alarm count pinned in eva/ledger.txt. A PROVED harness (0
# alarms) that grows an alarm, or any harness whose count exceeds its ledger
# value, fails the gate: that is a newly exposed runtime error in the modelled
# kernel. A count below the ledger is reported so the ledger can be tightened.
#
# The harnesses are STANDALONE (fcfish's eva_harness.c pattern): each reproduces
# a c43 kernel verbatim with its globals modelled and cites the source lines it
# mirrors, so this gate needs NO upstream clone and NO build - only frama-c.
#
# Optional infrastructure: with no opam switch / no frama-c it exits 127 and is
# reported SKIPPED, not passed.

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"

EVA_DIR="$SCRIPT_DIR/tooling/framac/eva"
LEDGER="$EVA_DIR/ledger.txt"
MACHDEP="${FRAMAC_MACHDEP:-gcc_x86_64}"
SLEVEL="${FRAMAC_EVA_SLEVEL:-500}"

# Quote-safe whitespace trim (xargs mis-parses apostrophes in the ledger notes).
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

# Echo the alarm count Eva reports for one harness (0 if it reports none).
eva_alarm_count() {
    local h="$1" out
    out="$(cd "$EVA_DIR" && frama-c -machdep "$MACHDEP" -rte -eva \
        -eva-no-show-progress -eva-slevel "$SLEVEL" "$h" 2>&1)" || true
    printf '%s\n' "$out" | grep -oE '[0-9]+ alarms? generated' | grep -oE '^[0-9]+' | head -1
}

main() {
    harness_init
    local log="$LOG_DIR/framac-eva.log"
    {
        framac_require
        [[ -f "$LEDGER" ]] || harness_die "missing $LEDGER"
        harness_log "Eva/RTE gate (slevel=$SLEVEL) over $(grep -cvE '^\s*(#|$)' "$LEDGER") harnesses"

        local fail=0 tighten=0 line h exp cls note actual
        while IFS='|' read -r h exp cls note; do
            h="$(trim "$h")"
            [[ -z "$h" || "$h" == \#* ]] && continue
            exp="$(trim "$exp")"
            cls="$(trim "$cls")"
            [[ -f "$EVA_DIR/$h" ]] || harness_die "harness not found: $h"

            actual="$(eva_alarm_count "$h")"; actual="${actual:-0}"
            if ((actual > exp)); then
                printf ' FAIL %-20s %-13s alarms=%s expected<=%s  REGRESSION\n' "$h" "$cls" "$actual" "$exp"
                fail=$((fail + 1))
            elif ((actual < exp)); then
                printf ' TGHT %-20s %-13s alarms=%s expected=%s   (ledger can tighten)\n' "$h" "$cls" "$actual" "$exp"
                tighten=$((tighten + 1))
            else
                printf ' ok   %-20s %-13s alarms=%s\n' "$h" "$cls" "$actual"
            fi
        done < "$LEDGER"

        harness_log "Eva/RTE gate: $fail regression(s), $tighten tightenable"
        ((fail == 0)) || harness_die "frama-c Eva gate FAILED: $fail harness(es) grew new alarms"
        harness_log "FRAMAC EVA OK"
    } 2>&1 | tee "$log"
    harness_log "log written: $log"
}

main "$@"
