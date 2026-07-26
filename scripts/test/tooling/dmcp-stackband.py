#!/usr/bin/env python3
"""Recover the C stack DMCP grants a running program, from a shipped firmware image.

DMCP documents no stack size: not the devel manual, not the SDK tree, not the linker script C47 ships. The number is in the binary. The
initial MSP is vector[0]. The floor is the highest SRAM address the firmware addresses as a fixed datum - everything below that is code's,
everything above it is the stack's, and the gap is what a program owns unconditionally.

Taking the allocator's arena top as the floor is the trap: on DMCP 3.29 the arena ends at 0x20016040 but the OS keeps another 5.6 KiB of
globals above it, so a floor read off the allocator alone overstates the stack by more than three times. This walks the whole image.

It is an instrument, not an oracle. It prints the evidence - jump-table targets, arena arithmetic, the top of the global cluster - so the
derivation can be checked, and it says which numbers are read and which are inferred. Re-run it when SwissMicros ships firmware; the
constants in docs/10-memory.md and in run-stackprof.sh are its output, not folklore.
"""

from __future__ import annotations

import argparse
import re
import struct
import subprocess
import sys
from collections import Counter
from pathlib import Path

# dep/DMCP_SDK/dmcp/lft_ifc.h: LIBRARY_FN_BASE 0x08000201, slots 0..3 are malloc/free/calloc/realloc. The odd address is the Thumb tag.
LIBRARY_FN_BASE = 0x08000200
SLOTS = ("malloc", "free", "calloc", "realloc")
BRANCH_RE = re.compile(r"\tb(?:\.w|\.n)?\s+0x([0-9a-f]+)")
# Disassembling a raw image yields no symbols and no `.word` lines - objdump decodes literal pools as instructions. The pools are still
# reachable: every pc-relative load carries its resolved literal address in objdump's comment, so follow that and read the image.
LITERAL_LOAD_RE = re.compile(r"\tldr(?:\.w)?\s+r\d+,\s*\[pc,[^]]*\]\s*@\s*\(?0x([0-9a-f]+)\)?")
ADD_IMM_RE = re.compile(r"\tadd(?:\.w)?\s+r\d+,\s*r\d+,\s*#(\d+)")


class Image:
    def __init__(self, path: Path, base: int, objdump: str) -> None:
        self.path, self.base, self.objdump = path, base, objdump
        self.data = path.read_bytes()
        self.top = base + len(self.data)

    def word(self, address: int) -> int:
        return struct.unpack_from("<I", self.data, address - self.base)[0]

    def disassemble(self, start: int | None = None, stop: int | None = None) -> str:
        options = [f"--start-address=0x{start:x}"] if start is not None else []
        options += [f"--stop-address=0x{stop:x}"] if stop is not None else []
        return subprocess.run(
            [self.objdump, "-D", "-b", "binary", "-m", "arm", "-M", "force-thumb", f"--adjust-vma=0x{self.base:x}",
             *options, str(self.path)], check=True, capture_output=True, text=True).stdout

    def sram_literals(self, text: str, low: int, high: int) -> Counter:
        """Every value in [low, high) that `text` loads from a literal pool, counted by how many sites load it."""
        found: Counter = Counter()
        for site in LITERAL_LOAD_RE.findall(text):
            address = int(site, 16)
            if self.base <= address < self.top - 4 and low <= (value := self.word(address)) < high:
                found[value] += 1
        return found


def report_allocator(image: Image, sram_low: int, sram_high: int, window: int) -> None:
    """Corroboration, not the answer: the arena bounds, from the malloc the SDK jump table points at."""
    text = image.disassemble(LIBRARY_FN_BASE, LIBRARY_FN_BASE + 4 * len(SLOTS))
    veneers = [BRANCH_RE.search(line) for line in text.splitlines()]
    targets = [int(m.group(1), 16) for m in veneers if m]
    if len(targets) < len(SLOTS):
        print("  jump table is not a run of b.w veneers - skipping the arena cross-check")
        return
    for name, target in zip(SLOTS, targets):
        print(f"  {name:>8} -> 0x{target:08X}")
    body = "".join(image.disassemble(entry, min(entry + window, image.top))
                   for entry in {targets[0], *(int(t, 16) for t in re.findall(r"\tbl\s+0x([0-9a-f]+)",
                                                                             image.disassemble(targets[0], targets[0] + window)))}
                   if image.base <= entry < image.top)
    literals = sorted(image.sram_literals(body, sram_low, sram_high))
    sizes = sorted({int(v) for v in ADD_IMM_RE.findall(body) if 0x1000 <= int(v) <= 0x100000})
    # Labelled as candidates on purpose: the window spans neighbouring functions, and nothing here distinguishes the arena base from an
    # adjacent allocator global. The arena is a sanity check on the map, never the floor - see the module docstring.
    if literals and sizes:
        print(f"  arena arithmetic: lowest literal 0x{literals[0]:08X} + 0x{sizes[-1]:X} ({sizes[-1]:,} B) -> 0x{literals[0] + sizes[-1]:08X}")
    print("  literals in the allocator window: " + ", ".join(f"0x{v:08X}" for v in literals[:8]))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("image", type=Path, help="firmware .bin as flashed, e.g. DMCP_flash_3.29_DM42-3.26.bin")
    parser.add_argument("--base", type=lambda v: int(v, 0), default=0x08000000, help="load address of the image")
    parser.add_argument("--sram", type=lambda v: int(v, 0), default=0x20000000, help="start of the SRAM the stack lives in")
    parser.add_argument("--sram-size", type=lambda v: int(v, 0), default=0x40000, help="size of that SRAM window")
    parser.add_argument("--window", type=lambda v: int(v, 0), default=0x400, help="bytes of the allocator to cross-check")
    parser.add_argument("--floor", type=lambda v: int(v, 0), help="override the derived floor")
    parser.add_argument("--top", type=int, default=12, help="how many of the highest globals to list")
    parser.add_argument("--objdump", default="arm-none-eabi-objdump")
    args = parser.parse_args()

    image = Image(args.image, args.base, args.objdump)
    sram_low, sram_high = args.sram, args.sram + args.sram_size
    print(f"image {args.image.name}: {len(image.data):,} B at 0x{image.base:08X}..0x{image.top:08X}")

    msp = image.word(image.base)
    print(f"initial MSP (vector[0])          0x{msp:08X}")
    if not sram_low <= msp <= sram_high:  # The MSP sits at the very top of RAM on the DM42n, so the window is closed at both ends.
        print(f"MSP 0x{msp:08X} is outside 0x{sram_low:08X}..0x{sram_high:08X} - wrong --base or --sram?", file=sys.stderr)
        return 2

    print(f"\nSDK jump table at 0x{LIBRARY_FN_BASE:08X} (lft_ifc.h LIBRARY_FN_BASE):")
    report_allocator(image, sram_low, sram_high, args.window)

    globals_found = image.sram_literals(image.disassemble(), sram_low, msp)
    if not globals_found:
        print("no SRAM literals anywhere in the image - wrong --sram window?", file=sys.stderr)
        return 2
    print(f"\nfixed SRAM data addressed by firmware code: {len(globals_found)} distinct, highest {args.top}:")
    for value in sorted(globals_found)[-args.top:]:
        print(f"  0x{value:08X}  loaded at {globals_found[value]} site(s)")

    derived = max(globals_found) + 4
    floor = args.floor if args.floor is not None else derived
    source = "--floor" if args.floor is not None else "highest addressed global + 4"
    print(f"\nstack floor  0x{floor:08X}   ({source})")
    print(f"initial MSP  0x{msp:08X}")
    print(f"GUARANTEED C STACK BAND: {msp - floor:,} B")
    print("\nRead: the MSP and every address above. Inferred: that the highest addressed global is the last one, which holds only if the\n"
          "firmware reaches all of its state through literal pools. Deeper use than the band is not an error - it is a bet that the\n"
          "memory below the floor is still free, and on the DM42 that memory is the top of the heap the allocator hands out.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
