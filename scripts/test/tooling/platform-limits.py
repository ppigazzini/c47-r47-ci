#!/usr/bin/env python3
"""Print the compile-time memory and capacity limits of every c47 target, side by side.

The limits are `#if`-selected in `src/c47/defines.h` by a handful of target macros, so a claim about "the DM42's pool" or "the
simulator's" is a claim about which branch a build took. This asks the preprocessor instead of a human: for each platform it compiles a
generated probe against upstream's own `defines.h` with that platform's macros, runs it, and tabulates what came back. A value that
differs across platforms is flagged, because those are the ones that make a simulator result mean nothing about hardware.

Every platform is evaluated by the **host** compiler with the target's `-D` flags. That is exact for integer constants, which is all this
reports; a limit derived from `sizeof` of a target type would be a host answer to a target question, so any name whose expansion mentions
`sizeof` is refused rather than printed.
"""

from __future__ import annotations

import argparse
import json
import re
import resource
import subprocess
import sys
import tempfile
from pathlib import Path

# name -> what the reader needs it for. Absent names are reported absent: upstream renames a macro and the row says so, rather than the
# probe failing to compile or, worse, a stale number surviving in a doc.
LIMITS: tuple[tuple[str, str], ...] = (
    ("HARDWARE_MODEL", "which hardware the build believes it is"),
    ("BPB", "log2 of the pool block size"),
    ("RAM_SIZE_IN_BLOCKS", "pool size, in blocks"),
    ("MAX_FREE_REGIONS", "free-list fragmentation ceiling"),
    ("MAX_ALLOCATED_REGIONS", "allocation-tracking ceiling (host debug only)"),
    ("C47_NULL", "the block number that means NULL, so the pool must stay below it"),
    ("NUMBER_OF_GLOBAL_REGISTERS", "global register file size"),
    ("NUMBER_OF_LOCAL_REGISTERS", "local registers per subroutine level"),
    ("FLASH_PGM_PAGE_SIZE", "flash program page size"),
    ("FLASH_PGM_NUMBER_OF_PAGES", "flash program pages"),
    ("MAX_LONG_INTEGER_SIZE_IN_BITS", "long-integer cap, and the bound on GMP's alloca temporaries"),
    ("AIM_BUFFER_LENGTH", "alpha input buffer"),
    ("TMP_STR_LENGTH", "the shared scratch string"),
    ("MAX_INTEGRATOR_NESTING_DEPTH", "runtime cap on nested integrate() re-entry"),
    ("MAX_SOLVER_NESTING_DEPTH", "runtime cap on nested engine evaluation, if this tree has one"),
)

# Platform -> the macros its meson build defines. Sourced from src/c47-dmcp/meson.build (-DOLD_HW), src/c47-dmcp5/meson.build (-DNEW_HW),
# and meson.build:24-41 for PC_BUILD and the OS32BIT/OS64BIT pair - cross builds are always 32-bit, the host follows its pointer size.
# OS32BIT/OS64BIT gate nothing but a consistency check in defines.h, so they are here to let the probe compile, not to change a value.
# DMCP_PACKAGE selects feature subsets of one DM42 memory model, so it is not a platform here - see run-stackprof.sh, which profiles each.
PLATFORMS: tuple[tuple[str, tuple[str, ...]], ...] = (
    ("DM42", ("DMCP_BUILD", "OLD_HW", "OS32BIT")),
    ("DM42n", ("DMCP_BUILD", "NEW_HW", "OS32BIT")),
    ("sim-linux", ("PC_BUILD", "LINUX", "OS64BIT")),
    ("sim-windows", ("PC_BUILD", "WIN32", "OS64BIT")),
    ("sim-macos", ("PC_BUILD", "OSX", "OS64BIT")),
)

SIZEOF_RE = re.compile(r"\bsizeof\b")


def macro_expansions(defines_h: Path, include_dirs: list[Path], macros: tuple[str, ...], cc: str) -> dict[str, str]:
    """Every macro definition `defines.h` leaves standing under one platform's flags, as written."""
    command = [cc, "-E", "-dM", *(f"-D{m}" for m in macros), *(f"-I{d}" for d in include_dirs), str(defines_h)]
    text = subprocess.run(command, check=True, capture_output=True, text=True).stdout
    return {m.group(1): m.group(2).strip() for m in re.finditer(r"^#define (\w+) (.*)$", text, re.M)}


def probe(defines_h: Path, include_dirs: list[Path], macros: tuple[str, ...], names: list[str], cc: str) -> dict[str, int]:
    """Compile and run a probe that prints each name's value, so the answer is the compiler's arithmetic and not a re-implementation."""
    body = "\n".join(f'#ifdef {n}\n  printf("{n}=%lld\\n", (long long)({n}));\n#endif' for n in names)
    # defines.h defines inline helpers over the fixed-width types, so stdint has to precede it; it includes nothing itself.
    source = ("#include <stdio.h>\n#include <stdint.h>\n"
              + "".join(f"#define {m} 1\n" for m in macros)
              + f'#include "{defines_h}"\n'
              + f"int main(void) {{\n{body}\n  return 0;\n}}\n")
    with tempfile.TemporaryDirectory() as work:
        src = Path(work) / "probe.c"
        exe = Path(work) / "probe"
        src.write_text(source, encoding="utf-8")
        build = subprocess.run([cc, "-w", *(f"-I{d}" for d in include_dirs), str(src), "-o", str(exe)],
                               capture_output=True, text=True)
        if build.returncode != 0:
            print(f"probe failed to build for {','.join(macros)}:\n{build.stderr[-2000:]}", file=sys.stderr)
            return {}
        out = subprocess.run([str(exe)], check=True, capture_output=True, text=True).stdout
    return {k: int(v) for k, v in (line.split("=", 1) for line in out.splitlines() if "=" in line)}


def host_stack_limit() -> tuple[int, str]:
    """The simulator's C stack is the host thread's, so report the host's actual soft limit rather than a remembered default."""
    soft, _ = resource.getrlimit(resource.RLIMIT_STACK)
    if soft == resource.RLIM_INFINITY:
        return -1, "unlimited (RLIMIT_STACK)"
    return soft, f"{soft:,} B soft RLIMIT_STACK on this host"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("upstream", type=Path, help="the c43 clone")
    parser.add_argument("--cc", default="cc", help="host compiler used to evaluate every platform's integer constants")
    parser.add_argument("--json", type=Path, help="write the matrix here")
    args = parser.parse_args()

    defines_h = args.upstream / "src" / "c47" / "defines.h"
    if not defines_h.is_file():
        print(f"no {defines_h} - is {args.upstream} a c43 clone?", file=sys.stderr)
        return 2
    include_dirs = [args.upstream / "src" / "c47", args.upstream / "src" / "generated"]

    names = [name for name, _ in LIMITS]
    # Refuse any limit whose expansion is target-dependent: the host cannot answer it, and a wrong number here would look like a fact.
    # Both passes matter. Deciding first, probing second, keeps one unsafe name from failing the probe and blanking a whole platform's
    # column - which reads as "these limits do not exist" rather than "one of them was not asked".
    unsafe: dict[str, set[str]] = {}
    expansions_by_platform: dict[str, dict[str, str]] = {}
    for platform, macros in PLATFORMS:
        expansions_by_platform[platform] = macro_expansions(defines_h, include_dirs, macros, args.cc)
        for name in names:
            if SIZEOF_RE.search(expansions_by_platform[platform].get(name, "")):
                unsafe.setdefault(name, set()).add(platform)
    safe = [name for name in names if name not in unsafe]
    values: dict[str, dict[str, int]] = {}
    for platform, macros in PLATFORMS:
        values[platform] = probe(defines_h, include_dirs, macros, safe, args.cc)

    platforms = [p for p, _ in PLATFORMS]
    width = max(len(p) for p in platforms)
    print(f"c47 compile-time limits, from {defines_h}")
    print(f"evaluated by {args.cc}; every column is upstream's own arithmetic under that platform's macros\n")
    header = "  ".join(f"{p:>{width}}" for p in platforms)
    print(f"{'limit':<34}{header}   differs?")
    print("-" * (34 + len(header) + 12))

    matrix: dict[str, dict[str, object]] = {}
    for name, purpose in LIMITS:
        if name in unsafe:
            print(f"{name:<34}{'target-dependent (sizeof) - not evaluated':<{len(header)}}")
            matrix[name] = {"skipped": "sizeof"}
            continue
        row = {p: values[p].get(name) for p in platforms}
        cells = "  ".join(f"{('-' if row[p] is None else row[p]):>{width}}" for p in platforms)
        present = {v for v in row.values() if v is not None}
        flag = "DIFFERS" if len(present) > 1 else ("absent" if not present else "")
        print(f"{name:<34}{cells}   {flag}")
        matrix[name] = {"values": row, "differs": len(present) > 1, "purpose": purpose}

    print("\nderived:")
    for platform in platforms:
        blocks, bpb = values[platform].get("RAM_SIZE_IN_BLOCKS"), values[platform].get("BPB")
        if blocks and bpb is not None:
            size = blocks * (1 << bpb)
            print(f"  {platform:>{width}}  pool {size:,} B ({size / 1024:.0f} KiB)")
            matrix.setdefault("pool_bytes", {}).setdefault("values", {})[platform] = size

    limit, description = host_stack_limit()
    print(f"\n  the simulator's C stack is the host thread's: {description}")
    matrix["host_stack_limit"] = {"values": {"host": limit}, "note": description}

    if args.json:
        args.json.write_text(json.dumps(matrix, indent=2, default=str), encoding="utf-8")
    return 0


if __name__ == "__main__":
    sys.exit(main())
