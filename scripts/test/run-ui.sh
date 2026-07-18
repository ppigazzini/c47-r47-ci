#!/usr/bin/env bash
# scripts/test/run-ui.sh
#
# The UI lane: the keyboard, softmenu and matrix-editor paths that no other lane
# can reach. The behavioural corpus calls functions directly and the testSuite
# has no DSL, so anything that only a keypress can drive - TAM parameter entry,
# softmenu decode, the matrix editor's cursor - is untested everywhere else.
#
# This lane needs no upstream patch. press is the one DSL command that requires
# GTK, and --headless is GTK-less by design, so a keyboard test runs the GTK
# front end (c47) WITHOUT --headless, under a virtual X server. Upstream states
# this in res/SCRIPTS/cli_automation_examples.txt: "press, which needs GTK: c47
# only". Do not reach for t47 here - it will report the command as unknown.
#
# c47 returns the script's exit status when given --script (c47-gtk.c:540-549),
# so the gate is simply that status. Each scripts/test/ui/*.t47 file is one test
# and must exit 0; the lane fails on the first that does not.
#
# Env knobs: UI_TESTS overrides the glob of test files. BUILD_TIMEOUT caps a
# single test run (a GTK dialog with no one to dismiss it would otherwise hang
# the lane rather than fail it - see the file-chooser note below).

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"

UI_DIR="${UI_DIR:-$SCRIPT_DIR/ui}"
TEST_TIMEOUT="${TEST_TIMEOUT:-120}"

main() {
    harness_init
    local log="$LOG_DIR/ui.log"
    {
        local commit
        commit="$(harness_resolve_commit)"
        harness_log "UI lane against upstream $commit"
        harness_sync_upstream "$commit"
        # Same preamble the other build lanes use. Whether "make simc47 t47"
        # strictly needs xlsxio was not established - it is present on the
        # machine this lane was developed on, so its absence was never tested.
        # The helper is cached, so calling it is cheap insurance.
        harness_setup_xlsxio
        harness_configure_ccache

        command -v xvfb-run > /dev/null \
            || harness_die "xvfb-run not found; the UI lane needs a virtual X server"

        # Build both front ends. "make simc47 t47" exactly: a bare "make t47"
        # builds the R47-based t47 instead. c47 is the one this lane runs.
        harness_log "building simulator (make simc47 t47)"
        make -C "$UPSTREAM_DIR" simc47 t47 "-j$(harness_jobs)" \
            > "$LOG_DIR/ui-build.log" 2>&1 \
            || harness_die "simulator build failed; see $LOG_DIR/ui-build.log"

        local c47="$UPSTREAM_DIR/c47"
        [[ -x "$c47" ]] || harness_die "c47 not built at $c47"
        harness_log "built: $(cd "$UPSTREAM_DIR" && md5sum c47 | cut -d' ' -f1) c47"

        shopt -s nullglob
        local tests=("$UI_DIR"/*.t47)
        shopt -u nullglob
        [[ ${#tests[@]} -gt 0 ]] || harness_die "no UI tests found in $UI_DIR"
        harness_log "${#tests[@]} UI test file(s) in $UI_DIR"

        # c47 reads res/ relative to cwd on Linux: the chdir that would lift
        # that is __APPLE__-only (c47-gtk.c:73), so run from the upstream root.
        #
        # WAYLAND_DISPLAY is unset deliberately. GTK3 prefers the Wayland
        # backend whenever that variable is set, which would bypass the virtual
        # X server that xvfb-run just created - on a developer's Wayland desktop
        # that puts a real calculator window on their screen. Under --reset a
        # GTK dialog has nobody to dismiss it, so timeout turns a hang into a
        # failure the lane can report.
        local failed=0 t rc
        for t in "${tests[@]}"; do
            harness_log "running $(basename "$t")"
            if ( cd "$UPSTREAM_DIR" \
                && env -u WAYLAND_DISPLAY timeout "$TEST_TIMEOUT" \
                    xvfb-run -a ./c47 --reset --script "$t" ); then
                harness_log "  PASS $(basename "$t")"
            else
                rc=$?
                if [[ $rc -eq 124 ]]; then
                    harness_log "  FAIL $(basename "$t") - timed out after ${TEST_TIMEOUT}s"
                    harness_log "       a blocking GTK dialog is the usual cause"
                else
                    harness_log "  FAIL $(basename "$t") - exit $rc"
                fi
                failed=$((failed + 1))
            fi
        done

        [[ $failed -eq 0 ]] || harness_die "$failed UI test(s) failed"
        harness_log "UI OK - ${#tests[@]} test file(s) passed"
    } 2>&1 | tee "$log"

    harness_log "log written: $log"
}

main "$@"
