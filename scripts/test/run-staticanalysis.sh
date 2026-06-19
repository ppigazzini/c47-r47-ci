#!/usr/bin/env bash
# scripts/test/run-staticanalysis.sh
#
# The static-analysis lane. It runs cppcheck over the c47
# sources to flag bug-class issues (null derefs, uninitialised use, buffer
# bounds, leaks, integer handling) without running the code - widening the net
# of findings that flow into the leak audit and the bug reports.
#
# Report-first against a baseline; set ANALYSIS_GATE=1 to fail on a new finding.
# cppcheck is the gcc/clang-agnostic analyzer here; GCC -fanalyzer and clang
# scan-build are heavier passes left as follow-ups.
#
# Env knobs: ANALYSIS_GATE (1 to gate), BASELINE, CPPCHECK_ENABLE.

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"

BASELINE="${BASELINE:-$SCRIPT_DIR/cppcheck-baseline.txt}"
SUPPRESSIONS="${SUPPRESSIONS:-$SCRIPT_DIR/tooling/cppcheck-suppressions.txt}"
ANALYSIS_GATE="${ANALYSIS_GATE:-0}"
CPPCHECK_ENABLE="${CPPCHECK_ENABLE:-warning,performance,portability}"

main() {
    harness_init
    command -v cppcheck > /dev/null || harness_die "cppcheck required (apt-get install cppcheck)"

    local commit
    commit="$(harness_resolve_commit)"
    harness_log "cppcheck static analysis against upstream $commit"
    harness_sync_upstream "$commit"

    harness_log "running cppcheck (--enable=$CPPCHECK_ENABLE) over src/c47"
    # Source-level analysis; no build needed. Exclude third-party decNumber.
    # --error-exitcode=0 so we collect and baseline rather than abort.
    local suppr_arg=()
    [[ -f "$SUPPRESSIONS" ]] && suppr_arg=("--suppressions-list=$SUPPRESSIONS")
    cppcheck \
        --enable="$CPPCHECK_ENABLE" \
        --inline-suppr \
        "${suppr_arg[@]}" \
        --suppress=missingInclude \
        --suppress=missingIncludeSystem \
        --suppress=unmatchedSuppression \
        --suppress=unknownMacro \
        --suppress=checkersReport \
        --suppress=normalCheckLevelMaxBranches \
        -i "$UPSTREAM_DIR/src/c47/decNumber" \
        --quiet --error-exitcode=0 \
        -j "$(harness_jobs)" \
        --template='{file}:{line}: {id}' \
        "$UPSTREAM_DIR/src/c47" > "$LOG_DIR/cppcheck.out" 2> "$LOG_DIR/cppcheck.err" || true

    # Normalise to one line per distinct site, keyed on c47 file:line and check id.
    sed -E "s#^$UPSTREAM_DIR/##" "$LOG_DIR/cppcheck.err" \
        | grep -E '^src/c47/.*: [a-zA-Z]' \
        | LC_ALL=C sort -u > "$LOG_DIR/cppcheck-found.txt" || true

    local n
    n="$(wc -l < "$LOG_DIR/cppcheck-found.txt" | tr -d ' ')"
    harness_log "distinct c47 cppcheck findings: $n"
    harness_log "by check id:"
    sed -E 's#^.*: ([a-zA-Z0-9_]+)$#\1#' "$LOG_DIR/cppcheck-found.txt" \
        | LC_ALL=C sort | uniq -c | LC_ALL=C sort -rn | head -10 | sed 's/^/ /'

    if [[ "${UPDATE_BASELINE:-0}" == "1" ]]; then
        cp "$LOG_DIR/cppcheck-found.txt" "$BASELINE.new"
        harness_log "UPDATE_BASELINE=1: new finding set written to $BASELINE.new"
        return 0
    fi

    [[ -f "$BASELINE" ]] || harness_die "no baseline at $BASELINE; run once with UPDATE_BASELINE=1"
    local base_sorted="$LOG_DIR/cppcheck-baseline.sorted"
    grep -vE '^\s*(#|$)' "$BASELINE" | LC_ALL=C sort -u > "$base_sorted"

    local new
    new="$(LC_ALL=C comm -13 "$base_sorted" "$LOG_DIR/cppcheck-found.txt")"
    if [[ -n "$new" ]]; then
        harness_log "NEW c47 cppcheck findings not in the baseline:"
        printf ' %s\n' "$new"
        [[ "$ANALYSIS_GATE" == "1" ]] && harness_die "static-analysis gate failed: $(printf '%s\n' "$new" | grep -c .) new finding(s)"
        harness_log "report-first: not failing the lane (set ANALYSIS_GATE=1 to gate)"
    else
        harness_log "no new c47 cppcheck findings vs baseline"
    fi
}

main "$@"
