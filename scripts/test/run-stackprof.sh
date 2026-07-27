#!/usr/bin/env bash
# scripts/test/run-stackprof.sh
#
# Memory limits of every supported c47 platform, measured rather than assumed.
#
# Three questions, in order:
#
#   1. What are each platform's compile-time limits, and where do they differ?
#      tooling/platform-limits.py asks upstream's own defines.h under each
#      platform's macros. The answer that matters most: the SIMULATOR IS BUILT
#      WITH THE NEW HARDWARE'S POOL, four times the DM42's, so a DM42 pool or
#      fragmentation failure cannot be reproduced on it at all.
#   2. Is the profiler telling the truth? Two calibration builds - one per
#      instruction set - compile without LTO so gcc -fstack-usage covers c47's
#      own sources, and every extracted frame is compared against gcc's. An
#      UNDER-report fails the lane whatever STACKPROF_GATE says: a bound below
#      the real frame is a bound that permits the overflow it was meant to stop.
#   3. What does a nested engine evaluation cost on each platform, against the
#      memory that platform actually has for it? On the DM42 that is what is left
#      of the firmware malloc arena once C47's pool is taken - 24,568 B, shared
#      with GMP and every other allocation - because a program runs on a
#      scheduler task stack out of that arena, NOT on the MSP band. 148 KiB on
#      the DM42n; the host thread's 8 MiB on the simulator, which is why the
#      simulator can never show you this bug.
#
# docs/06-memory.md owns the map, the derivation and the platform matrix.
#
# LTO is why there are two builds per instruction set and not one. The shipped
# firmware and simulator are both built with -flto, which defers code generation
# to link time, so gcc emits NO per-translation-unit .su file and the only stack
# usage it reports comes from GMP - built by its own autotools without LTO. The
# reported numbers therefore come from the shipped flags, and the calibration
# comes from a no-LTO twin: upstream's -Dmem=true for the firmware, -fno-lto for
# the simulator. Calibrating one target per ISA is enough - the extraction rules
# are per instruction set, not per package.
#
# Report-first by default (STACKPROF_GATE=0), like the other breadth lanes: the
# per-level numbers move with upstream inlining, so the standing reading in the
# log is the deliverable. Flip STACKPROF_GATE=1 to fail on a ceiling breach.

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"

STACKPROF_GATE="${STACKPROF_GATE:-0}"
BASELINE="${BASELINE:-$SCRIPT_DIR/stackprof-baseline.txt}"
ARM_OBJDUMP="${ARM_OBJDUMP:-arm-none-eabi-objdump}"
HOST_OBJDUMP="${HOST_OBJDUMP:-objdump}"

# What a nested evaluation's stack has to fit inside, per hardware target, read out
# of the shipped firmware images by tooling/dmcp-stackband.py and derived in
# docs/06-memory.md s3.
#
# DM42: NOT the MSP band. DMCP's SVCall/PendSV are a context switch that writes
# PSP, so a program runs in thread mode on a task stack allocated from the
# firmware malloc arena - the 2,472 B between the top of kernel data and the
# initial MSP is the handler and boot stack, which no program runs on. The bound
# that applies is what is left of the 90,104 B arena once C47's 64 KiB pool is
# taken, and it is shared with GMP's long integers and every other allocation.
# DM42n: MSP 0x20040000 down to the newlib break 0x2001ACB8, above which DMCP5
# puts nothing.
DM42_BAND=24568
DM42_MSP_BAND=2472
DM42N_BAND=152392

# The DM42 ships as feature packages that trade functions for flash; they share
# one memory model but not one set of built functions, so the largest frames and
# the worst reachable paths differ per package. defines.h:154 tabulates what each
# carries. Package 4 is the Makefile default and what CI builds.
DM42_PACKAGES=(1 2 3 4)

# Payload roots: user operations whose reachable stack is worth a standing
# reading. Reported with the recursion cut declared, never silently pruned.
PAYLOAD_ROOTS=(fnSin fnMod fnSqrt fnEigenvalues fnPem)
# Cutting these two turns the mutually recursive engine into a per-level cost.
# execProgram is the nesting budget's own choke point (c43 MR !1610); printTrace
# is the trace/error-display tail, live only while tracing, which would otherwise
# merge every numeric kernel into a single cycle.
CUTS=(execProgram printTrace)

failures=0
verified_isas=0

# Copy an upstream cross file with extra flags appended to its c_args.
#
# The whole file is rewritten rather than layered as a second --cross-file that
# carries only [built-in options]: meson merges several cross files but the
# overlay's missing [binaries] section drops the cross compiler, and the build
# silently falls back to the host `cc` until its sanity check fails on
# `--specs=nosys.specs`. Rewriting in place also keeps the flags upstream's, so
# they cannot drift from the shipped build the way a carried copy would.
write_cross_file() {
    local source="$1" dest="$2"
    shift 2
    python3 - "$source" "$dest" "$@" <<'PY'
import re, sys
text = open(sys.argv[1], encoding="utf-8").read()
match = re.search(r"^(c_args\s*=\s*\[)(.*?)(\])", text, re.S | re.M)
if not match:
    sys.exit(f"no c_args list in {sys.argv[1]}")
extra = "".join(f",\n  '{flag}'" for flag in sys.argv[3:])
open(sys.argv[2], "w", encoding="utf-8").write(text[:match.end(2)] + extra + text[match.end(2):])
PY
}

# Configure and build one tree. Returns non-zero without dying: a DMCP package
# that no longer fits in flash is a fact to report, not a reason to stop.
build_tree() {
    local label="$1" build="$2" target="$3"
    shift 3
    rm -rf "${UPSTREAM_DIR:?}/$build"
    if ! (cd "$UPSTREAM_DIR" && meson setup "$build" "$@") > "$LOG_DIR/stackprof-$label-setup.log" 2>&1; then
        harness_log "$label: meson setup failed; see $LOG_DIR/stackprof-$label-setup.log"
        return 1
    fi
    if ! (cd "$UPSTREAM_DIR/$build" && ninja "-j$(harness_jobs)" "$target") > "$LOG_DIR/stackprof-$label-build.log" 2>&1; then
        local reason
        reason="$(grep -m1 -oE "region \`[A-Z]+' overflowed by [0-9]+ bytes" "$LOG_DIR/stackprof-$label-build.log" || true)"
        harness_log "$label: DOES NOT BUILD at this commit${reason:+ - $reason}"
        return 1
    fi
    return 0
}

find_binary() {
    find "$UPSTREAM_DIR/$1" -type f -name "$2" -print -quit
}

# Calibrate one instruction set: build without LTO so gcc -fstack-usage covers
# c47's own sources, and compare every frame the profiler extracts against it.
verify_isa() {
    local label="$1" objdump="$2" build="$3" target="$4" binary="$5"
    shift 5
    harness_log "$label: calibration build (no LTO, -fstack-usage)"
    build_tree "$label" "$build" "$target" "$@" \
        || harness_die "$label: calibration build failed - the profile cannot be trusted without it"
    local elf su_count
    elf="$(find_binary "$build" "$binary")"
    [[ -n "$elf" ]] || harness_die "$label: no $binary under $build"
    su_count="$(find "$UPSTREAM_DIR/$build" -name '*.su' -not -path '*/subprojects/*' | wc -l)"
    [[ "$su_count" -gt 100 ]] \
        || harness_die "$label: only $su_count c47 .su files - LTO is still on, so the self-check would cover almost nothing"
    harness_log "$label: $su_count c47 .su files (excluding the GMP subproject)"
    python3 "$SCRIPT_DIR/tooling/stackprof.py" \
        --elf "$elf" --objdump "$objdump" --target "$label" --su-dir "$UPSTREAM_DIR/$build" --top 0 \
        || harness_die "$label: extraction disagrees with gcc -fstack-usage in the unsafe direction"
    verified_isas=$((verified_isas + 1))
}

# Profile one shipped build: chains against their ceilings, largest frames, and
# the worst reachable stack per payload root with the recursion cut declared.
profile() {
    local label="$1" objdump="$2" build="$3" band="$4" binary="$5"
    shift 5
    local elf rc=0
    elf="$(find_binary "$build" "$binary")"
    [[ -n "$elf" ]] || { harness_log "$label: no $binary under $build"; return 1; }
    python3 "$SCRIPT_DIR/tooling/stackprof.py" \
        --elf "$elf" --objdump "$objdump" --target "$label" \
        --chains "$BASELINE" --band "$band" --top 10 \
        --json "$LOG_DIR/stackprof-$label.json" \
        "${CUTS[@]/#/--cut=}" "${PAYLOAD_ROOTS[@]/#/--root=}" || rc=$?
    case "$rc" in
        0) harness_log "$label: within every ceiling" ;;
        1)
            harness_log "$label: a chain is invalid or over its ceiling"
            failures=$((failures + 1))
            ;;
        *) harness_die "$label: profiler failed (exit $rc)" ;;
    esac
}

main() {
    harness_init
    local log="$LOG_DIR/stackprof.log"
    {
        command -v "$ARM_OBJDUMP" > /dev/null || harness_die "$ARM_OBJDUMP not found - install the arm-none-eabi toolchain"
        command -v "$HOST_OBJDUMP" > /dev/null || harness_die "$HOST_OBJDUMP not found"

        local commit
        commit="$(harness_resolve_commit)"
        harness_log "stackprof against upstream $commit (STACKPROF_GATE=$STACKPROF_GATE)"
        harness_sync_upstream "$commit"
        harness_setup_xlsxio

        # ccache is baked into the cross files' compiler command and meson finds
        # it for the native build too. -fstack-usage writes a second output file
        # per object that a cache hit does not replay, so disable it here rather
        # than risk a calibration build with an empty .su tree.
        export CCACHE_DISABLE=1

        harness_log "--- compile-time limits, all platforms ---"
        python3 "$SCRIPT_DIR/tooling/platform-limits.py" "$UPSTREAM_DIR" \
            --json "$LOG_DIR/stackprof-limits.json" \
            || harness_die "platform-limits failed - defines.h no longer probes cleanly"

        local arm_cross="src/c47-dmcp/cross_arm_gcc.build" arm5_cross="src/c47-dmcp5/cross_arm_gcc.build"
        local su_cross="$HARNESS_WORK/su-arm.build"
        write_cross_file "$UPSTREAM_DIR/$arm_cross" "$su_cross" -fstack-usage

        harness_log "--- calibrating the profiler, one build per instruction set ---"
        # -Dmem=true is upstream's own diagnostic switch: it drops -flto so that
        # per-feature sizes read true, which is exactly the property needed here.
        verify_isa DM42-verify "$ARM_OBJDUMP" build.verify.dm42 dmcp C47.elf \
            "--cross-file=$su_cross" \
            -DDMCPVERSION=dmcp -DDMCP_PACKAGE=4 -DDECNUMBER_FASTMUL=true -DCI_COMMIT_TAG= -Dmem=true
        # src/c47-gtk/meson.build pins b_lto=true per target, so -Db_lto=false is
        # not enough; -fno-lto goes last in c_args, where it wins.
        verify_isa sim-verify "$HOST_OBJDUMP" build.verify.sim sim c47 \
            --buildtype=custom -DCI_COMMIT_TAG= -DDECNUMBER_FASTMUL=true "-Dc_args=-fstack-usage -fno-lto"
        harness_log "calibrated $verified_isas instruction sets, 0 under-reported frames"

        harness_log "DM42: task-stack budget $DM42_BAND B (arena less the pool, shared with GMP); MSP handler band $DM42_MSP_BAND B"
        harness_log "--- per-platform profiles, shipped flags ---"
        local pkg
        for pkg in "${DM42_PACKAGES[@]}"; do
            if build_tree "DM42-pkg$pkg" "build.dmcp.p$pkg" dmcp \
                "--cross-file=$arm_cross" -DDMCPVERSION=dmcp -DDMCP_PACKAGE="$pkg" \
                -DDECNUMBER_FASTMUL=true -DCI_COMMIT_TAG= -Dmem=false; then
                profile "DM42-pkg$pkg" "$ARM_OBJDUMP" "build.dmcp.p$pkg" "$DM42_BAND" C47.elf
            fi
        done

        if build_tree DM42n build.dmcp5 dmcp5 \
            "--cross-file=$arm5_cross" -DDMCPVERSION=dmcp5 -DDECNUMBER_FASTMUL=true -DCI_COMMIT_TAG=; then
            profile DM42n "$ARM_OBJDUMP" build.dmcp5 "$DM42N_BAND" C47.elf
        fi

        # The simulator's C stack is the host thread's, so its band is a host
        # setting, not a product fact - read it here rather than hardcode 8 MiB.
        local sim_band
        sim_band="$(ulimit -s)"
        if [[ "$sim_band" == unlimited ]]; then
            sim_band=0
            harness_log "sim: RLIMIT_STACK is unlimited on this host - no band to compare against"
        else
            sim_band=$((sim_band * 1024))
            harness_log "sim: host RLIMIT_STACK is $sim_band B, $((sim_band / DM42_BAND))x the DM42 band"
        fi
        if build_tree sim build.stackprof.sim sim \
            --buildtype=custom -DCI_COMMIT_TAG= -DDECNUMBER_FASTMUL=true; then
            profile sim "$HOST_OBJDUMP" build.stackprof.sim "$sim_band" c47
        fi

        if [[ "$failures" -gt 0 ]]; then
            harness_log "$failures platform(s) reported an invalid chain or a ceiling breach"
            [[ "$STACKPROF_GATE" == 1 ]] && harness_die "STACKPROF_GATE=1: $failures platform(s) failed"
        fi
        harness_log "STACKPROF OK (report-only unless STACKPROF_GATE=1)"
    } 2>&1 | tee "$log"
}

main "$@"
