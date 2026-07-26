#!/usr/bin/env bash
# scripts/test/lib/skip127.sh
#
# Run a lane script and translate its SKIP signal into a passing step.
#
#   bash scripts/test/lib/skip127.sh scripts/test/run-framac-wp.sh
#
# The frama-c lanes exit 127 to mean "the optional toolchain is not here, so this
# gate did not run" - documented in docs/05-ci.md as SKIP, deliberately distinct
# from passing. Nothing implemented that: the workflow called the scripts plainly,
# so a skip surfaced as a red lane, and the frama-c lane failed on every CI run it
# ever had because one prover was unregistered.
#
# 127 is the exit code the shell also uses for "command not found", which is the
# same condition by another route, so the overload is harmless here.
#
# This lives in a script rather than inline YAML for the reason docs/05-ci.md
# gives: a workflow must contain no logic that cannot be run locally. Run it
# locally and a skip prints the same line CI shows, and returns 0.
#
# It does NOT hide a failure: only 127 is translated, every other non-zero status
# is passed through unchanged, and a skip is announced on stdout and as a GitHub
# annotation so a lane cannot go quietly green forever. A gate that never fires
# is not a gate - so read the annotations, not just the checkmark.

set -Eeuo pipefail

[[ $# -ge 1 ]] || {
    printf 'usage: %s <lane-script> [args...]\n' "${0##*/}" >&2
    exit 2
}

lane="$1"
shift

rc=0
bash "$lane" "$@" || rc=$?

case "$rc" in
    0) ;;
    127)
        printf 'SKIPPED: %s exited 127 - its optional toolchain is absent, so the gate did not run.\n' "$lane"
        # ::warning:: puts it in the run summary; outside Actions it is just a line.
        printf '::warning title=%s skipped::exit 127, the gate did not run - see docs/05-ci.md\n' "${lane##*/}"
        rc=0
        ;;
esac
exit "$rc"
