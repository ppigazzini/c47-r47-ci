#!/usr/bin/env bash
# scripts/test/run-testmem.sh
#
# Per-test pool/GMP attribution. Runs the upstream test
# corpus under the testSuite --testmem mode, which clears the working state after
# each case and reports any case that grew the RAM pool or GMP past the
# high-water - turning the exit-only GMP check into per-operation attribution and
# finding pool leaks invisible to AddressSanitizer and Valgrind.
#
# It compares the growth cases against scripts/test/testmem-baseline.txt and fails
# on any growth case not in the baseline. The scanner tooling is the same patch
# the leak gate uses (scripts/test/tooling/leakscan.patch).
#
# Env knobs: UPDATE_BASELINE=1 rewrites the baseline from this run. BUILD_DIR
# overrides the build dir.

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"

TOOLING_PATCH="${TOOLING_PATCH:-$SCRIPT_DIR/tooling/leakscan.patch}"
BASELINE="${BASELINE:-$SCRIPT_DIR/testmem-baseline.txt}"
BUILD_DIR="${BUILD_DIR:-build.testmem}"

# Normalise --testmem output to one line per growth case, keyed on the test file
# and its IN parameter line (the case identity), ignoring the block/byte amounts.
testmem_normalize() {
    LC_ALL=C awk '
        /^TESTMEM GROWTH file=/ { match($0, /file=[^ ]+/); f=substr($0, RSTART+5, RLENGTH-5); next }
        /^ case: / { c=$0; sub(/^ case: /, "", c); if(f != "") print f"|"c; f="" }
    ' | LC_ALL=C sort -u
}

main() {
    harness_init
    local commit
    commit="$(harness_resolve_commit)"
    harness_log "per-test pool/GMP attribution against upstream $commit"
    harness_sync_upstream "$commit"

    [[ -f "$TOOLING_PATCH" ]] || harness_die "tooling patch not found: $TOOLING_PATCH"
    if ! git -C "$UPSTREAM_DIR" apply --check "$TOOLING_PATCH" 2> /dev/null; then
        harness_die "leakscan.patch does not apply on upstream $commit; rebase the
        test/ram-pool-leak-scanner tooling onto current upstream and regenerate
        scripts/test/tooling/leakscan.patch"
    fi
    git -C "$UPSTREAM_DIR" apply "$TOOLING_PATCH"
    harness_log "overlaid leak-scanner tooling"

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
            -Dc_args="-Wno-deprecated-declarations" > "$LOG_DIR/testmem-build.log" 2>&1
        ninja -C "$BUILD_DIR" src/c47/vcs.h >> "$LOG_DIR/testmem-build.log" 2>&1
        ninja -C "$BUILD_DIR" "-j$(harness_jobs)" src/testSuite/testSuite >> "$LOG_DIR/testmem-build.log" 2>&1
    ) || harness_die "build failed (see $LOG_DIR/testmem-build.log)"

    local bin="$UPSTREAM_DIR/$BUILD_DIR/src/testSuite/testSuite"
    [[ -x "$bin" ]] || harness_die "testSuite binary not built"

    # Run from a scratch dir (the testSuite writes state files into its CWD) and
    # from the upstream tree so the relative test list path resolves.
    local run_dir="$HARNESS_WORK/run"
    rm -rf "$run_dir"
    mkdir -p "$run_dir"
    harness_log "running --testmem over the corpus"
    (cd "$run_dir" && "$bin" --testmem "$UPSTREAM_DIR/src/testSuite/tests/testSuiteList.txt") > "$LOG_DIR/testmem.log" 2>&1 || true
    grep -E '^TESTMEM done' "$LOG_DIR/testmem.log" || true

    testmem_normalize < "$LOG_DIR/testmem.log" > "$LOG_DIR/testmem-growth.txt"

    if [[ "${UPDATE_BASELINE:-0}" == "1" ]]; then
        cp "$LOG_DIR/testmem-growth.txt" "$BASELINE.new"
        harness_log "UPDATE_BASELINE=1: new growth set written to $BASELINE.new (review and replace the baseline)"
        return 0
    fi

    local base_sorted="$LOG_DIR/testmem-baseline.sorted"
    grep -vE '^\s*(#|$)' "$BASELINE" | LC_ALL=C sort -u > "$base_sorted"

    local new missing
    new="$(LC_ALL=C comm -13 "$base_sorted" "$LOG_DIR/testmem-growth.txt")"
    missing="$(LC_ALL=C comm -23 "$base_sorted" "$LOG_DIR/testmem-growth.txt")"

    if [[ -n "$missing" ]]; then
        harness_log "baseline growth cases no longer present (likely fixed - update the baseline):"
        printf ' %s\n' "$missing"
    fi
    if [[ -n "$new" ]]; then
        harness_log "NEW per-test pool/GMP growth not in the baseline (gate FAILED):"
        printf ' %s\n' "$new"
        harness_die "per-test memory gate failed: $(printf '%s\n' "$new" | grep -c .) new growth case(s)"
    fi

    harness_log "per-test memory gate PASSED: no new pool/GMP growth vs baseline"
}

main "$@"
