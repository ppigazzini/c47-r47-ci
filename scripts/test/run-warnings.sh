#!/usr/bin/env bash
# scripts/test/run-warnings.sh
#
# The hardening-warning lane. It rebuilds the upstream
# testSuite with the OpenSSF Compiler Hardening warning set (plus
# -ftrivial-auto-var-init=zero) and reports the warnings, so new ones surface as
# they are introduced. Report-first against a baseline count; set WARN_GATE=1 to
# fail when the count rises above the baseline.
#
# Env knobs: WARN_GATE (1 to gate on new warnings), BUILD_DIR, BASELINE.

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"

BUILD_DIR="${BUILD_DIR:-build.warnings}"
BASELINE="${BASELINE:-$SCRIPT_DIR/warnings-baseline.txt}"
WARN_GATE="${WARN_GATE:-0}"

# OpenSSF Compiler Hardening Guide warning/codegen set (the high-signal subset;
# -Wconversion/-Wsign-conversion are omitted as baseline noise for a tracked
# lane). -ftrivial-auto-var-init=zero is a hardening codegen flag, included for hardening.
WARN_FLAGS="-Wall -Wextra -Wformat -Wformat=2 -Wformat-security \
-Wimplicit-fallthrough -Wshadow -Wundef -Wvla -Walloca -Wcast-qual \
-Wnull-dereference -Wdouble-promotion -Wtrampolines -Wstrict-overflow=2 \
-ftrivial-auto-var-init=zero -Wno-deprecated-declarations"

main() {
    harness_init
    local commit
    commit="$(harness_resolve_commit)"
    harness_log "hardening-warning build against upstream $commit"
    harness_sync_upstream "$commit"

    harness_setup_xlsxio
    harness_configure_ccache

    harness_log "building testSuite with the OpenSSF warning set ($BUILD_DIR)"
    (
        cd "$UPSTREAM_DIR"
        chmod +x tools/onARaspberry
        local raspberry
        raspberry="$(./tools/onARaspberry)"
        rm -rf "$BUILD_DIR"
        meson setup "$BUILD_DIR" --buildtype=custom \
            -DRASPBERRY="$raspberry" -DDECNUMBER_FASTMUL=true \
            -Dc_args="$WARN_FLAGS" > "$LOG_DIR/warnings-setup.log" 2>&1
        ninja -C "$BUILD_DIR" src/c47/vcs.h >> "$LOG_DIR/warnings-setup.log" 2>&1
        # Capture compile warnings; do not let a warning fail the build (no -Werror).
        ninja -C "$BUILD_DIR" "-j$(harness_jobs)" src/testSuite/testSuite > "$LOG_DIR/warnings-build.log" 2>&1 || true
    ) || harness_die "warning build setup failed (see $LOG_DIR/warnings-setup.log)"

    # One normalised line per distinct warning site, keyed on c47 file:line and
    # the -W category, ignoring absolute paths and column numbers.
    grep -hE ' warning: ' "$LOG_DIR/warnings-build.log" \
        | grep -E 'src/c47/' \
        | sed -E 's#^.*(src/c47/[^:]+):([0-9]+):[0-9]+: warning: .*(\[-W[a-z=-]+\]).*#\1:\2 \3#' \
        | grep -E '^src/c47/' \
        | LC_ALL=C sort -u > "$LOG_DIR/warnings-found.txt" || true

    local n
    n="$(wc -l < "$LOG_DIR/warnings-found.txt" | tr -d ' ')"
    harness_log "distinct c47 hardening warnings: $n"
    # Top categories, to aim cleanups.
    harness_log "by category:"
    sed -E 's#^.* (\[-W[a-z=-]+\])$#\1#' "$LOG_DIR/warnings-found.txt" \
        | LC_ALL=C sort | uniq -c | LC_ALL=C sort -rn | head -10 | sed 's/^/ /'

    if [[ "${UPDATE_BASELINE:-0}" == "1" ]]; then
        cp "$LOG_DIR/warnings-found.txt" "$BASELINE.new"
        harness_log "UPDATE_BASELINE=1: new warning set written to $BASELINE.new"
        return 0
    fi

    [[ -f "$BASELINE" ]] || harness_die "no baseline at $BASELINE; run once with UPDATE_BASELINE=1"
    local base_sorted="$LOG_DIR/warnings-baseline.sorted"
    # Tolerate an all-comment baseline (every warning fixed): grep -v then matches nothing and exits 1, which pipefail+set -e would turn into a spurious abort.
    { grep -vE '^\s*(#|$)' "$BASELINE" || true; } | LC_ALL=C sort -u > "$base_sorted"

    local new
    new="$(LC_ALL=C comm -13 "$base_sorted" "$LOG_DIR/warnings-found.txt")"
    if [[ -n "$new" ]]; then
        harness_log "NEW hardening warnings not in the baseline:"
        printf ' %s\n' "$new"
        [[ "$WARN_GATE" == "1" ]] && harness_die "warning gate failed: $(printf '%s\n' "$new" | grep -c .) new warning(s)"
        harness_log "report-first: not failing the lane (set WARN_GATE=1 to gate)"
    else
        harness_log "no new hardening warnings vs baseline"
    fi
}

main "$@"
