#!/usr/bin/env bash
# scripts/test/run-valgrind.sh
#
# The Valgrind lane: a hard memory gate over the full testSuite corpus.
#
# memcheck catches malloc-level errors and leaks the pool scanner cannot see,
# because c47 sub-allocates from its own ram[] block - but some paths (GMP, the
# HAL) do use malloc, and third-party init does too. A curated suppression file
# (tooling/valgrind.supp) silences only the known GTK/GLib/GMP library noise.
#
# Strong by design: full corpus, --track-origins=yes, and leaks of every kind
# (definite/indirect/possible) are errors. Each finding is attributed to the c47
# source file it occurs in - the innermost frame for an access error, the first
# c47 frame in the allocation stack for a leak. Any c47-owned uninitialised
# read, invalid access, or leak that is not in the tracked baseline fails the
# lane. Third-party frames (decNumberICU, GTK, GMP, libc) are surfaced in the
# uploaded log but never gate.
#
# Env knobs: VALGRIND_GATE (default 1; set 0 to report without failing),
# VALGRIND_LIST (test list, default the full corpus), BUILD_DIR, BASELINE,
# UPDATE_BASELINE=1 to regenerate the baseline from the current run.

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"

SUPP="${SUPP:-$SCRIPT_DIR/tooling/valgrind.supp}"
BASELINE="${BASELINE:-$SCRIPT_DIR/valgrind-baseline.txt}"
BUILD_DIR="${BUILD_DIR:-build.valgrind}"
VALGRIND_GATE="${VALGRIND_GATE:-1}"

main() {
    harness_init
    command -v valgrind > /dev/null || harness_die "valgrind required (apt-get install valgrind)"

    local commit
    commit="$(harness_resolve_commit)"
    harness_log "valgrind memcheck against upstream $commit"
    harness_sync_upstream "$commit"

    harness_setup_xlsxio
    harness_configure_ccache

    harness_log "building testSuite ($BUILD_DIR)"
    (
        cd "$UPSTREAM_DIR"
        chmod +x tools/onARaspberry
        local raspberry
        raspberry="$(./tools/onARaspberry)"
        rm -rf "$BUILD_DIR"
        meson setup "$BUILD_DIR" --buildtype=custom \
            -DRASPBERRY="$raspberry" -DDECNUMBER_FASTMUL=true \
            -Dc_args="-g -Wno-deprecated-declarations" > "$LOG_DIR/valgrind-build.log" 2>&1
        ninja -C "$BUILD_DIR" src/c47/vcs.h >> "$LOG_DIR/valgrind-build.log" 2>&1
        ninja -C "$BUILD_DIR" "-j$(harness_jobs)" src/testSuite/testSuite >> "$LOG_DIR/valgrind-build.log" 2>&1
    ) || harness_die "build failed (see $LOG_DIR/valgrind-build.log)"

    local bin="$UPSTREAM_DIR/$BUILD_DIR/src/testSuite/testSuite"
    [[ -x "$bin" ]] || harness_die "testSuite binary not built"

    local list="${VALGRIND_LIST:-$UPSTREAM_DIR/src/testSuite/tests/testSuiteList.txt}"
    local run_dir="$HARNESS_WORK/run"
    rm -rf "$run_dir"
    mkdir -p "$run_dir"

    harness_log "running testSuite under memcheck (list: $(basename "$list"))"
    (
        cd "$run_dir"
        valgrind --tool=memcheck \
            --leak-check=full \
            --show-leak-kinds=definite,indirect,possible \
            --errors-for-leak-kinds=definite,indirect,possible \
            --track-origins=yes \
            --error-exitcode=0 \
            --suppressions="$SUPP" --gen-suppressions=no \
            "$bin" "$list"
    ) > "$LOG_DIR/valgrind.log" 2>&1 || true

    # Ownership map: every c47 source basename in the synced tree. memcheck prints
    # basenames, so a finding is c47-owned when the relevant frame names one of
    # these files. Third-party frames (decNumberICU, GTK, GMP, libc) are excluded
    # from the gate but stay in the uploaded log.
    local c47_names="$LOG_DIR/c47-basenames.txt"
    find "$UPSTREAM_DIR/src/c47" \( -name '*.c' -o -name '*.h' \) -printf '%f\n' \
        | LC_ALL=C sort -u > "$c47_names"

    # Normalise to one line per distinct c47 error site: "<kind> @ <file>:<line>".
    # Access errors are attributed to the innermost frame (where the bad access
    # happens); leaks to the first c47 frame in the allocation stack, past the
    # allocator. Third-party-rooted findings are dropped here, not weakened: the
    # full memcheck report is preserved in valgrind.log.
    awk '
        NR == FNR { c47[$0] = 1; next }
        /^==[0-9]+== (Invalid|Use of|Conditional|Syscall|Mismatched|Source and destination|.*lost)/ {
            kind = $0; sub(/^==[0-9]+== */, "", kind)
            isleak = (kind ~ /lost/); pending = 1; first = 1; next
        }
        pending && /^==[0-9]+== +(at|by) 0x/ {
            f = $0; sub(/^.*\(/, "", f); sub(/\).*$/, "", f)   # f = "file:line"
            bn = f; sub(/:.*/, "", bn)
            if (isleak) {
                if (bn in c47) { print kind " @ " f; pending = 0 }
            } else {
                if (first && (bn in c47)) print kind " @ " f
                pending = 0          # access errors: only the innermost frame counts
            }
            first = 0
        }
    ' "$c47_names" "$LOG_DIR/valgrind.log" | LC_ALL=C sort -u > "$LOG_DIR/valgrind-found.txt" || true

    # Headline counts from memcheck's own summary.
    grep -E "definitely lost|indirectly lost|possibly lost|ERROR SUMMARY" "$LOG_DIR/valgrind.log" | tail -4 | sed 's/^/ /' || true
    local n
    n="$(wc -l < "$LOG_DIR/valgrind-found.txt" | tr -d ' ')"
    harness_log "distinct c47 memcheck sites (uninit/invalid/leak): $n"

    if [[ "${UPDATE_BASELINE:-0}" == "1" ]]; then
        cp "$LOG_DIR/valgrind-found.txt" "$BASELINE.new"
        harness_log "UPDATE_BASELINE=1: new site set written to $BASELINE.new"
        return 0
    fi

    [[ -f "$BASELINE" ]] || harness_die "no baseline at $BASELINE; run once with UPDATE_BASELINE=1"
    local base_sorted="$LOG_DIR/valgrind-baseline.sorted"
    # The baseline holds only comments while c47 stays malloc-clean, so tolerate
    # a no-match grep instead of letting pipefail abort the lane.
    { grep -vE '^\s*(#|$)' "$BASELINE" || true; } | LC_ALL=C sort -u > "$base_sorted"

    local new
    new="$(LC_ALL=C comm -13 "$base_sorted" "$LOG_DIR/valgrind-found.txt")"
    if [[ -n "$new" ]]; then
        harness_log "NEW c47 memcheck sites not in the baseline:"
        printf ' %s\n' "$new"
        if [[ "$VALGRIND_GATE" == "1" ]]; then
            harness_die "valgrind gate failed: $(printf '%s\n' "$new" | grep -c .) new c47 site(s)"
        fi
        harness_log "VALGRIND_GATE=0: reporting only, not failing the lane"
    else
        harness_log "no new c47 memcheck sites vs baseline"
    fi
}

main "$@"
