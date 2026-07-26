#!/usr/bin/env bash
# scripts/test/run-nestcheck.sh
#
# Nested-engine recursion check. A C47 program may legally re-enter its own
# numeric engines (SOLVE(SOLVE) and PLOT(SOLVE) are supported), so a
# SELF-referential program - one that solves, integrates, sums or plots itself -
# is reachable user input, and on an unguarded tree each one recurses until the
# C stack dies (the class of c43 MR !1610). This lane assembles the five
# self-referential probes plus one legal depth-2 nest with tooling/p47asm.py
# (byte-encodings proven against executed streams by its --selftest), runs each
# headless under timeout and xvfb-run, and classifies: SURVIVED (clean halt),
# CRASHED, HANG.
#
# xvfb-run is not optional and not about the keyboard: t47 is the same binary as
# c47 and calls gtk_init before parsing its arguments, so with no display it exits
# 1 and every probe reads as a product failure. See the call site for the detail.
#
# The legal nest (nested2, root exactly 2) must ALWAYS survive: it is the lane's
# own control - if it fails, the runner or the build is broken, and the lane
# dies rather than reporting anything about the probes.
#
# Report-only by default (NESTCHECK_GATE=0): upstream master currently CRASHES
# on all five probes, and the lane's job is to say so on every run, loudly and
# with a count, until the nesting budget merges. Flip NESTCHECK_GATE=1 once it
# has: from then on any probe that stops surviving is a regression and fails
# the lane.

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"

NESTCHECK_GATE="${NESTCHECK_GATE:-0}"
# selfplt spends its budgeted depth rendering plots per level; the others abort
# or crash in seconds. One generous ceiling keeps a hang detectable.
TEST_TIMEOUT="${TEST_TIMEOUT:-300}"
PGM_DIR="$SCRIPT_DIR/tooling/nestcheck"

# Append a probe's captured output to a fatal message. Every diagnostic this lane
# produces goes to a file under $LOG_DIR, so a bare "control did not survive" left
# three CI failures with nothing to read: the console log carried the verdict and
# none of the evidence. Inline the tail on the paths that die.
probe_evidence() {
    local out="$1"
    [[ -s "$out" ]] || { printf '\n  (no output captured in %s)' "$out"; return 0; }
    printf '\n  --- last 20 lines of %s ---\n' "$out"
    tail -20 "$out" | sed -e 's/^/  | /'
}

# name:label pairs; nested2 is the control and runs first.
PROBES=(nested2:N selfslv:A selfint:A selfsum:A selfplt:P mixnest:G)

main() {
    harness_init
    local log="$LOG_DIR/nestcheck.log"
    {
        local commit
        commit="$(harness_resolve_commit)"
        harness_log "nestcheck against upstream $commit (NESTCHECK_GATE=$NESTCHECK_GATE)"
        harness_sync_upstream "$commit"
        harness_setup_xlsxio
        harness_configure_ccache

        harness_log "p47asm selftest (encoder vs executed byte streams)"
        python3 "$SCRIPT_DIR/tooling/p47asm.py" \
            --items "$UPSTREAM_DIR/src/c47/items.h" --selftest \
            || harness_die "p47asm selftest failed - encoder or items.h drifted"

        local pgm out
        for pgm in "$PGM_DIR"/*.pgm; do
            out="$LOG_DIR/$(basename "$pgm" .pgm).p47"
            python3 "$SCRIPT_DIR/tooling/p47asm.py" \
                --items "$UPSTREAM_DIR/src/c47/items.h" "$pgm" "$out" \
                || harness_die "p47asm failed on $pgm"
        done

        # Build both front ends. "make simc47 t47" exactly: a bare "make t47"
        # builds the R47-based t47 instead.
        harness_log "building simulator (make simc47 t47)"
        make -C "$UPSTREAM_DIR" simc47 t47 "-j$(harness_jobs)" \
            > "$LOG_DIR/nestcheck-build.log" 2>&1 \
            || harness_die "simulator build failed$(probe_evidence "$LOG_DIR/nestcheck-build.log")"
        [[ -x "$UPSTREAM_DIR/t47" ]] || harness_die "t47 not built"

        # t47 reads res/ relative to cwd on Linux, so run from the upstream root.
        #
        # Under xvfb-run even though nothing here touches the keyboard: t47 is the
        # same GTK binary as c47 and calls gtk_init unconditionally
        # (src/c47-gtk/c47-gtk.c:428), before it has even parsed its arguments. On
        # a machine with no display that call fails and the process exits 1 with
        # "cannot open display", which the classifier below cannot tell from a
        # product failure - it is what made this lane's control fail on every CI
        # run while passing on any desktop. `--headless` does NOT avoid it: the
        # flag is read after gtk_init has already run.
        #
        # -a picks a free server number so a second lane on the same runner cannot
        # collide. timeout wraps xvfb-run, which propagates the child's status, so
        # the 139/124 classification is unchanged - both verified.
        command -v xvfb-run > /dev/null \
            || harness_die "xvfb-run not found - t47 calls gtk_init unconditionally, so the probes need a display (apt install xvfb)"

        local entry name label rc marker out crashed=0 survived=0 hung=0
        for entry in "${PROBES[@]}"; do
            name="${entry%%:*}"
            label="${entry##*:}"
            marker="NESTCHECK-DONE-$name"
            out="$LOG_DIR/nestcheck-$name.out"
            rc=0
            (cd "$UPSTREAM_DIR" && timeout "$TEST_TIMEOUT" xvfb-run -a ./t47 --reset \
                --exec "readp $LOG_DIR/$name.p47; xeq $label; puts \"$marker X=[reg X]\"" \
                > "$out" 2>&1) || rc=$?
            if grep -q "$marker" "$out"; then
                if [[ "$name" == nested2 ]]; then
                    grep -q "$marker X=2\$" "$out" \
                        || harness_die "control nested2 survived but root != 2 - runner or build broken$(probe_evidence "$out")"
                    harness_log "CONTROL  nested2: survived, root exact - runner sound"
                else
                    harness_log "SURVIVED $name: clean halt (guarded tree)"
                    survived=$((survived + 1))
                fi
            elif [[ "$rc" == 124 ]]; then
                harness_log "HANG     $name: no result within ${TEST_TIMEOUT}s"
                hung=$((hung + 1))
            else
                if [[ "$name" == nested2 ]]; then
                    harness_die "control nested2 did not survive (rc=$rc) - runner or build broken$(probe_evidence "$out")"
                fi
                harness_log "CRASHED  $name: rc=$rc (unbounded recursion class)"
                crashed=$((crashed + 1))
            fi
        done

        harness_log "summary: survived=$survived crashed=$crashed hung=$hung of $((${#PROBES[@]} - 1)) probes"
        if [[ "$crashed" -gt 0 || "$hung" -gt 0 ]]; then
            harness_log "upstream $commit is VULNERABLE to self-referential engine nesting"
            [[ "$NESTCHECK_GATE" == 1 ]] \
                && harness_die "NESTCHECK_GATE=1: $crashed crash(es), $hung hang(s)"
        else
            harness_log "upstream $commit bounds all self-referential nests"
        fi
        harness_log "NESTCHECK OK (report-only unless NESTCHECK_GATE=1)"
    } 2>&1 | tee "$log"
}

main "$@"
