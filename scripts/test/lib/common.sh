#!/usr/bin/env bash
# scripts/test/lib/common.sh
#
# Shared preamble for the c43 testing harness. Source
# this from every lane script in scripts/test/. It provides the building blocks
# the later lanes (leak gate, coverage, fuzzing, ...) reuse:
# upstream resolution and sync, an optional tooling overlay from a test/* branch,
# the xlsxio build, ccache configuration, job detection, and logging.
#
# Sourcing has no side effect beyond defining functions and default variables.
# Every default is overridable from the environment so a CI lane sets only what
# it needs and calls the functions.

set -Eeuo pipefail

# ---- configuration (override via environment) ----
: "${UPSTREAM_URL:=https://gitlab.com/rpncalculators/c43.git}"
: "${UPSTREAM_REF:=refs/heads/master}"
: "${UPSTREAM_COMMIT:=}" # explicit pin; empty means resolve UPSTREAM_REF
: "${XLSXIO_URL:=https://github.com/brechtsanders/xlsxio.git}"
: "${XLSXIO_COMMIT:=a9016eb2eb46dcd613a68fcfcd1002b5adf64ae9}"
: "${HARNESS_WORK:=${RUNNER_TEMP:-/tmp}/c43-test-harness}"
: "${UPSTREAM_DIR:=${HARNESS_WORK}/upstream}"
: "${XLSXIO_PREFIX:=${HOME}/.cache/c43/xlsxio/${XLSXIO_COMMIT}}"
: "${CCACHE_DIR:=${HARNESS_WORK}/ccache}"
: "${LOG_DIR:=${HARNESS_WORK}/logs}"

harness_log() { printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*"; }
harness_die() {
    printf '[ERROR] %s\n' "$*" >&2
    exit 1
}

# Build concurrency, with a safe fallback.
harness_jobs() { nproc 2> /dev/null || echo 2; }

# Create the work and log directories.
harness_init() { mkdir -p "$HARNESS_WORK" "$LOG_DIR"; }

# Echo the upstream commit SHA to resolve: an explicit pin if set, else the tip
# of UPSTREAM_REF. Network call (git ls-remote); no working tree touched.
harness_resolve_commit() {
    if [[ -n "$UPSTREAM_COMMIT" ]]; then
        # harness_sync_upstream fetches this exact object over the wire; a shallow
        # `want` for an abbreviated SHA is rejected ("not allow request for
        # unadvertised object"), so require the full 40-hex form up front with an
        # actionable message rather than a cryptic fetch failure.
        [[ "$UPSTREAM_COMMIT" =~ ^[0-9a-f]{40}$ ]] \
            || harness_die "UPSTREAM_COMMIT must be a full 40-char SHA, got '$UPSTREAM_COMMIT'"
        printf '%s\n' "$UPSTREAM_COMMIT"
        return 0
    fi
    local sha
    sha="$(git ls-remote --exit-code "$UPSTREAM_URL" "$UPSTREAM_REF" | awk 'NR == 1 { print $1 }')"
    [[ -n "$sha" ]] || harness_die "could not resolve $UPSTREAM_REF at $UPSTREAM_URL"
    printf '%s\n' "$sha"
}

# Shallow-clone the upstream tree at a commit, including submodules (jimtcl,
# DMCP SDKs). Mirrors the build/analysis lanes so the build lanes build the same tree.
harness_sync_upstream() {
    local commit="$1" dir="${2:-$UPSTREAM_DIR}"
    rm -rf "$dir"
    mkdir -p "$dir"
    git -C "$dir" init -q
    git -C "$dir" remote add origin "$UPSTREAM_URL"
    git -C "$dir" fetch -q --depth 1 origin "$commit"
    git -C "$dir" checkout -q --detach FETCH_HEAD
    git -C "$dir" submodule update -q --init --recursive --depth 1
}

# Hook to overlay not-yet-upstream tooling (leak scanners, fuzz harnesses) carried
# on a test/* branch off upstream master, onto the synced tree. For the smoke lane this is a
# documented no-op; a later lane passes a real ref and a lane-specific
# overlay implementation.
harness_overlay_tooling() {
    local ref="${1:-${TOOLING_REF:-}}"
    if [[ -z "$ref" ]]; then
        harness_log "no tooling overlay requested"
        return 0
    fi
    harness_log "tooling overlay ref '$ref' requested (handled by the lane script)"
}

# Build and install the pinned xlsxio static toolchain if not already cached,
# then expose it on PATH and the loader path. Required by the simulator build
# (ttf2RasterFonts), so the build lanes call this before building.
harness_setup_xlsxio() {
    if [[ -x "$XLSXIO_PREFIX/bin/xlsxio_xlsx2csv" ]] || [[ -f "$XLSXIO_PREFIX/lib/libxlsxio_read.so" ]]; then
        harness_log "xlsxio present at $XLSXIO_PREFIX"
    else
        command -v cmake > /dev/null || harness_die "cmake required to build xlsxio"
        local src="$HARNESS_WORK/xlsxio"
        rm -rf "$src"
        git init -q "$src"
        git -C "$src" remote add origin "$XLSXIO_URL"
        git -C "$src" fetch -q --depth 1 origin "$XLSXIO_COMMIT"
        git -C "$src" checkout -q --detach FETCH_HEAD
        mkdir -p "$XLSXIO_PREFIX"
        cmake -S "$src" -B "$src/build" \
            -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
            -DBUILD_STATIC=ON -DBUILD_SHARED=OFF \
            -DBUILD_DOCUMENTATION=FALSE -DBUILD_EXAMPLES=FALSE \
            -DBUILD_TOOLS=ON -DWITH_LIBZIP=OFF > /dev/null
        cmake --build "$src/build" --parallel "$(harness_jobs)" > /dev/null
        cmake --install "$src/build" --prefix "$XLSXIO_PREFIX" > /dev/null
    fi
    export PATH="$XLSXIO_PREFIX/bin:$PATH"
    export LD_LIBRARY_PATH="$XLSXIO_PREFIX/lib:${LD_LIBRARY_PATH:-}"
}

# Configure ccache for the instrumented builds the fan-out runs repeatedly.
harness_configure_ccache() {
    if ! command -v ccache > /dev/null; then
        harness_log "ccache not found; continuing without it"
        return 0
    fi
    mkdir -p "$CCACHE_DIR"
    export CCACHE_DIR
    export CCACHE_BASEDIR="$UPSTREAM_DIR"
    export CCACHE_COMPILERCHECK=content
    export CCACHE_MAXSIZE="${CCACHE_MAXSIZE:-750M}"
    ccache --zero-stats > /dev/null 2>&1 || true
    harness_log "ccache configured at $CCACHE_DIR"
}

# One-line version report for the tools the harness lanes use.
harness_toolchain_report() {
    local t
    for t in gcc clang meson ninja cmake valgrind ccache; do
        if command -v "$t" > /dev/null; then
            printf ' %-9s %s\n' "$t" "$("$t" --version 2> /dev/null | head -1)"
        else
            printf ' %-9s MISSING\n' "$t"
        fi
    done
}
