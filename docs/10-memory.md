# Memory Architecture

Where C47's memory physically lives on each target, what bounds each region, and
how to measure any of it. Read it before changing anything that allocates,
recurses, or sizes a buffer for the firmware.

[01-codebase.md](01-codebase.md) Section 6 owns the **C47 pool**: block numbers,
the free list, program memory growing downward. This page is the machine under
that pool - the SRAM it is carved out of, the C stack beside it, and the
firmware that hands out both.

Audit basis: upstream `757d5c029199ce225f54a86fc5bf18683d230d87`, 2026-07-25.

## 1. Four arenas, four failure modes

C47 draws on four separate pools of memory. They fail differently, and the one
with no detector at all is the one this page is mostly about.

| arena | who bounds it | what C47 puts there | what exhaustion looks like | what detects it |
|---|---|---|---|---|
| **C stack** | DMCP, at a size it does not document | every call frame; the numeric kernels' multi-kilobyte local buffers | silent corruption of whatever lies below, then a hard fault | **nothing** - no guard page, no software check, and Cortex-M4 has no `MSPLIM` |
| **firmware heap** | the DMCP allocator's own arena | one `malloc` for the pool (`config.c`), plus GMP's every long integer | `malloc` returns NULL; GMP aborts | `sys_free_mem()`; the pool's own accounting sees only itself |
| **C47 pool** | `RAM_SIZE_IN_BLOCKS`, inside that one `malloc` | registers, programs, matrices, subroutine levels | `MAX_ALLOCATED_REGIONS` (`src/c47/c47.h:363`), then wrong answers | the leak and testmem lanes; the pool canary |
| **`.data`/`.bss`** | the linker script | the mutable globals that are the calculator's state - [01-codebase.md](01-codebase.md) Section 7 | link failure, so never at run time | the build |

Two consequences a newcomer gets wrong:

- **The pool is not the heap and neither is the stack.** A nested engine
  evaluation costs 12 bytes of pool for its subroutine level
  (`allocC47Blocks(3)`, `src/c47/programming/lblGtoXeq.c:171`) and about two
  *kilobytes* of C stack for its frames. Pool accounting - `getFreeRamMemory()`,
  the leak lanes, `--testmem` - cannot see the resource that actually runs out.
- **The stack is the only one with no detector.** Everything else fails loudly
  or is gated by a lane. Stack exhaustion corrupts and continues.

## 2. The DM42: a 2.4 KiB stack above 5.6 KiB of firmware state

The DM42 is an STM32L476 with 96 KiB of SRAM1 at `0x20000000` and 32 KiB of
SRAM2. C47's own linker script (`src/c47-dmcp/stm32_program.ld`) puts `.data`
and `.bss` in SRAM2 and claims **none** of SRAM1: all of it belongs to DMCP,
which splits it into an allocator arena, its own globals, and the stack.

DMCP states none of this. The numbers below are read out of the shipped image
`DMCP_flash_3.29_DM42-3.26.bin` (sha256 `c81e0dee...b2b29`) by
[`scripts/test/tooling/dmcp-stackband.py`](../scripts/test/tooling/dmcp-stackband.py),
which prints the evidence for each one:

```sh
python3 scripts/test/tooling/dmcp-stackband.py DMCP_flash_3.29_DM42-3.26.bin --sram-size 0x18000
```

| region | bounds | size | how it is known |
|---|---|---|---|
| low system words | `0x20000000`-`0x20000047` | 72 B | addressed by the allocator |
| **firmware malloc arena** | `0x20000048`-`0x20016040` | 90,104 B | the allocator's lazy init: a literal base, `add.w #90112`, `sub.w #8`, `bic #7` |
| allocator globals | `0x20016048`-`0x20016057` | 16 B | the four words its core and `free` both address |
| **DMCP OS globals** | `0x20016058`-`0x20017647` | 5,616 B | 67 distinct word addresses that firmware code loads, up to 37 sites each |
| **C stack** | `0x20017648`-`0x20017FF0` | **2,472 B** | the remainder, below the initial MSP |
| initial MSP | `0x20017FF0` | - | vector[0] |

Two independent readings put the floor at `0x20017648`: it is the top of the
cluster of addresses firmware code loads as fixed data, and it is the exclusive
upper bound of the reset handler's zero-fill loop (`0x0802CEC4`, comparing
against `0x20017648` from its literal pool). A boot loop that zeroes SRAM must
stop below the stack it is running on, so that bound *is* the stack floor.

**The arena top is not the stack floor**, and reading it that way overstates the
stack by more than three times - it skips the 5.6 KiB of OS globals between
them. That matters beyond the arithmetic: C47 uses far more than 2,472 bytes on
ordinary work, so its stack routinely descends past `0x20017648`. What it grows
into is **live firmware state**, not spare heap.

The C47 pool - 64 KiB on this target (`RAM_SIZE_IN_BLOCKS` 16384) - is
`malloc`'d out of that same 90 KiB arena. So a stack deep enough to leave its
band crosses the OS globals first and reaches the top of the arena next, which
is exactly the memory the allocator hands to the next caller. One 96 KiB SRAM,
consumed from both ends, with nothing in between to stop either.

## 3. The DM42n: the same map without the problem

`DMCP5_flash_3.55.bin` (sha256 `f6aa86be...c53ce`), same tool, no `--sram-size`
override:

- initial MSP `0x20040000`, the top of a contiguous 256 KiB SRAM
- DMCP5 addresses no fixed data above `0x2001ACB8`, which is also where the
  newlib break starts; `_sbrk` is clamped at `0x2003FC00`, one kilobyte below
  the MSP
- so ~152 KiB sits between the top of firmware state and the MSP, shared
  between a growing heap and a descending stack

C47's 256 KiB pool on this target comes from a separate pool allocator whose
control block is in firmware `.bss`, so pool pressure does not squeeze the
stack. Every stack conclusion on this page is an **old-hardware** conclusion.

## 4. What one nested evaluation costs

A user program may re-enter its own numeric engines - `SOLVE(SOLVE)` and
`PLOT(SOLVE)` are supported features - so the frames of one nested evaluation
multiply by the nesting depth. `MAX_SOLVER_NESTING_DEPTH` (`defines.h`) is the
runtime bound on that depth, and the product is what has to fit.

The per-level chains and their measured cost live in
[`scripts/test/stackprof-baseline.txt`](../scripts/test/stackprof-baseline.txt),
which the stack lane re-measures on every run and gates on when
`STACKPROF_GATE=1`. Read the number there, not here.
The shape of it is the part that does not move: **one nested SOLVE level costs
roughly the whole DM42 stack band**, so any nesting at all on the old hardware
is already spending memory the firmware did not guarantee, and the payload
inside the nest - a trig evaluation is several kilobytes on its own - is spent
on top.

That is the argument for keeping `MAX_SOLVER_NESTING_DEPTH` small on the DM42
and for moving the engines' large locals off the stack. Neither is settled here;
what is settled is that the budget is measurable, and the lane measures it.

## 5. Where the large frames are

`run-stackprof.sh` prints the largest fixed frames per target on every run. Two
of them are design decisions worth knowing before you touch them:

- **The modulo pair splits by hardware.** `WP34S_Mod` / `WP34S_BigMod` take a
  `HARDWARE_MODEL == HWM_DM42` branch (`src/c47/mathematics/wp34s.c:1543`) that
  trades digits for stack on the old hardware; the new hardware keeps the full
  precision and pays a frame of several kilobytes for it. On a target whose
  whole guaranteed stack is 2.4 KiB, that trade is not optional.
- **The angle-reduction buffers were sized by crashing.**
  `src/c47/registerValueConversions.c:1325` sizes one under the comment "This
  cannot be increased to 6147 further. 6147 overruns the stack", and `:1328`
  adds "crashes if this goes to 6147". That is a stack budget discovered by
  trial and an accuracy ceiling set by a number nobody had measured - which is
  the whole reason this page and its lane exist.

## 6. Why the engines have no static bound

Ask the profiler for the worst-case stack of any engine entry point and it
answers `RECURSIVE - no static bound`. That is correct, not a limitation:
`solver` reaches `_executeSolverReal`, which reaches `reallyRunFunction`, which
dispatches any item including ones that call `solver` again. The call graph has
a cycle, and a cycle has no finite bound - only the runtime nesting budget
closes it.

The engines are not the only cycle. GMP's divide-and-conquer kernels -
`__gmpn_toom22_mul`, `__gmpn_hgcd` and about thirty others - call themselves
directly, with a depth set by operand size rather than by any constant. The
long-integer cap bounds them; nothing in the frame sums does.

A per-level number is recovered by **cutting** the cycle deliberately:
`--cut execProgram` drops every edge into the choke point, so what remains is
one nested evaluation. The lane declares its cuts and prints them. A walk that
prunes back edges silently instead - and prints a finite number anyway - is the
failure this design exists to avoid: it reports a bound for something unbounded.

Three things no static walk sees, all of them reported rather than hidden:

- **Indirect dispatch.** Item execution goes through `blx`; the profiler counts
  the sites and says how many lie on the path it reported.
- **`alloca` and VLAs.** GMP sizes temporaries with `alloca`; the lane counts
  the functions whose frame is dynamic and prints how many lie on the path it
  reported. `gcc -fstack-usage` marks them, and the profiler excludes them from
  its own self-check, because a dynamic frame has no fixed size to check.
- **Interrupt frames.** Whatever DMCP's handlers push lands on the same stack.

## 7. Measuring it

```sh
bash scripts/test/run-stackprof.sh              # both targets, report-only
STACKPROF_GATE=1 bash scripts/test/run-stackprof.sh
```

The lane cross-builds both DMCP targets with `-fstack-usage` and profiles the
ELFs. [05-ci.md](05-ci.md) has the lane contract;
[scripts/test/README.md](../scripts/test/README.md) has what each script does.

**The profiler checks itself against the compiler on every run.** It reads frame
sizes out of the disassembly; `gcc -fstack-usage` reports the same sizes from
the front end. Every unambiguous static frame must match exactly, and a mismatch
fails the lane whatever `STACKPROF_GATE` says - a stack number nobody can check
is worse than no number. The profiler keys functions by **address, never by
name**, for the same reason: three GMP statics share a name inside one DM42 ELF,
and a name-keyed walk merges their frames and their callees.

To profile something the lane does not cover, run the tool directly:

```sh
python3 scripts/test/tooling/stackprof.py --elf build.dmcp.p4/src/c47-dmcp/C47.elf \
    --target DM42 --su-dir build.dmcp.p4 --band 2472 \
    --cut execProgram --cut printTrace --root fnSin \
    --chain 'execProgram,fnExecute,runProgram,runFunction,reallyRunFunction,fnSolve,solver'
```

`--chain` sums a named chain **and checks every link is really an edge**. That
check is the point: a chain is how a per-level cost is stated, and an upstream
refactor that reroutes the engine turns a stale chain into a plausible wrong
number. A link that is neither a direct call nor an indirect dispatch fails.

## 8. What is not established

- **Liveness of the DM42 OS globals.** The floor at `0x20017648` is where
  firmware *addresses* data. Whether every byte below it is live while a program
  runs is not provable statically; some may be boot-only. The band is therefore
  a lower bound on the stack, and the honest one to budget against.
- **How much stack C47 actually uses.** Every number here is static. The
  dynamic answer - paint the band at boot, run the corpus and real workloads,
  read the high-water mark back - would also catch the `alloca` component that
  no prologue sum sees. Nothing in this repo does that yet.
- **Interrupt and DMCP reserve.** Neither is measured, and both come out of the
  same band.
- **Whether the numbers hold on silicon.** They are read from images and ELFs.
  No reading on this page has been confirmed against a running DM42.
