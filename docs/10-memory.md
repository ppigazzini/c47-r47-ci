# Memory Architecture

Where C47's memory physically lives on **each supported platform**, what bounds
each region, where the platforms disagree, and how to measure any of it. Read it
before changing anything that allocates, recurses, or sizes a buffer.

[01-codebase.md](01-codebase.md) Section 6 owns the **C47 pool**: block numbers,
the free list, program memory growing downward. This page is the machine under
that pool - the SRAM it is carved out of, the C stack beside it, and the
firmware or host that hands out both.

Audit basis: upstream `5e628d1e0f8552360c56c12f44fb14b8fe2d0f37`, 2026-07-26.

## 1. Four arenas, four failure modes

C47 draws on four separate pools of memory. They fail differently, and the one
with no detector at all is the one this page is mostly about.

| arena | who bounds it | what C47 puts there | what exhaustion looks like | what detects it |
|---|---|---|---|---|
| **C stack** | DMCP or the host thread, at a size DMCP does not document | every call frame; the numeric kernels' multi-kilobyte local buffers | silent corruption of whatever lies below, then a hard fault | **nothing** - no guard page, no software check, and Cortex-M4 has no `MSPLIM` |
| **firmware heap** | the DMCP allocator's arena, or the host `malloc` | one `malloc` for the pool (`config.c`), plus GMP's every long integer | `malloc` returns NULL; GMP aborts | `sys_free_mem()`; the pool's own accounting sees only itself |
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

## 2. The platforms, and where they disagree

Every limit below is `#if`-selected in `src/c47/defines.h`, so which value a
build gets is a property of its macros. Regenerate the whole matrix rather than
trusting a number here:

```sh
python3 scripts/test/tooling/platform-limits.py <c43-clone>
```

| | DM42 | DM42n | simulator |
|---|---|---|---|
| build | `make dmcp` (`-DOLD_HW`) | `make dmcp5` (`-DNEW_HW`) | `make simc47` (`-DPC_BUILD`) |
| core | Cortex-M4, DMCP | Cortex-M33, DMCP5 | host x86-64 or arm64 |
| `HARDWARE_MODEL` | `HWM_DM42` | `HWM_DM42n` | **not defined** |
| C47 pool | **64 KiB** | 256 KiB | **256 KiB** |
| `MAX_FREE_REGIONS` | **50** | 200 | **200** |
| `MAX_ALLOCATED_REGIONS` | not defined | not defined | 5000 |
| guaranteed C stack | **2,472 B** | **152,392 B** | the host thread's, 8 MiB by default on Linux |
| optimisation | `-Os -flto` | `-Os -flto` | `-O0`, LTO overridden per target |

**The simulator is built with the new hardware's memory model.** Its pool and its
free-region ceiling are the DM42n's, four times the DM42's, so a DM42 pool
exhaustion or free-list fragmentation failure **cannot be reproduced on the
simulator at all** - it will run out four times later or not at all. Its stack is
larger again by three orders of magnitude. Anything you conclude about DM42
memory from a simulator run is unfounded; the lane exists to give you the
hardware answer instead.

Two smaller divergences with real consequences:

- **`HARDWARE_MODEL` is undefined on host builds**, so every
  `#if defined(DMCP_BUILD) && HARDWARE_MODEL == HWM_DM42` branch is false there.
  The simulator takes the DM42n path, not the DM42 path - including the
  full-precision, stack-hungry side of the modulo split in Section 6.
- **`MAX_ALLOCATED_REGIONS` exists only on host builds**, so the pool's
  allocation tracking, and the size-mismatch detector built on it, are host-only.
  A wrong `freeC47Blocks` size corrupts the free list silently on hardware.

### The DM42 ships as four feature packages

`DMCP_PACKAGE` selects which functions are compiled in, so the DM42 has one
memory model but four different sets of built code - and therefore four different
largest-frame lists and worst-case paths. `src/c47/defines.h:154` tabulates what
each carries: package 3 is the only one with eigenvalues, package 2 the only one
with the full elliptic/Bessel/orthogonal set, package 4 the aggressive subset the
Makefile defaults to and CI builds.

**With `arm-none-eabi-gcc` 13.2.1, only package 4 links.** Packages 1, 2 and 3
overflow the 704 KiB internal `FLASH` region (`src/c47-dmcp/stm32_program.ld`) by
a few hundred to a few thousand bytes; the lane prints the current overflow for
each, and the amount moves with every upstream commit, so read it from the run
rather than from here. `make dmcp_pkgs_all` builds 1, 2 and 3, so that target
fails here too. The lane profiles the packages that build and reports the rest;
whether upstream CI's toolchain still fits them is not something this repo can
see. **Package 3 is the one that matters most and the one nobody can measure** -
it is the only build carrying eigenvalues, on the target with the least stack.

## 3. The DM42: a 2.4 KiB stack above 5.6 KiB of firmware state

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

## 4. The DM42n: the same map without the problem

`DMCP5_flash_3.55.bin` (sha256 `f6aa86be...c53ce`), same tool, no `--sram-size`
override:

- initial MSP `0x20040000`, the top of a contiguous 256 KiB SRAM
- DMCP5 addresses no fixed data above `0x2001ACB8`, which is also where the
  newlib break starts; `_sbrk` is clamped at `0x2003FC00`, one kilobyte below
  the MSP
- so 152,392 B sit between the top of firmware state and the MSP, shared
  between a growing heap and a descending stack

C47's 256 KiB pool on this target comes from a separate pool allocator whose
control block is in firmware `.bss`, so pool pressure does not squeeze the
stack. Every stack conclusion on this page is an **old-hardware** conclusion.

## 5. What one nested evaluation costs, per platform

A user program may re-enter its own numeric engines - `SOLVE(SOLVE)` and
`PLOT(SOLVE)` are supported features - so the frames of one nested evaluation
multiply by the nesting depth. On current upstream the only runtime bound is
`MAX_INTEGRATOR_NESTING_DEPTH` (5, `src/c47/defines.h:565`) and it caps the
**integrator only**; the solver, sum/product, differentiator and grapher have
none, which is why `run-nestcheck.sh` still records crashes. c43 MR !1610
proposes one bound at the `execProgram` choke point.

The per-level chains and their measured cost live in
[`scripts/test/stackprof-baseline.txt`](../scripts/test/stackprof-baseline.txt),
which the stack lane re-measures on every run and gates on when
`STACKPROF_GATE=1`. Read the numbers there, not here. The shape of it is the
part that does not move: **one nested SOLVE level costs roughly the whole DM42
stack band**, so any nesting at all on the old hardware is already spending
memory the firmware did not guarantee, and the payload inside the nest - a trig
evaluation is several kilobytes on its own - is spent on top. On the DM42n the
same level fits sixty times over.

**The simulator does not even have the same call chain.** The firmware is built
with `-flto`, the simulator at `-O0`: LTO inlines `executeOneStep` into
`runProgram` and splits `_fnIntegrate` into a `.part.0` clone, neither of which
happens on the host. The baseline therefore carries separate `sim` chains, and
the simulator's per-level cost is the *largest* of the three platforms while its
stack is the largest by three orders of magnitude. It is the one platform on
which this class of bug cannot be observed.

## 6. Where the large frames are

`run-stackprof.sh` prints the largest fixed frames per platform on every run. Two
of them are design decisions worth knowing before you touch them:

- **The modulo pair splits by hardware.** `WP34S_Mod` / `WP34S_BigMod` take a
  `HARDWARE_MODEL == HWM_DM42` branch (`src/c47/mathematics/wp34s.c:1543`) that
  trades digits for stack on the old hardware; every other build keeps the full
  precision and pays a frame of several kilobytes for it. On a target whose whole
  guaranteed stack is 2.4 KiB, that trade is not optional - and because
  `HARDWARE_MODEL` is undefined on host builds, the simulator pays the large
  frame, so it cannot show you the small one working.
- **The angle-reduction buffers were sized by crashing.**
  `src/c47/registerValueConversions.c:1325` sizes one under the comment "This
  cannot be increased to 6147 further. 6147 overruns the stack", and `:1328`
  adds "crashes if this goes to 6147". That is a stack budget discovered by
  trial and an accuracy ceiling set by a number nobody had measured - which is
  the whole reason this page and its lane exist.

## 7. Why the engines have no static bound

Ask the profiler for the worst-case stack of any engine entry point and it
answers `RECURSIVE - no static bound`. That is correct, not a limitation:
`solver` reaches `_executeSolverReal`, which reaches `reallyRunFunction`, which
dispatches any item including ones that call `solver` again. The call graph has
a cycle, and a cycle has no finite bound - only a runtime nesting budget closes
it.

The engines are not the only cycle. GMP's divide-and-conquer kernels -
`__gmpn_toom22_mul`, `__gmpn_hgcd` and about thirty others - call themselves
directly, with a depth set by operand size rather than by any constant. The
long-integer cap bounds them; nothing in the frame sums does. The simulator
links the *system* GMP, so those frames are not even in its binary.

A per-level number is recovered by **cutting** the cycle deliberately:
`--cut execProgram` drops every edge into the choke point, so what remains is
one nested evaluation. The lane declares its cuts and prints them. A walk that
prunes back edges silently instead - and prints a finite number anyway - is the
failure this design exists to avoid: it reports a bound for something unbounded.

Three things no static walk sees, all of them reported rather than hidden:

- **Indirect dispatch.** Item execution goes through `blx` on ARM and `call *` on
  x86-64; the profiler counts the sites and says how many lie on the path it
  reported.
- **`alloca` and VLAs.** GMP sizes temporaries with `alloca`; the lane counts the
  functions whose frame is dynamic and prints how many lie on the path it
  reported. `gcc -fstack-usage` marks them, and the profiler excludes them from
  its own self-check, because a dynamic frame has no fixed size to check.
- **Interrupt frames.** Whatever DMCP's handlers push lands on the same stack.

## 8. Measuring it

```sh
bash scripts/test/run-stackprof.sh              # every platform, report-only
STACKPROF_GATE=1 bash scripts/test/run-stackprof.sh
```

The lane profiles each DM42 package, the DM42n and the host simulator with one
instrument, so the platform comparison is measured rather than assumed. It reads
frame sizes out of the disassembly for two instruction sets - Thumb and x86-64 -
and the ISA is detected from the disassembly, so the same command serves a
firmware ELF and a simulator binary. [05-ci.md](05-ci.md) has the lane contract;
[scripts/test/README.md](../scripts/test/README.md) has what each script does.

**The profiler is calibrated against the compiler on every run, once per
instruction set.** It compares every unambiguous static frame it extracts against
`gcc -fstack-usage`. An **under**-report fails the lane whatever
`STACKPROF_GATE` says: a bound below the real frame is a bound that permits the
overflow it was meant to prevent. An over-report is the documented cost of
summing every allocation a function makes instead of tracing which can co-occur,
and is printed with its total so it cannot grow unnoticed.

**Calibration needs its own build, and LTO is why.** The shipped firmware and
simulator are both built with `-flto`, which defers code generation to link time,
so GCC writes no per-translation-unit `.su` file at all: in an LTO build the only
stack usage it reports comes from GMP, built by its own autotools without LTO.
The lane therefore builds a no-LTO twin per instruction set - upstream's own
`-Dmem=true` for the firmware, `-fno-lto` last in `c_args` for the simulator,
which `src/c47-gtk/meson.build` needs because it pins `b_lto=true` per target -
and calibrates there. The reported numbers still come from the shipped flags.

Two extraction details the calibration pinned down, both platform-specific:

- On x86-64 `gcc -fstack-usage` **includes the 8-byte return address** the
  `call` pushed; on Thumb the return address is in `lr` and costs only when the
  prologue pushes it. The profiler charges the difference so a frame is
  comparable across platforms and matches GCC on both.
- A frame past one page on x86-64 is allocated by a **stack-clash probe loop** -
  `lea -0x7000(%rsp),%r11`, then a loop subtracting one page at a time. The `lea`
  carries the whole allocation; summing the loop body's single `sub` instruction
  reads a 30 KB frame as 4 KB.

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

The profiler keys functions by **address, never by name**: three GMP statics
share a name inside one DM42 ELF, and a name-keyed walk merges their frames and
their callees.

## 9. What is not established

- **Liveness of the DM42 OS globals.** The floor at `0x20017648` is where
  firmware *addresses* data. Whether every byte below it is live while a program
  runs is not provable statically; some may be boot-only. The band is therefore
  a lower bound on the stack, and the honest one to budget against.
- **How much stack C47 actually uses.** Every number here is static. The
  dynamic answer - paint the band at boot, run the corpus and real workloads,
  read the high-water mark back - would also catch the `alloca` component that
  no prologue sum sees. Nothing in this repo does that yet.
- **The three packages that do not link.** Their frames are unmeasured because
  no ELF exists to measure, and package 2 and 3 are the ones carrying the
  stack-heaviest functions. Whether the overflow is upstream's or this
  toolchain's is not established.
- **The macOS and Windows simulators.** Their compile-time limits are in the
  matrix, which is a preprocessor answer and needs no host. Their frames and
  their thread stack limits are not measured; the lane profiles the host it runs
  on, and CI runs Linux.
- **Interrupt and DMCP reserve.** Neither is measured, and both come out of the
  same band.
- **Whether the numbers hold on silicon.** They are read from images and ELFs.
  No reading on this page has been confirmed against a running DM42.
