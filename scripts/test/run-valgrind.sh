#!/usr/bin/env bash
# scripts/test/run-valgrind.sh
#
# The Valgrind lane. memcheck catches malloc-level errors
# and leaks the pool scanner cannot see, because c47 sub-allocates from its
# own ram[] block - but some paths (GMP, the HAL) do use malloc, and third-party
# init does too. A curated suppression file (tooling/valgrind.supp) silences the
# known GTK/GLib/GMP noise so a real c47 malloc-level finding stands out.
#
# Report-first against a baseline of known suppressed-error kinds; set
# VALGRIND_GATE=1 to fail on a new definitely-lost block or invalid access.
#
# Env knobs: VALGRIND_LIST (test list, default the full corpus), VALGRIND_GATE,
# BUILD_DIR, BASELINE.

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"

SUPP="${SUPP:-$SCRIPT_DIR/tooling/valgrind.supp}"
BASELINE="${BASELINE:-$SCRIPT_DIR/valgrind-baseline.txt}"
BUILD_DIR="${BUILD_DIR:-build.valgrind}"
VALGRIND_GATE="${VALGRIND_GATE:-0}"

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
        valgrind --tool=memcheck --leak-check=full --show-leak-kinds=definite,indirect \
            --errors-for-leak-kinds=definite --error-exitcode=0 \
            --suppressions="$SUPP" --gen-suppressions=no \
            "$bin" "$list"
    ) > "$LOG_DIR/valgrind.log" 2>&1 || true

    # Normalise to one line per distinct c47 error site: the memcheck error kind
    # plus the first c47 frame, ignoring addresses.
    awk '
        /^==[0-9]+== (Invalid|Use of|Conditional|.*lost in loss record|.*definitely lost)/ { kind=$0; sub(/^==[0-9]+== */,"",kind); pending=1 }
        pending && /by 0x|at 0x/ && /src\/c47\// {
            site=$0; sub(/^.*\(/,"",site); sub(/\).*$/,"",site);
            if(site ~ /src\/c47\//) { print kind " @ " site; pending=0 }
        }
    ' "$LOG_DIR/valgrind.log" | LC_ALL=C sort -u > "$LOG_DIR/valgrind-found.txt" || true

    # Headline counts from memcheck's own summary.
    grep -E "definitely lost|indirectly lost|ERROR SUMMARY" "$LOG_DIR/valgrind.log" | tail -3 | sed 's/^/ /' || true
    local n
    n="$(wc -l < "$LOG_DIR/valgrind-found.txt" | tr -d ' ')"
    harness_log "distinct c47 memcheck sites (definite/invalid): $n"

    if [[ "${UPDATE_BASELINE:-0}" == "1" ]]; then
        cp "$LOG_DIR/valgrind-found.txt" "$BASELINE.new"
        harness_log "UPDATE_BASELINE=1: new site set written to $BASELINE.new"
        return 0
    fi

    [[ -f "$BASELINE" ]] || harness_die "no baseline at $BASELINE; run once with UPDATE_BASELINE=1"
    local base_sorted="$LOG_DIR/valgrind-baseline.sorted"
    grep -vE '^\s*(#|$)' "$BASELINE" | LC_ALL=C sort -u > "$base_sorted"

    local new
    new="$(LC_ALL=C comm -13 "$base_sorted" "$LOG_DIR/valgrind-found.txt")"
    if [[ -n "$new" ]]; then
        harness_log "NEW c47 memcheck sites not in the baseline:"
        printf ' %s\n' "$new"
        [[ "$VALGRIND_GATE" == "1" ]] && harness_die "valgrind gate failed: $(printf '%s\n' "$new" | grep -c .) new site(s)"
        harness_log "report-first: not failing the lane (set VALGRIND_GATE=1 to gate)"
    else
        harness_log "no new c47 memcheck sites vs baseline"
    fi
}

main "$@"
