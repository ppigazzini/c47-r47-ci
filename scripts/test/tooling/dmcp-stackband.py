#!/usr/bin/env python3
"""Map the SRAM a shipped DMCP firmware image hands out, and say which stack is which.

DMCP documents none of this: not the devel manual, not the SDK tree, not the linker script C47 ships. It is all in the binary.

The trap this tool exists to avoid is mislabelling. `vector[0]` is the initial MSP, and the gap between it and the top of the firmware's own
data looks exactly like "the C stack a program gets" - both a previous reading of this image (8,088 B, taken from the allocator arena top)
and its correction (2,472 B, taken from the top of kernel data) named it that. Both measured the MSP band. Neither is the stack a program
runs on: SVCall and PendSV in this image are a FreeRTOS context switch that writes PSP, so programs run in thread mode on a **task stack
allocated from the malloc arena**. The MSP band is the handler and boot stack.

So the tool reports three separate things and refuses to conflate them:

  1. the MSP band          - initial MSP down to the top of addressed firmware data, with a two-signal cross-check
  2. the scheduler verdict - whether thread mode runs on PSP, which decides whether (1) is a program's stack at all
  3. the arena budget      - what is left of the malloc arena once C47's pool is taken, the real ceiling on a task stack

Evidence, not assertion: it prints the reference density per region, because that is what separates "the allocator's heap" from "the kernel's
globals" - the arena is addressed a handful of times across 90 KiB, the kernel region tens of times per KiB.
"""

from __future__ import annotations

import argparse
import re
import struct
import subprocess
import sys
from pathlib import Path

# dep/DMCP_SDK/dmcp/lft_ifc.h: LIBRARY_FN_BASE 0x08000201, slots 0..3 are malloc/free/calloc/realloc. The odd address is the Thumb tag.
LIBRARY_FN_BASE = 0x08000200
SLOTS = ("malloc", "free", "calloc", "realloc")
# Cortex-M vector table slots that decide which stack thread mode uses.
VECTOR_MSP, VECTOR_RESET, VECTOR_SVCALL, VECTOR_PENDSV = 0, 1, 11, 14
BRANCH_RE = re.compile(r"\tb(?:\.w|\.n)?\s+0x([0-9a-f]+)")
# Disassembling a raw image yields no symbols and no `.word` lines - objdump decodes literal pools as instructions. The pools are still
# reachable: every pc-relative load carries its resolved literal address in objdump's comment, so follow that and read the image.
LITERAL_LOAD_RE = re.compile(r"^\s*([0-9a-f]+):\t[0-9a-f ]+\tldr(?:\.w)?\s+r\d+,\s*\[pc,[^]]*\]\s*@\s*\(?0x([0-9a-f]+)\)?", re.M)
ADD_IMM_RE = re.compile(r"\tadd(?:\.w)?\s+r\d+,\s*r\d+,\s*#(\d+)")
SP_WRITE_RE = re.compile(r"^\s*([0-9a-f]+):\t[0-9a-f ]+\tmsr\s+(MSP|PSP|CONTROL)", re.M)
# FreeRTOS paints a new task's stack with tskSTACK_FILL_BYTE so uxTaskGetStackHighWaterMark can read it back.
STACK_FILL_RE = re.compile(r"\tmovs?\s+r\d+,\s*#165\b|\tmov\.w\s+r\d+,\s*#165\b")


class Image:
    def __init__(self, path: Path, base: int, objdump: str) -> None:
        self.path, self.base, self.objdump = path, base, objdump
        self.data = path.read_bytes()
        self.top = base + len(self.data)
        self._full: str | None = None

    def word(self, address: int) -> int:
        return struct.unpack_from("<I", self.data, address - self.base)[0]

    def vector(self, slot: int) -> int:
        return self.word(self.base + 4 * slot)

    def disassemble(self, start: int | None = None, stop: int | None = None) -> str:
        options = [f"--start-address=0x{start:x}"] if start is not None else []
        options += [f"--stop-address=0x{stop:x}"] if stop is not None else []
        return subprocess.run(
            [self.objdump, "-D", "-b", "binary", "-m", "arm", "-M", "force-thumb", f"--adjust-vma=0x{self.base:x}", *options, str(self.path)],
            check=True,
            capture_output=True,
            text=True,
        ).stdout

    def full(self) -> str:
        """The whole image, disassembled once and reused - it is ~1 MB and several seconds."""
        if self._full is None:
            self._full = self.disassemble()
        return self._full

    def literal_sites(self, text: str) -> dict[int, list[int]]:
        """value -> the addresses of the instructions that load it from a literal pool."""
        sites: dict[int, list[int]] = {}
        for site, pool in LITERAL_LOAD_RE.findall(text):
            address = int(pool, 16)
            if self.base <= address < self.top - 4:
                sites.setdefault(self.word(address), []).append(int(site, 16))
        return sites


def find_fill_bounds(image: Image, sram: tuple[int, int]) -> dict[int, int]:
    """Locate boot memory-fill loops and return {one-past-the-end address: loop address}.

    The shape is a post-increment store followed by a compare against a literal and a backward branch. It is the second, independent signal
    for where firmware data ends: a loop that clears SRAM must stop below the stack it is itself running on, so its bound is an upper bound
    on the data below and a lower bound on the stack above.
    """
    lines = image.full().splitlines()
    store = re.compile(r"^\s*([0-9a-f]+):\t[0-9a-f ]+\tstr(?:\.w)?\s+r\d+,\s*\[r\d+\],\s*#4")
    load = re.compile(r"\tldr(?:\.w)?\s+r\d+,\s*\[pc,[^]]*\]\s*@\s*\(?0x([0-9a-f]+)\)?")
    bounds: dict[int, int] = {}
    for index, line in enumerate(lines):
        match = store.match(line)
        if not match:
            continue
        window = lines[index + 1 : index + 8]
        if not any("\tcmp\t" in w or "\tcmp " in w for w in window):
            continue
        for candidate in window:
            found = load.search(candidate)
            if not found:
                continue
            pool = int(found.group(1), 16)
            if image.base <= pool < image.top - 4 and sram[0] <= (value := image.word(pool)) <= sram[1]:
                bounds[value] = int(match.group(1), 16)
    return bounds


def report_scheduler(image: Image) -> bool:
    """Decide whether thread mode runs on the process stack, and say what that means for the MSP band.

    Returns True when the MSP band is the handler stack rather than a program's. The test is structural rather than by name: the image
    carries no RTOS strings, but a SVCall/PendSV pair that writes PSP is a context switch whatever it is called.
    """
    writes = [(int(a, 16), r) for a, r in SP_WRITE_RE.findall(image.full())]
    print("\n-- which stack does thread mode use --")
    for slot, name in ((VECTOR_SVCALL, "SVCall"), (VECTOR_PENDSV, "PendSV")):
        print(f"  vector[{slot:2d}] {name:6s} = 0x{image.vector(slot):08X}")
    for address, register in writes:
        print(f"  0x{address:08X}  msr {register}")
    if not any(r == "CONTROL" for _, r in writes):
        print("  no `msr CONTROL`: SPSEL is never set directly, so a switch to PSP can only come from an exception return")
    handlers = {image.vector(slot) & ~1 for slot in (VECTOR_SVCALL, VECTOR_PENDSV)}
    psp_in_handler = any(r == "PSP" and any(0 <= address - handler < 0x100 for handler in handlers) for address, r in writes)
    if psp_in_handler:
        print("  VERDICT: SVCall/PendSV write PSP - this is a context switch, so thread mode runs on a TASK stack.")
        print("           The MSP band below is the HANDLER and boot stack. It is NOT the stack a program gets.")
    else:
        print("  VERDICT: no PSP write in SVCall/PendSV - thread mode appears to stay on MSP, so the band below is a program's stack.")
    fills = len(STACK_FILL_RE.findall(image.full()))
    if fills:
        print(f"  task stacks are painted with 0xA5 ({fills} sites), so a high-water mark can be read back on hardware")
    return psp_in_handler


def report_regions(image: Image, sites: dict[int, list[int]], arena: tuple[int, int] | None, sram: tuple[int, int]) -> None:
    """Reference density per region - the evidence that separates heap from kernel globals.

    A malloc arena is addressed by the allocator and nobody else; a region of globals is addressed by whoever owns them, over and over. The
    density difference is what makes the boundary a measurement rather than a guess, and it is also the check against decode noise: SRAM is
    a tiny slice of the address space, so a mis-decoded literal almost never lands in it, and never lands in it repeatedly.
    """
    total = len(LITERAL_LOAD_RE.findall(image.full()))
    print(f"\n-- reference density by region ({total:,} pc-relative loads decoded) --")
    bands = [(0x10000000, 0x10008000, "SRAM2")]
    if arena:
        bands += [(arena[0], arena[1], "malloc arena"), (arena[1], sram[1], "SRAM1 above the arena")]
    else:
        bands += [(sram[0], sram[1], "SRAM1")]
    for low, high, label in bands:
        chosen = {v: s for v, s in sites.items() if low <= v < high}
        refs = sum(len(s) for s in chosen.values())
        kib = (high - low) / 1024
        print(f"  {label:24s} 0x{low:08X}-0x{high:08X}  distinct={len(chosen):4d}  refs={refs:5d}  {refs / kib:7.2f} refs/KiB")


def report_arena(image: Image, window: int, pool_bytes: int) -> tuple[int, int] | None:
    """The malloc arena, from the allocator the SDK jump table points at - and what is left of it once the pool is taken.

    This is the budget that actually bounds a task stack, because the stack, GMP's long integers and C47's pool all come from one arena.
    """
    text = image.disassemble(LIBRARY_FN_BASE, LIBRARY_FN_BASE + 4 * len(SLOTS))
    targets = [int(m.group(1), 16) for m in (BRANCH_RE.search(line) for line in text.splitlines()) if m]
    print(f"\n-- the malloc arena, via the SDK jump table at 0x{LIBRARY_FN_BASE:08X} --")
    if len(targets) != len(SLOTS):
        print(f"  not a run of {len(SLOTS)} b.w veneers ({len(targets)} found) - cannot locate the allocator")
        return None
    for name, target in zip(SLOTS, targets, strict=True):
        print(f"  {name:>8} -> 0x{target:08X}")
    body = image.disassemble(targets[0], min(targets[0] + window, image.top))
    for callee in sorted({int(t, 16) for t in re.findall(r"\tbl\s+0x([0-9a-f]+)", body)}):
        if image.base <= callee < image.top:
            body += image.disassemble(callee, min(callee + window, image.top))
    candidates = sorted(v for v in image.literal_sites(body) if 0x20000000 <= v < 0x20080000)
    sizes = sorted({int(v) for v in ADD_IMM_RE.findall(body) if 0x1000 <= int(v) <= 0x100000})
    # The allocator's own globals sit next to the arena base and are indistinguishable by value alone - taking the lowest literal picks one
    # of them and shifts the arena by a few bytes. A malloc arena base is 8-aligned; those neighbours are not, which is the discriminator.
    aligned = [v for v in candidates if v % 8 == 0]
    if not (aligned and sizes):
        print(f"  could not recover the arena arithmetic (SRAM literals {[hex(v) for v in candidates]}, sizes {sizes})")
        return None
    base, size = aligned[0], sizes[-1]
    if candidates and candidates[0] != base:
        print(f"  ignoring unaligned neighbour 0x{candidates[0]:08X} (allocator global, not the arena base)")
    # The allocator's lazy init 8-aligns the top after reserving one word, so the usable end is base+size-8 rounded down.
    end = (base + size - 8) & ~7
    print(f"  base 0x{base:08X} + 0x{size:X} ({size:,} B), less the allocator's own word -> usable end 0x{end:08X}")
    print(f"  usable arena            {end - base:,} B")
    if pool_bytes:
        print(f"  less C47's pool         -{pool_bytes:,} B")
        print(f"  LEFT FOR THE TASK STACK, GMP AND EVERY OTHER ALLOCATION: {end - base - pool_bytes:,} B")
    return base, end


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("image", type=Path, help="firmware .bin as flashed, e.g. DMCP_flash_3.29_DM42-3.26.bin")
    parser.add_argument("--base", type=lambda v: int(v, 0), default=0x08000000, help="load address of the image")
    parser.add_argument("--sram", type=lambda v: int(v, 0), default=0x20000000, help="start of the SRAM the stacks live in")
    parser.add_argument("--sram-size", type=lambda v: int(v, 0), default=0x40000, help="size of that SRAM window")
    parser.add_argument("--window", type=lambda v: int(v, 0), default=0x400, help="bytes of the allocator to walk")
    parser.add_argument("--pool-bytes", type=lambda v: int(v, 0), default=0, help="C47 pool size, to subtract from the arena")
    parser.add_argument("--floor", type=lambda v: int(v, 0), help="override the derived top of firmware data")
    parser.add_argument("--top", type=int, default=8, help="how many of the highest addressed data words to list")
    parser.add_argument("--objdump", default="arm-none-eabi-objdump")
    args = parser.parse_args()

    image = Image(args.image, args.base, args.objdump)
    sram = (args.sram, args.sram + args.sram_size)
    print(f"image {args.image.name}: {len(image.data):,} B at 0x{image.base:08X}..0x{image.top:08X}")

    msp = image.vector(VECTOR_MSP)
    print(f"vector[ 0] initial MSP = 0x{msp:08X}")
    print(f"vector[ 1] Reset       = 0x{image.vector(VECTOR_RESET):08X}")
    if not sram[0] <= msp <= sram[1]:  # The MSP sits at the very top of RAM on the DM42n, so the window is closed at both ends.
        print(f"MSP 0x{msp:08X} is outside 0x{sram[0]:08X}..0x{sram[1]:08X} - wrong --base or --sram?", file=sys.stderr)
        return 2

    handler_stack = report_scheduler(image)
    arena = report_arena(image, args.window, args.pool_bytes)
    sites = image.literal_sites(image.full())
    report_regions(image, sites, arena, sram)

    in_sram = {v: s for v, s in sites.items() if sram[0] <= v < msp}
    if not in_sram:
        print("no SRAM literals anywhere in the image - wrong --sram window?", file=sys.stderr)
        return 2
    print(f"\n-- top of addressed firmware data ({len(in_sram)} distinct values below the MSP) --")
    for value in sorted(in_sram)[-args.top :]:
        print(f"  0x{value:08X}  {len(in_sram[value])} site(s)")

    # Two independent signals for the same boundary: the highest word any code addresses, and where the boot zero-fill stops. The second is
    # found structurally - a post-increment store loop with a literal bound - rather than by guessing from reference counts, which cannot
    # tell a once-read global from a loop limit.
    bounds = find_fill_bounds(image, sram)
    highest = max(in_sram)
    floor = args.floor if args.floor is not None else highest + 4
    print("\n-- cross-check: two signals for the same boundary --")
    print(f"  highest addressed word           0x{highest:08X}")
    if bounds:
        for bound, site in sorted(bounds.items()):
            print(f"  boot fill loop stops at          0x{bound:08X}  (loop at 0x{site:08X})")
        # A fill loop's limit is the last word it writes or the first it does not, depending on how the compiler shaped the compare, so
        # agreement means within one word - not equality. Demanding equality reported a real agreement as a mismatch on DMCP5.
        nearest = min(bounds, key=lambda b: abs(b - highest))
        agree = abs(nearest - highest) <= 4
        print(f"  nearest bound to it              0x{nearest:08X}  ({nearest - highest:+d} B)")
        print(f"  the two agree within a word: {agree}" + ("" if agree else "  <- they should; re-derive by hand before trusting the band"))
        if agree:
            # One word of irreducible uncertainty: a literal pool holds bare words, so nothing distinguishes "the address of the last
            # datum" from "a pointer value the code stores" - on the DM42n the top value is the initial heap break, not a variable. Take
            # the conservative end (a smaller band) and say so rather than imply 4-byte precision.
            floor = args.floor if args.floor is not None else max(highest, nearest) + 4
            print("  the floor is uncertain by one word: a literal pool cannot tell a datum's address from a stored pointer, so the band")
            print(f"  below is the conservative end of {msp - floor:,}..{msp - floor + 4:,} B")
    else:
        print("  no boot fill loop found - the band below rests on ONE signal only")

    label = "MSP (HANDLER AND BOOT) STACK BAND" if handler_stack else "C STACK BAND"
    print(f"\n{label}: {msp - floor:,} B   (0x{floor:08X}..0x{msp:08X})")
    if handler_stack:
        print("  A program does NOT run on this. Its stack is a task stack out of the arena above - budget with that number, not this one.")
    print(
        "\nRead: the vector table, the addresses above, the arena arithmetic. Inferred: that the highest addressed word is the last one,\n"
        "which holds only while the firmware reaches its state through literal pools. Not knowable from an image at all: the size the\n"
        "scheduler gave the task a program runs on. That needs a high-water read on hardware."
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
