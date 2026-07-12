#!/usr/bin/env bash
# scripts/test/run-fuzz.sh
#
# Fuzz the program-step decoder. This drives the
# highest-yield leak/robustness surface - a parser of data that reaches the
# calculator from imported programs and restored state - with adversarial input.
#
# It overlays the libFuzzer harness (scripts/test/tooling/fuzz-decode.patch,
# carried off the test/fuzz-decode-harness branch off upstream master), builds
# the fuzzDecode target under clang with -fsanitize=fuzzer,address,undefined
# (ASan is the crash gate; UBSan runs in report mode; the alignment check is off
# because the calculator packs program bytecode unaligned by design), and runs a
# time-boxed campaign over the seed corpus with the decoder dictionary.
#
# Report-first: a crash is surfaced and its reproducer uploaded, but the lane
# only fails when FUZZ_GATE=1. Env knobs: FUZZ_TIME (seconds, default 60),
# FUZZ_MAXLEN (bytes, default 64), FUZZ_GATE (1 to fail on a finding), BUILD_DIR.

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"

TOOLING_PATCH="${TOOLING_PATCH:-$SCRIPT_DIR/tooling/fuzz-decode.patch}"
SEED_DIR="${SEED_DIR:-$SCRIPT_DIR/tooling/fuzz-decode-seeds}"
DICT="${DICT:-$SCRIPT_DIR/tooling/fuzz-decode.dict}"
BUILD_DIR="${BUILD_DIR:-build.fuzz}"
FUZZ_TIME="${FUZZ_TIME:-60}"
FUZZ_MAXLEN="${FUZZ_MAXLEN:-64}"
FUZZ_GATE="${FUZZ_GATE:-0}"

main() {
    harness_init
    command -v clang > /dev/null || harness_die "clang required for libFuzzer (apt-get install clang)"

    local commit
    commit="$(harness_resolve_commit)"
    harness_log "fuzzing decodeOneStep against upstream $commit"
    harness_sync_upstream "$commit"

    [[ -f "$TOOLING_PATCH" ]] || harness_die "tooling patch not found: $TOOLING_PATCH"
    if ! git -C "$UPSTREAM_DIR" apply --check "$TOOLING_PATCH" 2> /dev/null; then
        harness_die "fuzz-decode.patch does not apply on upstream $commit; rebase the
        test/fuzz-decode-harness tooling onto current upstream and regenerate
        scripts/test/tooling/fuzz-decode.patch"
    fi
    git -C "$UPSTREAM_DIR" apply "$TOOLING_PATCH"
    harness_log "overlaid libFuzzer harness"

    harness_setup_xlsxio

    harness_log "building fuzzDecode under clang ($BUILD_DIR)"
    (
        cd "$UPSTREAM_DIR"
        chmod +x tools/onARaspberry
        local raspberry
        raspberry="$(./tools/onARaspberry)"
        rm -rf "$BUILD_DIR"
        CC=clang CXX=clang++ meson setup "$BUILD_DIR" --buildtype=custom \
            -DRASPBERRY="$raspberry" -DDECNUMBER_FASTMUL=true \
            -Dfuzz_decode=true \
            -Dc_args="-Wno-deprecated-declarations" > "$LOG_DIR/fuzz-build.log" 2>&1
        ninja -C "$BUILD_DIR" src/c47/vcs.h >> "$LOG_DIR/fuzz-build.log" 2>&1
        ninja -C "$BUILD_DIR" "-j$(harness_jobs)" src/testSuite/fuzzDecode >> "$LOG_DIR/fuzz-build.log" 2>&1
    ) || harness_die "fuzz build failed (see $LOG_DIR/fuzz-build.log)"

    local bin="$UPSTREAM_DIR/$BUILD_DIR/src/testSuite/fuzzDecode"
    [[ -x "$bin" ]] || harness_die "fuzzDecode binary not built"

    # Run from a scratch dir; seed a working corpus from the carried seeds so the
    # campaign starts from structurally plausible steps and accumulates coverage.
    local run_dir="$HARNESS_WORK/run"
    rm -rf "$run_dir"
    mkdir -p "$run_dir/corpus"
    [[ -d "$SEED_DIR" ]] && cp -f "$SEED_DIR"/* "$run_dir/corpus/" 2> /dev/null || true

    local dict_arg=()
    [[ -f "$DICT" ]] && dict_arg=("-dict=$DICT")

    harness_log "running a ${FUZZ_TIME}s campaign (max_len=$FUZZ_MAXLEN, ASan gate, UBSan report)"
    local rc=0
    (
        cd "$run_dir"
        export UBSAN_OPTIONS="halt_on_error=0:print_stacktrace=1"
        export ASAN_OPTIONS="detect_leaks=1:abort_on_error=0"
        "$bin" -max_total_time="$FUZZ_TIME" -max_len="$FUZZ_MAXLEN" \
            -rss_limit_mb=4096 -artifact_prefix="$LOG_DIR/fuzz-" \
            "${dict_arg[@]}" corpus/
    ) > "$LOG_DIR/fuzz-campaign.log" 2>&1 || rc=$?

    # Preserve the evolved corpus for the next run / OSS-Fuzz seeding.
    tar -czf "$LOG_DIR/fuzz-corpus.tar.gz" -C "$run_dir" corpus 2> /dev/null || true

    local crashes
    crashes="$(ls "$LOG_DIR"/fuzz-crash-* "$LOG_DIR"/fuzz-leak-* "$LOG_DIR"/fuzz-oom-* "$LOG_DIR"/fuzz-timeout-* 2> /dev/null || true)"
    if [[ -n "$crashes" ]]; then
        harness_log "FUZZ FINDING(s) - reproducers saved (re-run: fuzzDecode <file>):"
        printf ' %s\n' $crashes
        # Surface the sanitizer summary lines for triage.
        grep -E "ERROR: AddressSanitizer|SUMMARY: (AddressSanitizer|UndefinedBehaviorSanitizer)|in [a-zA-Z_]+ /" \
            "$LOG_DIR/fuzz-campaign.log" | head -8 | sed 's/^/ /' || true
        if [[ "$FUZZ_GATE" == "1" ]]; then
            harness_die "fuzz gate failed: $(printf '%s\n' $crashes | grep -c .) finding(s)"
        fi
        harness_log "report-first: not failing the lane (set FUZZ_GATE=1 to gate)"
        return 0
    fi

    harness_log "campaign finished with no ASan finding (rc=$rc); corpus saved to fuzz-corpus.tar.gz"
}

main "$@"
