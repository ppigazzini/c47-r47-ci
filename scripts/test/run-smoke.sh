#!/usr/bin/env bash
# scripts/test/run-smoke.sh
#
# Smoke lane. Proves the script-to-CI call pattern end to
# end: resolve the upstream commit, sync the upstream tree (with submodules),
# verify the build surface, configure ccache, report the toolchain, and write a
# log. It intentionally does NOT build the simulator - that is 's
# run-leakscan.sh, which reuses the same lib/common.sh preamble.

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"

main() {
    harness_init
    local log="$LOG_DIR/smoke.log"
    {
        harness_log "c43 test harness smoke"
        harness_log "upstream: $UPSTREAM_URL ref=$UPSTREAM_REF"

        local commit
        commit="$(harness_resolve_commit)"
        harness_log "resolved upstream commit: $commit"

        harness_sync_upstream "$commit"
        local head
        head="$(git -C "$UPSTREAM_DIR" rev-parse HEAD)"
        [[ "$head" == "$commit" ]] || harness_die "synced HEAD $head != resolved $commit"
        harness_log "synced upstream HEAD: $head"

        harness_overlay_tooling "${TOOLING_REF:-}"

        harness_log "build-surface check:"
        local f surface_ok=1
        for f in Makefile meson.build meson_options.txt \
            src/testSuite/meson.build src/testSuite/tests/testSuiteList.txt \
            dep/jimtcl/jim.c; do
            if [[ -e "$UPSTREAM_DIR/$f" ]]; then
                printf ' ok %s\n' "$f"
            else
                printf ' MISS %s\n' "$f"
                surface_ok=0
            fi
        done
        [[ "$surface_ok" == 1 ]] || harness_die "upstream build surface incomplete"

        harness_log "make targets present:"
        grep -nE '^(sim|simr47|test|test_asan|both_asan|docs):' "$UPSTREAM_DIR/Makefile" \
            || harness_die "expected make targets missing"

        harness_configure_ccache
        harness_log "build concurrency: $(harness_jobs) jobs"
        harness_log "toolchain:"
        harness_toolchain_report

        harness_log "SMOKE OK"
    } 2>&1 | tee "$log"

    harness_log "log written: $log"
}

main "$@"
