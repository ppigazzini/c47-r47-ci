#!/usr/bin/env bash
# scripts/test/run-stackprof.sh
#
# Firmware C-stack profile. Builds both DMCP targets with -fstack-usage and
# reports, per target: how much C stack one nested engine evaluation costs, what
# the largest fixed frames are, and how those numbers sit against the stack the
# firmware actually grants.
#
# The DM42 grant is the reason this lane exists. DMCP hands a running program a
# fixed 8,088 byte band and nothing else that is guaranteed; anything deeper
# rides whatever the top of the malloc arena happens to have free, and the
# allocator will hand that same region to the next caller. So a per-level cost
# times MAX_SOLVER_NESTING_DEPTH is not a curiosity, it is the safety margin.
# docs/10-memory.md owns the map and the derivation.
#
# Three checks, two of them gated:
#
#   1. Extraction self-check (ALWAYS hard). stackprof.py reads frame sizes out
#      of the disassembly; gcc -fstack-usage reports the same numbers from the
#      compiler. They must agree exactly, or the lane is reporting fiction and
#      dies whatever STACKPROF_GATE says.
#   2. Chain validity and per-level ceilings (STACKPROF_GATE=1 to gate) against
#      stackprof-baseline.txt.
#   3. Worst-case reachable stack per payload root - report-only, and reported
#      as unbounded where it is: every engine root sits in a recursion cycle
#      that only the runtime nesting budget closes.
#
# Report-first by default (STACKPROF_GATE=0), like the other breadth lanes: the
# numbers move with upstream inlining, so the first job is a standing reading in
# the log. Flip STACKPROF_GATE=1 to make a ceiling breach fail CI.

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"

STACKPROF_GATE="${STACKPROF_GATE:-0}"
BASELINE="${BASELINE:-$SCRIPT_DIR/stackprof-baseline.txt}"
OBJDUMP="${OBJDUMP:-arm-none-eabi-objdump}"

# Guaranteed downward stack, per target, read out of the shipped firmware images
# by tooling/dmcp-stackband.py and re-derived in docs/10-memory.md s2. DM42:
# initial MSP 0x20017FF0 down to 0x20017648, the highest address DMCP code
# addresses as a fixed global and the end of its boot zero-fill. DM42n: MSP
# 0x20040000 down to the newlib break at 0x2001ACB8, above which DMCP5 places
# nothing - which is why the old hardware is the only one with a problem.
DM42_BAND=2472
DM42N_BAND=152392

# Payload roots: user operations whose reachable stack is worth a standing
# reading. Reported with the recursion cut declared, never silently pruned.
PAYLOAD_ROOTS=(fnSin fnMod fnSqrt fnEigenvalues fnPem)
# Cutting these two turns the mutually recursive engine into a per-level cost.
# execProgram is the nesting budget's own choke point (c43 MR !1610); printTrace
# is the trace/error-display tail, which is live only while tracing and would
# otherwise merge every numeric kernel into one cycle.
CUTS=(execProgram printTrace)

# Emit a Meson cross file that repeats the upstream c_args with -fstack-usage
# appended. Generated rather than carried: a copy of upstream's compiler flags
# would rot silently the next time upstream changes them, and the .su numbers
# must come from the same flags as the ELF or the self-check compares two builds.
write_su_cross_file() {
    local source="$1" dest="$2"
    python3 - "$source" "$dest" <<'PY'
import re, sys
text = open(sys.argv[1], encoding="utf-8").read()
match = re.search(r"^c_args\s*=\s*\[(.*?)\]", text, re.S | re.M)
if not match:
    sys.exit(f"no c_args list in {sys.argv[1]}")
args = [a for a in re.findall(r"'([^']*)'", match.group(1))]
args.append("-fstack-usage")
body = ",\n  ".join(f"'{a}'" for a in args)
open(sys.argv[2], "w", encoding="utf-8").write(f"[built-in options]\nc_args = [\n  {body}]\n")
PY
}

# Configure and build one DMCP target, then profile it.
profile_target() {
    local label="$1" cross="$2" build="$3" target="$4" band="$5"
    shift 5
    local overlay="$HARNESS_WORK/su-$label.build"
    write_su_cross_file "$UPSTREAM_DIR/$cross" "$overlay"

    harness_log "$label: configuring $build with -fstack-usage"
    rm -rf "${UPSTREAM_DIR:?}/$build"
    (cd "$UPSTREAM_DIR" && meson setup "$build" \
        --cross-file="$cross" --cross-file="$overlay" "$@") \
        > "$LOG_DIR/stackprof-$label-setup.log" 2>&1 \
        || harness_die "$label: meson setup failed; see $LOG_DIR/stackprof-$label-setup.log"

    # Name the target: a bare `ninja` builds the default set, which for this
    # cross tree is the host generators and the testSuite, not the firmware ELF.
    harness_log "$label: building $target"
    (cd "$UPSTREAM_DIR/$build" && ninja "-j$(harness_jobs)" "$target") \
        > "$LOG_DIR/stackprof-$label-build.log" 2>&1 \
        || harness_die "$label: build failed; see $LOG_DIR/stackprof-$label-build.log"

    local elf
    elf="$(find "$UPSTREAM_DIR/$build" -name 'C47.elf' -print -quit)"
    [[ -n "$elf" ]] || harness_die "$label: no C47.elf under $build"
    # A build that produced no .su files would make the self-check vacuous, so
    # require them before trusting anything the profile prints.
    local su_count
    su_count="$(find "$UPSTREAM_DIR/$build" -name '*.su' | wc -l)"
    [[ "$su_count" -gt 0 ]] || harness_die "$label: -fstack-usage produced no .su files"
    harness_log "$label: $elf, $su_count .su files"

    local rc=0
    python3 "$SCRIPT_DIR/tooling/stackprof.py" \
        --elf "$elf" --objdump "$OBJDUMP" --target "$label" \
        --su-dir "$UPSTREAM_DIR/$build" \
        --chains "$BASELINE" --band "$band" \
        --json "$LOG_DIR/stackprof-$label.json" \
        "${CUTS[@]/#/--cut=}" "${PAYLOAD_ROOTS[@]/#/--root=}" || rc=$?

    case "$rc" in
        0) harness_log "$label: within every ceiling" ;;
        1)
            harness_log "$label: a chain is invalid or over its ceiling"
            [[ "$STACKPROF_GATE" == 1 ]] && harness_die "STACKPROF_GATE=1: $label failed its chain ceilings"
            ;;
        *) harness_die "$label: extraction self-check failed - the profile is not a measurement" ;;
    esac
    return 0
}

main() {
    harness_init
    local log="$LOG_DIR/stackprof.log"
    {
        command -v "$OBJDUMP" > /dev/null || harness_die "$OBJDUMP not found - install the arm-none-eabi toolchain"

        local commit
        commit="$(harness_resolve_commit)"
        harness_log "stackprof against upstream $commit (STACKPROF_GATE=$STACKPROF_GATE)"
        harness_sync_upstream "$commit"
        harness_setup_xlsxio

        # ccache is baked into the cross files' compiler command. -fstack-usage
        # writes a second output file per object that a cache hit would not
        # replay, so disable it here rather than risk an empty .su tree.
        export CCACHE_DISABLE=1

        profile_target DM42 src/c47-dmcp/cross_arm_gcc.build build.dmcp.p4 dmcp "$DM42_BAND" \
            -DDMCPVERSION=dmcp -DDMCP_PACKAGE=4 -DDECNUMBER_FASTMUL=true -DCI_COMMIT_TAG= -Dmem=false
        profile_target DM42n src/c47-dmcp5/cross_arm_gcc.build build.dmcp5 dmcp5 "$DM42N_BAND" \
            -DDMCPVERSION=dmcp5 -DDECNUMBER_FASTMUL=true -DCI_COMMIT_TAG=

        harness_log "STACKPROF OK (report-only unless STACKPROF_GATE=1)"
    } 2>&1 | tee "$log"
}

main "$@"
