# Memory Architecture

Where C47's memory physically lives on **each supported platform**, what bounds
each region, where the platforms disagree, and how to measure any of it. Read it
before changing anything that allocates, recurses, or sizes a buffer.

[01-codebase.md](01-codebase.md) Section 6 owns the **C47 pool**: block numbers,
the free list, program memory growing downward. This page is the machine under
that pool - the SRAM it is carved out of, the stack a program runs on, and the
firmware or host that hands out both. On the DM42 those last two are the same
memory, which is the fact the page is built around.

Audit basis: upstream `5e628d1e0f8552360c56c12f44fb14b8fe2d0f37`, 2026-07-26.

## 1. Four arenas, and on the DM42 two of them are one

C47 draws on four pools of memory. They fail differently, the one with no
detector at all is the one this page is mostly about, and **on the DM42 the C
stack is not independent of the heap** - the scheduler allocates it there.

| arena | who bounds it | what C47 puts there | what exhaustion looks like | what detects it |
|---|---|---|---|---|
| **C stack** | the scheduler on DMCP (a task stack out of the firmware heap), or the host thread - at a size DMCP does not document | every call frame; the numeric kernels' multi-kilobyte local buffers | silent corruption of whatever lies below, then a hard fault | **nothing** - no guard page, no software check, and Cortex-M4 has no `MSPLIM` |
| **firmware heap** | the DMCP allocator's arena, or the host `malloc` | one `malloc` for the pool (`config.c`), plus GMP's every long integer | `malloc` returns NULL; GMP aborts | `sys_free_mem()`; the pool's own accounting sees only itself |
| **C47 pool** | `RAM_SIZE_IN_BLOCKS`, inside that one `malloc` | registers, programs, matrices, subroutine levels | on a host, `MAX_ALLOCATED_REGIONS` (`src/c47/c47.h:363`); on firmware that symbol does not exist, so wrong answers with no diagnostic | the leak and testmem lanes; the pool canary |
| **`.data`/`.bss`** | the linker script | the mutable globals that are the calculator's state - [01-codebase.md](01-codebase.md) Section 7 | link failure, so never at run time | the build |

Two consequences a newcomer gets wrong:

- **The pool is not the heap, and pool accounting cannot see the stack.** A
  nested engine evaluation costs 12 bytes of pool for its subroutine level
  (`allocC47Blocks(3)`, `src/c47/programming/lblGtoXeq.c:171`) and about two
  *kilobytes* of C stack for its frames. `getFreeRamMemory()`, the leak lanes and
  `--testmem` measure the first and are blind to the second - which is the one
  that runs out.
- **On the DM42 the stack, the pool and every long integer are one budget.** The
  scheduler's task stack, C47's `malloc` for the pool, and GMP all come out of the
  same firmware arena, so growth in any of them takes room from the others.
  Section 3 does that arithmetic. On the DM42n and on a host they are genuinely
  separate.
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
| stack a program runs on | a scheduler **task stack** out of the 90,104 B arena; **24,568 B** left after the pool, shared with GMP | a task stack inside the **~152 KiB** shared heap-and-stack region below the MSP | the host thread's, 8 MiB by default on Linux |
| MSP band (handlers and boot) | ~2.4 KiB - **not** a program's stack | ~148 KiB, shared with the heap | n/a |
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

## 3. The DM42: three stacks, and only one of them is a program's

The DM42 is an STM32L476 with 96 KiB of SRAM1 at `0x20000000` and 32 KiB of
SRAM2. C47's own linker script (`src/c47-dmcp/stm32_program.ld`) puts `.data`
and `.bss` in SRAM2 and claims **none** of SRAM1: all of it belongs to DMCP.

DMCP states none of this. The numbers below are read out of the shipped image
`DMCP_flash_3.29_DM42-3.26.bin` (sha256 `c81e0dee...b2b29`) by
[`scripts/test/tooling/dmcp-stackband.py`](../scripts/test/tooling/dmcp-stackband.py),
which prints the evidence for each one:

```sh
python3 scripts/test/tooling/dmcp-stackband.py DMCP_flash_3.29_DM42-3.26.bin \
    --sram-size 0x18000 --pool-bytes 65536
```

| region | bounds | size | how it is known |
|---|---|---|---|
| **firmware malloc arena** | `0x20000048`-`0x20016040` | 90,104 B | the allocator's lazy init: an 8-aligned literal base, `add.w #90112`, `sub.w #8`, `bic #7` |
| **DMCP kernel globals** | `0x2001604C`-`0x20017647` | 5,628 B | 71 distinct addresses firmware code loads as fixed data, 418 times; the lowest is `&pxCurrentTCB` |
| **MSP: handler and boot stack** | `0x2001764C`-`0x20017FF0` | 2,468-2,472 B | the remainder, below the initial MSP |
| initial MSP | `0x20017FF0` | - | vector[0] |

**A program does not run on that MSP band.** `vector[11]` (SVCall) and
`vector[14]` (PendSV) are a context switch: they load a task's saved registers
and write **PSP** (`0x0801876A`, `0x08018840`), the shape of FreeRTOS's
`vPortSVCHandler` and `xPortPendSVHandler`. No `msr CONTROL` appears anywhere, so
the switch to the process stack comes from the exception return. Thread mode
therefore runs on a **task stack**, and a task stack is `malloc`'d - out of the
arena in the first row.

So the number that bounds a nested evaluation is not either stack band. It is
what is left of the arena once C47's pool is taken:

```
  usable arena                                       90,104 B
  less the C47 pool (RAM_SIZE_IN_BLOCKS 16384 x 4)  -65,536 B
  left for the task stack, GMP and everything else   24,568 B
```

GMP is in that number, not beside it: `allocGmp` rounds for accounting and then
calls libc `malloc` ([01-codebase.md](01-codebase.md) Section 6), so every long
integer competes with the stack a program is running on.

### How the boundary is known, and how far to trust it

Two neighbouring gaps below the initial MSP both look like "the C stack a program
gets", and neither is. Taking the arena top as the floor skips the kernel globals;
taking the top of kernel data as the floor measures the handler stack. The checks
below are what tell them apart, and the tool prints all of them.

What makes the region above the arena *kernel globals* rather than spare stack is
reference density:

| region | span | distinct addresses | references | per KiB |
|---|---|---|---|---|
| SRAM2 (DMCP `.data`/`.bss` + SDB) | 32 KiB | 639 | 5,723 | 178.8 |
| malloc arena | 88 KiB | 6 | 8 | **0.09** |
| SRAM1 above the arena | 8 KiB | 71 | 418 | **52.7** |

A 580x density step at the arena top is not decode noise, and the identity of the
lowest address in the cluster settles it: `0x2001604C` holds the pointer the
context switch dereferences on every switch - `pxCurrentTCB`. The region is the
scheduler's own state.

The floor is confirmed by a second, independent signal: the boot fill loop at
`0x0802CEC0` stops at `0x20017648`, one word past the highest addressed datum. A
loop clearing SRAM must stop below the stack it is running on, so the two agree.

They agree to **one word, not to the byte**, and that limit is irreducible from an
image: a literal pool holds bare words, so nothing in it distinguishes the address
of the last variable from a pointer value the code happens to store. On the DM42n
the highest such word is the initial heap break, not a variable at all. The tool
reports the conservative end of the range and says which it is.

Upstream carries the matching fact for SRAM2: the DMCP **system data block** is
at a fixed `0x10002000`, and `src/c47-dmcp/stm32_program.ld` now fails the link if
C47's `.bss` reaches it (upstream `2e6493156`, 660 bytes of headroom).

## 4. The DM42n: the same shape, far more room

`DMCP5_flash_3.55.bin` (sha256 `f6aa86be...c53ce`), same tool, no `--sram-size`
override:

- initial MSP `0x20040000`, the top of a contiguous 256 KiB SRAM
- DMCP5 addresses no fixed data above `0x2001ACB8`, which is also where the
  newlib break starts; `_sbrk` is clamped at `0x2003FC00`, one kilobyte below
  the MSP
- so ~152,390 B sit between the top of firmware state and the MSP (152,388 or
  152,392, one word either way as Section 3 explains)

**The same caveat as Section 3 applies:** DMCP5's SVCall/PendSV also write PSP, so
that 152,392 B is the MSP band, and a program still runs on a task stack. The
difference is that on this target the region is shared between a heap growing up
from the break and the stack coming down from the MSP, with 148 KiB of it free -
so the task stack has room the DM42 does not have, and the tool cannot locate a
separate arena here at all (DMCP5 has no `b.w` veneer table at
`LIBRARY_FN_BASE`, which is itself the evidence that its allocator is a different
one).

C47's 256 KiB pool on this target comes from a separate pool allocator whose
control block is in firmware `.bss`, so pool pressure does not squeeze the stack.
Every alarming conclusion on this page is an **old-hardware** conclusion.

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
part that does not move: **on the DM42 a nested SOLVE level and the trig payload
inside it are spending the same 24,568 bytes that GMP's long integers and every
other allocation come out of** - the arena left after the pool, and the only
memory a program's task stack can grow into. On the DM42n the same level fits
sixty times over in a region nothing else competes for.

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
  precision and pays a frame of several kilobytes for it. On a target whose task
  stack shares 24 KiB with the pool's leftovers and every long integer, that trade
  is not optional - and because `HARDWARE_MODEL` is undefined on host builds, the
  simulator pays the large frame, so it cannot show you the small one working.
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

- **The size of the task stack a program actually gets.** This is now the
  load-bearing unknown, and an image cannot answer it: the scheduler passes a
  stack depth at task creation and the stack is `malloc`'d, so only a running
  machine knows. 24,568 B is the ceiling on it, not its size. Everything in
  Section 5 is a per-level cost against a budget whose exact size is unmeasured.
- **Which task, and whether one program runs on more than one.** The context
  switch is identified; the task layout is not.
- **How much stack C47 actually uses.** Every number here is static. The dynamic
  answer would also catch the `alloca` component no prologue sum sees, and it is
  cheaper than it looks: the firmware already paints new task stacks with `0xA5`
  (four `#165` immediates in the image), so a high-water mark can be read back
  without painting anything first. Nothing in this repo does that yet.
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
