#!/usr/bin/env bash
# scripts/test/run-framac.sh
#
# Frama-C parse gate (Milestone M0 of the Frama-C plan; see __DEV REPORT-15).
# Proves the curated c43 source slice parses and typechecks as one C17 program to
# the Frama-C kernel - the prerequisite for any Eva/WP analysis. It does NOT run
# Eva or WP; that is M1+.
#
# Like fcfish's Frama-C gates, this lane is OPTIONAL infrastructure: with no opam
# switch / no frama-c it exits 127 and is reported SKIPPED, not passed, so a clone
# without Frama-C stays green over every other lane.
#
# Tree resolution:
#   FRAMAC_C43_DIR=/path/to/built/c43   use an existing (ideally built) tree
#   otherwise                           resolve + shallow-sync upstream master
#
# Generated headers: the slice includes files that reference generated constants
# (constantPointers.h). A BUILT tree carries the real src/generated and the full
# slice is certified. A bare clone has none, so the lane falls back to the
# parse-only generated-stubs shipped here and SKIPS the @needs-generated targets,
# reporting exactly which and why (no silent cap).

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"

TOOL_DIR="$SCRIPT_DIR/tooling/framac"
STUBS="$TOOL_DIR/stubs"
GEN_STUBS="$TOOL_DIR/generated-stubs"
FAM_PATCH="$TOOL_DIR/framac-fam-shim.patch"
TARGETS="$TOOL_DIR/targets.txt"
MACHDEP="${FRAMAC_MACHDEP:-gcc_x86_64}"

# Load the opam switch so `frama-c` is on PATH; SKIP (127) if unavailable.
framac_require() {
    if command -v opam > /dev/null 2>&1; then
        eval "$(opam env 2> /dev/null)" || true
    fi
    if ! command -v frama-c > /dev/null 2>&1; then
        harness_log "frama-c not found (no opam switch) - SKIP (not a failure)"
        exit 127
    fi
    harness_log "frama-c: $(frama-c -version 2>/dev/null)"
}

main() {
    harness_init
    local log="$LOG_DIR/framac.log"
    {
        framac_require

        # 1. Resolve the tree.
        local dir
        if [[ -n "${FRAMAC_C43_DIR:-}" ]]; then
            dir="$FRAMAC_C43_DIR"
            [[ -d "$dir/src/c47" ]] || harness_die "FRAMAC_C43_DIR has no src/c47: $dir"
            harness_log "using existing tree: $dir"
        else
            local commit
            commit="$(harness_resolve_commit)"
            harness_log "resolved upstream commit: $commit"
            harness_sync_upstream "$commit"
            dir="$UPSTREAM_DIR"
        fi

        # 2. Apply the FAM shim (kernel rejects the static-init flexible array
        #    member in finite_differences.h, which the god header pulls in).
        [[ -f "$FAM_PATCH" ]] || harness_die "missing $FAM_PATCH"
        if git -C "$dir" apply --check "$FAM_PATCH" 2> /dev/null; then
            git -C "$dir" apply "$FAM_PATCH"
            harness_log "applied framac-fam-shim.patch"
        elif git -C "$dir" apply --reverse --check "$FAM_PATCH" 2> /dev/null; then
            harness_log "framac-fam-shim.patch already applied"
        else
            harness_die "framac-fam-shim.patch does not apply on $dir; rebase it onto current upstream"
        fi

        # 3. Choose the generated-header source: real (built tree) or stub.
        local inc_gen mode
        if [[ -f "$dir/src/generated/constantPointers.h" ]]; then
            inc_gen="-I$dir/src/generated"
            mode=real
            harness_log "generated headers: REAL (src/generated present) - full slice certified"
        else
            inc_gen="-I$GEN_STUBS"
            mode=stub
            harness_log "generated headers: STUB fallback (tree not built) - @needs-generated targets will be SKIPPED"
        fi

        local cpp=(
            "-I$STUBS" "$inc_gen"
            "-I$dir/src/c47" "-I$dir/src/c47/hal" "-I$dir/src/testSuite"
            "-I$dir/dep/decNumberICU"
            "-DPC_BUILD=1" "-DLINUX=1" "-DOS64BIT=1" "-DTESTSUITE_BUILD"
            "-DDECNUMBER_FASTMUL=1" "-std=c11"
        )

        # 4. Parse every target.
        [[ -f "$TARGETS" ]] || harness_die "missing $TARGETS"
        local pass=0 fail=0 skip=0 failed=()
        local line rel tag
        while IFS= read -r line; do
            line="${line%%#*}"                       # strip comments
            line="$(printf '%s' "$line" | xargs)"    # trim
            [[ -z "$line" ]] && continue
            rel="${line%%@*}"; rel="$(printf '%s' "$rel" | xargs)"
            tag="${line#"$rel"}"; tag="$(printf '%s' "$tag" | xargs)"
            [[ -f "$dir/$rel" ]] || harness_die "target not in tree: $rel"

            if (cd "$dir" && frama-c -machdep "$MACHDEP" -cpp-extra-args="${cpp[*]}" "$rel") \
                > "$LOG_DIR/framac.$$.tu" 2>&1; then
                pass=$((pass + 1)); printf ' ok   %s\n' "$rel"
            elif [[ "$mode" == stub && "$tag" == "@needs-generated" ]]; then
                skip=$((skip + 1)); printf ' skip %s (needs a built tree)\n' "$rel"
            else
                fail=$((fail + 1)); failed+=("$rel"); printf ' FAIL %s\n' "$rel"
                sed -n 's/^/      /p' "$LOG_DIR/framac.$$.tu" | grep -iE 'error|fatal' | head -3 || true
            fi
        done < "$TARGETS"
        rm -f "$LOG_DIR/framac.$$.tu"

        # 5. Leave the tree as we found it when we own it.
        [[ -z "${FRAMAC_C43_DIR:-}" ]] || git -C "$dir" checkout -- src/c47/solver/finite_differences.h 2> /dev/null || true

        harness_log "parse gate [$mode]: $pass passed, $skip skipped, $fail failed"
        if ((fail > 0)); then
            harness_log "FAILED: ${failed[*]}"
            harness_die "frama-c parse gate FAILED on $fail file(s)"
        fi
        harness_log "FRAMAC PARSE OK"
    } 2>&1 | tee "$log"

    harness_log "log written: $log"
}

main "$@"
