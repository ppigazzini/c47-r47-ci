#!/usr/bin/env bash
# scripts/test/run-coverage.sh
#
# The coverage lane - the completeness metric that makes
# "all the leaks" falsifiable by measuring what the leak hunt actually reaches.
#
# It builds the upstream testSuite with gcc coverage instrumentation
# (-Db_coverage=true), exercises it three ways - the 278-file regression corpus,
# the --keyscan key-sequence/subsystem driver, and the --leakscan item sweep -
# then runs gcovr over the c47 sources to produce a line/function coverage map.
# The scanners come from the same tooling patch the leak and per-test lanes use
# (scripts/test/tooling/leakscan.patch), so --keyscan/--leakscan exist.
#
# This lane is report-first: it always publishes the coverage summary, macro
# sector coverage, direct function reachability, and the least-covered leak-prone
# modules (solver, integrator/mathematics, graphing/ui, program engine), so the
# next leak hunt can be aimed at the lowest-covered module. Set COVERAGE_MIN to a
# percentage to additionally gate on overall line coverage.
#
# Env knobs: COVERAGE_MIN (global line-% gate, default 0 = report only),
# SECTOR_GATE=1 with SECTOR_FLOORS (per-sector floors file, default
# coverage-floors.txt) to gate sector regressions, BUILD_DIR overrides the build
# dir.

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"

TOOLING_PATCH="${TOOLING_PATCH:-$SCRIPT_DIR/tooling/leakscan.patch}"
COVERAGE_PATCH="${COVERAGE_PATCH:-$SCRIPT_DIR/tooling/coverage.patch}"
BUILD_DIR="${BUILD_DIR:-build.coverage}"
COVERAGE_MIN="${COVERAGE_MIN:-0}"
# Per-sector ratchet floors. SECTOR_GATE=1 fails the lane when any sector with a
# configured floor drops below it (a coverage regression); report-only otherwise.
SECTOR_FLOORS="${SECTOR_FLOORS:-$SCRIPT_DIR/coverage-floors.txt}"
SECTOR_GATE="${SECTOR_GATE:-0}"

main() {
    harness_init
    local commit
    commit="$(harness_resolve_commit)"
    harness_log "coverage map against upstream $commit"
    harness_sync_upstream "$commit"

    [[ -f "$TOOLING_PATCH" ]] || harness_die "tooling patch not found: $TOOLING_PATCH"
    if ! git -C "$UPSTREAM_DIR" apply --check "$TOOLING_PATCH" 2> /dev/null; then
        harness_die "leakscan.patch does not apply on upstream $commit; rebase the
        test/ram-pool-leak-scanner tooling onto current upstream and regenerate
        scripts/test/tooling/leakscan.patch"
    fi
    git -C "$UPSTREAM_DIR" apply "$TOOLING_PATCH"
    harness_log "overlaid leak-scanner tooling (for --keyscan/--leakscan)"

    # Overlay the coverage corpus extension on top of the leak-scanner tooling: it
    # registers ~70 previously-unexposed functions in the testSuite whitelist,
    # completes the testSuite I/O HAL so the save/restore serializers are testable,
    # and adds corpus test files (stats / store-recall / compare / distributions /
    # curve fitting / round / error / save-restore) that lift whole 0% subsystems.
    # Applies on top of leakscan.patch; regenerate if either side moves.
    if [[ -f "$COVERAGE_PATCH" ]]; then
        python3 "$SCRIPT_DIR/tooling/coverage-patch-audit.py" "$COVERAGE_PATCH" \
            | tee "$LOG_DIR/coverage-patch-audit.txt"
        if ! git -C "$UPSTREAM_DIR" apply --check "$COVERAGE_PATCH" 2> /dev/null; then
            harness_die "coverage.patch does not apply on upstream $commit (after
            leakscan.patch); regenerate scripts/test/tooling/coverage.patch from the
            test/stats-coverage branch rebased onto current upstream"
        fi
        git -C "$UPSTREAM_DIR" apply "$COVERAGE_PATCH"
        harness_log "overlaid coverage corpus extension (whitelist + HAL + tests)"
    fi

    command -v gcovr > /dev/null || harness_die "gcovr not found (pip install gcovr or apt-get install gcovr)"

    harness_setup_xlsxio
    harness_configure_ccache

    harness_log "building testSuite with coverage ($BUILD_DIR)"
    (
        cd "$UPSTREAM_DIR"
        chmod +x tools/onARaspberry
        local raspberry
        raspberry="$(./tools/onARaspberry)"
        rm -rf "$BUILD_DIR"
        # -Db_coverage=true adds --coverage to compile and link (gcc gcno/gcda).
        # ccache is content-keyed so it does not hide coverage flags.
        # -DKEYSCAN_COVERAGE_FLUSH makes the forked --keyscan children flush their
        # gcov counters before _exit; without it their interactive-subsystem
        # coverage (the editors, TAM, the solver entry) is discarded.
        meson setup "$BUILD_DIR" --buildtype=custom \
            -DRASPBERRY="$raspberry" -DDECNUMBER_FASTMUL=true \
            -Db_coverage=true \
            -Dc_args="-Wno-deprecated-declarations -DKEYSCAN_COVERAGE_FLUSH" > "$LOG_DIR/coverage-build.log" 2>&1
        ninja -C "$BUILD_DIR" src/c47/vcs.h >> "$LOG_DIR/coverage-build.log" 2>&1
        ninja -C "$BUILD_DIR" "-j$(harness_jobs)" src/testSuite/testSuite >> "$LOG_DIR/coverage-build.log" 2>&1
        # Generate the sample-program fixture (native tool). The testSuite loads
        # res/testPgms/testPgms.bin from its CWD at startup; without it the
        # program-execution corpus (programs.txt) cannot resolve its labels, so
        # the whole program engine - decode execution, step walking, PEM, and
        # XEQ dispatch - is never exercised and reads as dead in the coverage map.
        ninja -C "$BUILD_DIR" "-j$(harness_jobs)" testPgms >> "$LOG_DIR/coverage-build.log" 2>&1
    ) || harness_die "coverage build failed (see $LOG_DIR/coverage-build.log)"

    local bin="$UPSTREAM_DIR/$BUILD_DIR/src/testSuite/testSuite"
    [[ -x "$bin" ]] || harness_die "testSuite binary not built"
    local test_pgms="$UPSTREAM_DIR/$BUILD_DIR/src/generateTestPgms/testPgms.bin"
    [[ -f "$test_pgms" ]] || harness_die "testPgms.bin fixture not generated"

    # Exercise three ways from a scratch dir (the testSuite writes state files
    # into its CWD). Each run appends to the .gcda counters in $BUILD_DIR.
    local run_dir="$HARNESS_WORK/run"
    rm -rf "$run_dir"
    mkdir -p "$run_dir"
    # Stage the sample programs where the testSuite looks for them (CWD-relative),
    # so programs.txt actually runs and the program engine is covered.
    mkdir -p "$run_dir/res/testPgms"
    cp "$test_pgms" "$run_dir/res/testPgms/testPgms.bin"
    harness_log "running the regression corpus (278 files)"
    (cd "$run_dir" && "$bin" "$UPSTREAM_DIR/src/testSuite/tests/testSuiteList.txt") > "$LOG_DIR/coverage-suite.log" 2>&1 || true
    harness_log "running --keyscan (key-sequence/subsystem driver)"
    (cd "$run_dir" && "$bin" --keyscan) > "$LOG_DIR/coverage-keyscan.log" 2>&1 || true
    harness_log "running --leakscan (item sweep)"
    (cd "$run_dir" && "$bin" --leakscan) > "$LOG_DIR/coverage-leakscan.log" 2>&1 || true

    # Build the coverage map over the c47 calculator sources only: exclude the
    # testSuite harness, generated headers, and third-party decNumber.
    harness_log "generating coverage report (gcovr)"
    local cov_txt="$LOG_DIR/coverage-summary.txt"
    local cov_json="$LOG_DIR/coverage.json"
    local cov_html_dir="$LOG_DIR/coverage-html"
    rm -rf "$cov_html_dir"
    mkdir -p "$cov_html_dir"
    local cov_html="$cov_html_dir/index.html"
    # gcc inflates loop counters in a few hot files (gcov bug 68080); tell gcovr
    # to warn rather than abort on those "suspicious hits".
    gcovr --root "$UPSTREAM_DIR" \
        --gcov-executable "gcov" \
        --gcov-ignore-parse-errors suspicious_hits.warn_once_per_file \
        --filter "$UPSTREAM_DIR/src/c47/" \
        --exclude '.*/decNumber/.*' \
        --exclude '.*/testSuite/.*' \
        --exclude '.*vcs\.h' \
        --print-summary \
        --txt "$cov_txt" \
        --json-summary "$cov_json" \
        --html-details "$cov_html" \
        > "$LOG_DIR/coverage-gcovr.log" 2>&1 \
        || harness_die "gcovr failed (see $LOG_DIR/coverage-gcovr.log)"

    # Overall line coverage percentage (from the gcovr JSON summary).
    local line_pct
    line_pct="$(python3 -c 'import json,sys; print("%.2f" % json.load(open(sys.argv[1]))["line_percent"])' "$cov_json" 2> /dev/null || echo "0")"
    harness_log "overall c47 line coverage: ${line_pct}%"

    # Least-covered leak-prone modules: rank c47 source files by line coverage and
    # surface the lowest in the leak-prone subsystems so the next hunt is aimed.
    harness_log "least-covered leak-prone files (solver / mathematics / ui / programming):"
    python3 - "$cov_json" <<'PY' | tee "$LOG_DIR/coverage-underspent.txt"
import json, sys
data = json.load(open(sys.argv[1]))
prone = ("/solver/", "/mathematics/", "/ui/", "/programming/")
rows = []
for f in data.get("files", []):
    name = f["filename"]
    if any(p in name for p in prone):
        lp = f["line_percent"]
        lines = f.get("line_total", f.get("lines", 0))
        rows.append((lp, lines, name))
rows.sort(key=lambda r: (r[0], -r[1]))
for lp, lines, name in rows[:15]:
    print(f" {lp:6.2f}% {lines:5d} lines {name}")
PY

    local cov_sectors="$LOG_DIR/coverage-sectors.txt"
    harness_log "macro sector coverage:"
    # Always publish the sector report. When SECTOR_GATE=1 and a floors file
    # exists, also pass the floors so a sector below its floor exits non-zero.
    local sector_rc=0
    if [[ "$SECTOR_GATE" == "1" && -f "$SECTOR_FLOORS" ]]; then
        python3 "$SCRIPT_DIR/tooling/coverage-sectors.py" "$cov_json" "$SECTOR_FLOORS" | tee "$cov_sectors" || sector_rc=$?
    else
        python3 "$SCRIPT_DIR/tooling/coverage-sectors.py" "$cov_json" | tee "$cov_sectors"
    fi

    local reachability="$LOG_DIR/function-reachability.txt"
    harness_log "direct function reachability:"
    python3 "$SCRIPT_DIR/tooling/function-reachability.py" "$UPSTREAM_DIR" | tee "$reachability"

    harness_log "artifacts: $cov_txt , $cov_json , $cov_sectors , $reachability , $cov_html (and ci-artifacts upload)"

    # Optional global gate: fail if overall line coverage is below COVERAGE_MIN.
    if [[ "$COVERAGE_MIN" != "0" ]]; then
        awk -v c="$line_pct" -v m="$COVERAGE_MIN" 'BEGIN { exit !(c + 0 >= m + 0) }' \
            || harness_die "coverage gate failed: ${line_pct}% < ${COVERAGE_MIN}% required"
        harness_log "coverage gate PASSED: ${line_pct}% >= ${COVERAGE_MIN}%"
    else
        harness_log "coverage map published (report-only; set COVERAGE_MIN to gate)"
    fi

    # Optional per-sector ratchet gate: sector_rc is non-zero when a sector fell
    # below its floor (a regression). Fail last so the full report is published.
    if [[ "$SECTOR_GATE" == "1" ]]; then
        [[ "$sector_rc" == "0" ]] || harness_die "sector coverage gate failed (see the sector report above; a sector dropped below its floor in $SECTOR_FLOORS)"
        harness_log "sector coverage gate PASSED (no sector below its floor)"
    fi
}

main "$@"
