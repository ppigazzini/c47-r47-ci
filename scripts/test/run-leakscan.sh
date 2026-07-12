#!/usr/bin/env bash
# scripts/test/run-leakscan.sh
#
# The pool/GMP leak gate. This is the lane that finds the
# leaks malloc-level tools (ASan/Valgrind) cannot see, because the c47 calculator
# sub-allocates from its own RAM pool.
#
# It syncs the upstream tree at the resolved commit, overlays the not-yet-upstream
# leak-scanner tooling (scripts/test/tooling/leakscan.patch, carried here off the
# test/ram-pool-leak-scanner branch), builds the testSuite, runs --leakscan and
# --keyscan, and compares the findings against scripts/test/leakscan-baseline.txt.
# Any finding not in the baseline (a new pool/GMP leak or a new crash) fails the
# lane; a baseline entry that no longer appears is reported as a likely fix.
#
# Env knobs: UPDATE_BASELINE=1 rewrites the baseline from this run instead of
# gating (use after an intended change). BUILD_DIR overrides the build dir.

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"

TOOLING_PATCH="${TOOLING_PATCH:-$SCRIPT_DIR/tooling/leakscan.patch}"
BASELINE="${BASELINE:-$SCRIPT_DIR/leakscan-baseline.txt}"
BUILD_DIR="${BUILD_DIR:-build.leakscan}"

# Normalise raw --leakscan/--keyscan output to one line per distinct finding,
# keyed on item number (a leak is the same bug across stack types) or sequence
# name, ignoring the variable block/byte counts.
leakscan_normalize() {
    local mode="$1"
    LC_ALL=C awk -v m="$mode" '
        /^LEAK / && match($0, /item=[ ]*[0-9]+/) { n=substr($0,RSTART,RLENGTH); gsub(/ /,"",n); print m" LEAK "n; next }
        /^CRASH / && match($0, /item=[ ]*[0-9]+/) { n=substr($0,RSTART,RLENGTH); gsub(/ /,"",n); print m" CRASH "n; next }
        /^LEAK / && match($0, /seq=[A-Za-z0-9_]+/) { print m" LEAK "substr($0,RSTART,RLENGTH); next }
        /^CRASH / && match($0, /seq=[A-Za-z0-9_]+/) { print m" CRASH "substr($0,RSTART,RLENGTH); next }
    ' | LC_ALL=C sort -u
}

main() {
    harness_init
    local commit
    commit="$(harness_resolve_commit)"
    harness_log "pool/GMP leak gate against upstream $commit"
    harness_sync_upstream "$commit"

    # Overlay the leak-scanner tooling onto the synced upstream tree.
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

    # Build the testSuite. The scanner uses the calculator's own pool/GMP
    # accounting, not ASan, so a plain build is sufficient and fast.
    harness_log "building testSuite ($BUILD_DIR)"
    (
        cd "$UPSTREAM_DIR"
        chmod +x tools/onARaspberry
        local raspberry
        raspberry="$(./tools/onARaspberry)"
        rm -rf "$BUILD_DIR"
        meson setup "$BUILD_DIR" --buildtype=custom \
            -DRASPBERRY="$raspberry" -DDECNUMBER_FASTMUL=true \
            -Dc_args="-Wno-deprecated-declarations" > "$LOG_DIR/leakscan-build.log" 2>&1
        # Generate the version header first: meson does not wire the generated
        # vcs.h as a dependency of every source, so a fresh parallel build of the
        # testSuite-only target can otherwise race and fail to find vcs.h.
        ninja -C "$BUILD_DIR" src/c47/vcs.h >> "$LOG_DIR/leakscan-build.log" 2>&1
        ninja -C "$BUILD_DIR" "-j$(harness_jobs)" src/testSuite/testSuite >> "$LOG_DIR/leakscan-build.log" 2>&1
    ) || harness_die "build failed (see $LOG_DIR/leakscan-build.log)"

    local bin="$UPSTREAM_DIR/$BUILD_DIR/src/testSuite/testSuite"
    [[ -x "$bin" ]] || harness_die "testSuite binary not built"

    # Run the scans from a scratch dir: the testSuite writes calculator state
    # files (REGS.TSV, .bmp, backup.cfg, c47.sav) into its CWD, which must not be
    # the caller's checkout.
    local run_dir="$HARNESS_WORK/run"
    rm -rf "$run_dir"
    mkdir -p "$run_dir"
    harness_log "running --leakscan (item x stack-type pool/GMP scan)"
    (cd "$run_dir" && "$bin" --leakscan) > "$LOG_DIR/leakscan.log" 2>&1 || true
    harness_log "running --keyscan (interactive/subsystem key sequences)"
    (cd "$run_dir" && "$bin" --keyscan) > "$LOG_DIR/keyscan.log" 2>&1 || true

    # The scans exit non-zero by design when they find leaks, so their exit code
    # cannot gate completion. Assert each printed its end-of-run sentinel instead:
    # a scan truncated by a crash/abort mid-corpus emits fewer findings and would
    # otherwise sail through the baseline diff as a false PASS.
    grep -qa '^LEAKSCAN done' "$LOG_DIR/leakscan.log" \
        || harness_die "leakscan did not complete (no 'LEAKSCAN done'): run truncated"
    grep -qa '^KEYSCAN done' "$LOG_DIR/keyscan.log" \
        || harness_die "keyscan did not complete (no 'KEYSCAN done'): run truncated"

    # Compare normalised findings against the baseline.
    {
        leakscan_normalize leakscan < "$LOG_DIR/leakscan.log"
        leakscan_normalize keyscan < "$LOG_DIR/keyscan.log"
    } | LC_ALL=C sort -u > "$LOG_DIR/leakscan-findings.txt"

    if [[ "${UPDATE_BASELINE:-0}" == "1" ]]; then
        cp "$LOG_DIR/leakscan-findings.txt" "$BASELINE.new"
        harness_log "UPDATE_BASELINE=1: new findings written to $BASELINE.new (review and replace the baseline)"
        return 0
    fi

    [[ -f "$BASELINE" ]] || harness_die "no baseline at $BASELINE; run once with UPDATE_BASELINE=1"
    local base_sorted="$LOG_DIR/baseline.sorted"
    # Tolerate an all-comment baseline (every finding fixed): grep -v then matches
    # nothing and exits 1, which pipefail+set -e would turn into a spurious abort.
    { grep -vE '^\s*(#|$)' "$BASELINE" || true; } | LC_ALL=C sort -u > "$base_sorted"

    local new missing
    new="$(LC_ALL=C comm -13 "$base_sorted" "$LOG_DIR/leakscan-findings.txt")"
    missing="$(LC_ALL=C comm -23 "$base_sorted" "$LOG_DIR/leakscan-findings.txt")"

    if [[ -n "$missing" ]]; then
        harness_log "findings in the baseline no longer present (likely fixed - update the baseline):"
        printf ' %s\n' "$missing"
    fi

    if [[ -n "$new" ]]; then
        harness_log "NEW pool/GMP findings not in the baseline (gate FAILED):"
        printf ' %s\n' "$new"
        harness_die "leak gate failed: $(printf '%s\n' "$new" | grep -c .) new finding(s)"
    fi

    harness_log "leak gate PASSED: no new pool/GMP leaks or crashes vs baseline"
}

main "$@"
