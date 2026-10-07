# Memory Architecture

Audit basis: upstream `7f030deba57dd9df0e01bdf6ff395898131868dd`, 2026-10-07.

Where C47's memory physically lives on **each supported platform**, what bounds
each region, where the platforms disagree, and how to measure any of it. Read it
before changing anything that allocates, recurses, or sizes a buffer.

[01-codebase.md](01-codebase.md) Section 6 owns the **C47 pool**: block numbers,
the free list, program memory growing downward. This page is the machine under
that pool - the SRAM it is carved out of, the stack a program runs on, and the
firmware or host that hands out both. Whether on the DM42 those last two are the
same memory is the question the page is built around.

## 1. Four arenas, and on the DM42 two of them may be one

C47 draws on four pools of memory. They fail differently, the one with no
detector at all is the one this page is mostly about, and on this repo's reading
of the DM42 image **the C stack is not independent of the heap** - the scheduler
allocates it there. Section 3 gives upstream's other reading.

| arena | who bounds it | what C47 puts there | what exhaustion looks like | what detects it |
|---|---|---|---|---|
| **C stack** | the scheduler on DMCP (a task stack out of the firmware heap), or the host thread - at a size DMCP does not document | every call frame; the numeric kernels' multi-kilobyte local buffers | silent corruption of whatever lies below, then a hard fault | **nothing** - no guard page, no software check, and Cortex-M4 has no `MSPLIM` |
| **firmware heap** | the DMCP allocator's arena, or the host `malloc` | one `malloc` for the pool (`config.c`), plus GMP's every long integer | `malloc` returns NULL; GMP aborts | `sys_free_mem()`; the pool's own accounting sees only itself |
| **C47 pool** | `RAM_SIZE_IN_BLOCKS`, inside that one `malloc` | registers, programs, matrices, subroutine levels | on a host, `MAX_ALLOCATED_REGIONS` (`src/c47/c47.h:363`); on firmware that symbol does not exist, so wrong answers with no diagnostic | the leak and testmem lanes; the pool canary |
| **`.data`/`.bss`** | the linker script | the mutable globals that are the calculator's state - [01-codebase.md](01-codebase.md) Section 7 | link failure, so never at run time | the build |

Two consequences a newcomer gets wrong:

- **The pool is not the heap, and pool accounting cannot see the stack.** A
  nested engine evaluation costs 12 bytes of pool for its subroutine level
  (`allocC47Blocks(3)`, `src/c47/programming/lblGtoXeq.c:171`) and a kilobyte or
  more of C stack for its frames (`run-stackprof.sh` prints the figure per
  platform). `getFreeRamMemory()`, the leak lanes and
  `--testmem` measure the first and are blind to the second - which is the one
  that runs out.
- **On this repo's reading of the DM42 image, the stack, the pool and every long
  integer are one budget.** The scheduler's task stack, C47's `malloc` for the
  pool, and GMP all come out of the same firmware arena, so growth in any of them
  takes room from the others. Section 3 does that arithmetic and gives upstream's
  other reading. On the DM42n and on a host they are separate.
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
| stack a program runs on | **disputed** (Section 3): this repo reads a scheduler task stack out of the 90,104 B arena, **24,568 B** left after the pool and shared with GMP; upstream's `tools/pgemu` reads the 8,104 B below the initial MSP | a task stack inside the **~152 KiB** shared heap-and-stack region below the MSP | the host thread's, 8 MiB by default on Linux |
| MSP band (handlers and boot) | ~2.4 KiB on this repo's reading | ~148 KiB, shared with the heap | n/a |
| optimisation | `-Os`, no LTO | `-Os`, no LTO | `-O0` for `make simc47`, `b_lto=true` pinned per target |

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
  6147- and 12321-digit side of the modulo split in Section 6.
- **`MAX_ALLOCATED_REGIONS` exists only on host builds**, so the pool's
  allocation tracking, and the size-mismatch detector built on it, are host-only.
  A wrong `freeC47Blocks` size corrupts the free list silently on hardware.

### The DM42 ships as four feature packages

`DMCP_PACKAGE` selects which functions are compiled in, so the DM42 has one
memory model but four different sets of built code - and therefore four different
largest-frame lists and worst-case paths. Each package's `#if` block in `src/c47/defines.h` opens with a
comment naming what it carries - `:193`, `:209`, `:225` and `:246`; the free-byte
figures in those comments are upstream's notes, not a measurement of the tree
they sit in. Package 3 is the only one with `EIGEN`, package 2 the only one with
the full `X.FN` menu (1 and 3 strip it), and package 4 is the minimal build the
Makefile defaults to and upstream's pipeline compiles.

**Which packages link moves with the tree and the compiler.** The limit is the
704 KiB internal `FLASH` region (`src/c47-dmcp/stm32_program.ld`). With Arm's
14.2.Rel1 binary standing in for the `arm-none-eabi-gcc` 14.2.1 that upstream's
`ubuntu:25.10` CI installs, wiped build directories and ccache off, upstream
`7f030deba` overflows packages 1, 2 and 3 by 1,536, 512 and 1,232 bytes and
links package 4 with 27,472 bytes left; the same binary linked all four at
`ad322d6a3`, with 3,424 bytes left in package 1. Ubuntu 24.04's 13.2.1, which
this repo's stackprof lane installs, overflowed 1, 2 and 3 at `ad322d6a3`
already. The margins move with every upstream commit, and two readings of one
package at one commit have differed by 16 bytes, so read them from a build
rather than from here. The lane profiles every package that links and reports
the rest as `DOES NOT BUILD at this commit`. **Package 3 matters most** - it is
the only build carrying eigenvalues, on the target with the least stack.

## 3. The DM42: three stacks, and which one is a program's is disputed

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

On that reading the number that bounds a nested evaluation is not either stack
band. It is what is left of the arena once C47's pool is taken:

```
  usable arena                                       90,104 B
  less the C47 pool (RAM_SIZE_IN_BLOCKS 16384 x 4)  -65,536 B
  left for the task stack, GMP and everything else   24,568 B
```

GMP is in that number, not beside it: `allocGmp` rounds for accounting and then
calls libc `malloc` ([01-codebase.md](01-codebase.md) Section 6), so every long
integer competes with the stack a program is running on.

**Upstream reads the same image differently.** `tools/pgemu/MEASUREMENTS.md` and
`tools/pgemu/target.py` take the vector table's initial MSP, `0x20017FF0`, as the
top of the program's stack and the arena end below it as the floor: **8,104 B**,
with heap_4's variables first in line for an overrun. That span is this page's
kernel globals plus its MSP band, and pgemu runs C47 without DMCP's scheduler,
so it does not exercise the PSP switch above. The two readings disagree on which
region a program's stack is, and neither has been checked on a running DM42 by
reading the stack pointer. Upstream's hardware runs bound the answer from the
outside: the `PLOT_NESTING_ALLOWED` comment in `src/c47/defines.h` records INT
inside INT (7,684 B) surviving on the DM42 and a plot with an integral inside it
(12,020 B on the DM42n) hanging, which upstream reads as the overrun. Name the
reading beside any DM42 stack figure.

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
at a fixed `0x10002000`, and `src/c47-dmcp/stm32_program.ld:187` fails the link
if C47's `.bss` reaches it. The headroom moves with every global; read `_ebss`
from the build's `C47.map`.

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
`PLOT(SOLVE)` are supported where the cap below allows them, on the DM42n and
the simulator; the DM42's cap of 1 refuses both - so the frames of one nested
evaluation multiply by the nesting depth. Upstream bounds that count with
`engineNestingDepth` (`src/c47/c47.h`), which covers **PLOT, INT and SOLVE
combined** and is capped by `MAX_ENGINE_NESTING_DEPTH` in `src/c47/defines.h`:
**1** on the DM42 (`OLD_HW`), **3** on the DM42n (`NEW_HW`), **4** on the
simulator. PLOT runs only as the outermost engine. Past the cap the program
stops with `ERROR_NESTING_TOO_DEEP` rather than overflowing the C stack.

**A second macro gates the plot case.** `PLOT_NESTING_ALLOWED` (`defines.h`) is
**0** on the DM42 and 1 everywhere else, and `engineNestingRefused`
(`solver/solve.c:43`) tests it beside the count: where it is 0, nothing runs
inside a plot at all, whatever the depth. On the DM42 the cap of 1 already
refuses every engine inside another, a plot included, so there the macro binds
only if the cap rises. The comment above the cap calls it "one level each way",
and the comment beside each macro carries the hardware measurement it is set
from; Section 8.1 is where those runs live. Quote the comments, not this page: a
retuned macro takes its own justification with it.

The counter is taken at each engine's own entry - `solver/integrate.c`,
`solver/solve.c`, `solver/graph.c` - and reset in `config.c`, not at a single
`execProgram` choke point. Sum/product and the differentiator are outside it.
Re-measure `run-nestcheck.sh` against this cap before quoting a crash from it.

The per-level chains and their measured cost live in
[`scripts/test/stackprof-baseline.txt`](../scripts/test/stackprof-baseline.txt),
which the stack lane re-measures on every run and gates on when
`STACKPROF_GATE=1`. Read the numbers there, not here; the lane also prints how
many levels fit each platform's band. On this repo's reading of the image,
**on the DM42 a nested SOLVE level and the trig payload inside it spend the same
24,568 bytes that GMP's long integers and every other allocation come out of** -
the arena left after the pool. On the DM42n the same level has a region nothing
else competes for.

**The simulator does not even have the same call chain.** The firmware is
compiled at `-Os` without LTO (`src/c47-dmcp/meson.build` says so), the
`make simc47` simulator at `-O0`: at `-Os` GCC inlines `executeOneStep` into
`runProgram` and splits `_fnIntegrate` into a `.part.0` clone, neither of which
happens at `-O0`. The baseline therefore carries separate `sim` chains, and the
simulator's per-level cost is the *largest* of the three platforms while its
stack is the largest by three orders of magnitude. It is the one platform on
which this class of bug cannot be observed.

## 6. Where the large frames are

`run-stackprof.sh` prints the largest fixed frames per platform on every run. Two
of them are design decisions worth knowing before you touch them:

- **The modulo pair takes its buffer from the heap, at a precision that splits
  by hardware.** `WP34S_Mod` and `WP34S_BigMod`
  (`src/c47/mathematics/wp34s.c:2145`, `:2171`) each carry a
  `HARDWARE_MODEL == HWM_DM42` branch. On the DM42 both reduce at 2139 digits in
  a 1436-byte `REAL_T_ALLOC` buffer; every other build allocates 12321 digits
  (8224 bytes) the same way and reduces at 6147 (`WP34S_Mod`) or 12321
  (`WP34S_BigMod`). Both raise `ERROR_RAM_FULL` when the allocation fails.
  Because `HARDWARE_MODEL` is undefined on host builds, the simulator runs the
  wide side and cannot show the DM42's 2139-digit reduction. The pool-allocating
  `_Pauli` variants (`:2095`-`:2136`) sit inside `#if 0`, so the -NaN defect
  upstream records above them belongs to code no build compiles.
- **The angle-reduction buffers are heap, at the largest size that did not
  crash.** `src/c47/registerValueConversions.c:1404-1405` takes both 2139-digit
  buffers with `REAL_T_ALLOC`, a self-freeing `malloc` (`src/c47/realType.h:28`),
  and raises `ERROR_RAM_FULL` if either fails. Upstream's comment at `:1403`
  measures the trade: 1436 bytes each, 2872 of a 2936-byte frame, and "from the
  heap the frame falls to 64 bytes". The 2139 ceiling is found, not derived -
  `:1404` and `:1413` both say 6147 overruns the stack. **On the DM42 the relief
  depends on which stack reading holds (Section 3):** on this repo's, `malloc`
  comes out of the same 90,104 B arena the task stack grows into, so the cost
  sits inside one budget. On the DM42n and the host it leaves the stack.

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
firmware ELF and a simulator binary. [07-ci.md](07-ci.md) has the lane contract;
[scripts/test/README.md](../scripts/test/README.md) has what each script does.

**The profiler is calibrated against the compiler on every run, once per
instruction set.** It compares every unambiguous static frame it extracts against
`gcc -fstack-usage`. An **under**-report fails the lane whatever
`STACKPROF_GATE` says: a bound below the real frame is a bound that permits the
overflow it was meant to prevent. An over-report is the documented cost of
summing every allocation a function makes instead of tracing which can co-occur,
and is printed with its total so it cannot grow unnoticed.

**Calibration needs its own build.** It needs `gcc -fstack-usage`, which no
shipped build passes, so the lane builds a twin per instruction set and
calibrates there. The firmware is compiled without LTO, so its twin differs from
the shipped build by that flag alone. The simulator pins `b_lto=true` per target
in `src/c47-gtk/meson.build`, and an LTO build writes no per-translation-unit
`.su` file, so its twin puts `-fno-lto` last in `c_args`. The reported numbers
come from the shipped flags.

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

### 8.1 Upstream measures the same thing dynamically, on the calculator

Everything above is static: frames read out of a disassembly, summed along a
chain. Upstream carries the other half - `tools/hwtest/stack-watermark` paints a
marker over a stretch of the running stack, runs a case, and searches for the
lowest place the marker is gone. That catches what a prologue sum cannot see,
`alloca` and GMP's temporaries included, and it runs on the hardware rather than
on a model of it. Its `README.txt` is the authority; what follows is what a
reader of this page needs before trusting a figure of either kind.

- It is **off by default** - `#define STACK_WATERMARK` in `defines.h` - and with
  it on, every keystroke outside a running program repaints and re-searches the
  whole stretch, so the calculator feels slow.
- **A testSuite build switches it off again by itself**, under
  `TESTSUITE_BUILD`, because the tool creates named variables and writes them at
  every dispatch and would move the register state the corpus compares against.
  The corpus therefore cannot be measured with it.
- It exposes long-integer variables: `STCKHI` the figure, `STCKHWM` the deepest
  since cleared, `STCKGO` to paint (1) or read (2), `STCKSPN` how far down to
  paint, `STCKSPU` how far was painted, and **`STCKST`, which says whether the
  figure means anything**. Only `STCKST 0` is a measurement; 1 means the marker
  ran out below, 2 that nothing was disturbed, 3 that no fresh marker was laid.
  A number comes out in all four cases, and a column of them reads as a result
  when it is the tool failing to measure. Read `STCKST` on every line.
- Painting deeper than the memory that is yours does not fail at the time: the
  calculator hard faults on the **next reset** and needs reflashing.

**Where the figures are, and what they say.** The captured runs live in
`tools/hwtest/stack-watermark/results/` - eight PLOT, INT and SOLVE combinations
ordered shallowest first, one column per machine. Read them there rather than
from a copy here; the two facts on this page's subject are the ones that hold
whatever the figures move to:

- **The captured runs come from a DM42 firmware whose cap was 2:** it completed
  `INT` nesting `INT` and hung on an engine inside a plot. The results are dated
  2026-07-27; `MAX_ENGINE_NESTING_DEPTH` is 1 on `OLD_HW`, so the current
  firmware refuses that plot case with `ERROR_NESTING_TOO_DEEP`, and the
  `README.txt` beside the results describes the cap of 2. The DM42n
  completes all eight.
- **Nothing there bounds the DM42's grant.** The runs report what a case used,
  never what was available, and the DM42 never reached a case that would have
  told you.

Because the cases are ordered shallowest first and each output line is opened,
written and closed, **where the file stops is itself a result**: a run that
takes the machine down keeps every measurement it had already taken.

Read these depths against the firmware's `main`, not against the arena
arithmetic in Section 3: the two anchor differently and are not the same
quantity. The simulator anchors wherever its first measurement lands, so its
column carries an unknown constant and compares only with itself.

## 9. What is not established

- **The size of the stack a program actually gets.** This is the load-bearing
  unknown, and an image cannot answer it. On this repo's reading the scheduler
  passes a stack depth at task creation and the stack is `malloc`'d, so 24,568 B
  is the ceiling on it, not its size; on upstream's it is the 8,104 B below the
  MSP (Section 3). Only a running machine settles it. Everything in
  Section 5 is a per-level cost against a budget whose exact size is unmeasured.
- **Which task, and whether one program runs on more than one.** The context
  switch is identified; the task layout is not.
- **How much stack C47 actually uses, from a lane.** Every number this repo
  produces is static. Upstream answers the dynamic half on hardware with
  `tools/hwtest/stack-watermark` (Section 8.1), which catches the `alloca`
  component no prologue sum sees - but it is a manual run on a calculator with a
  purpose-built firmware, not something a lane can call, and it cannot be run
  against the corpus at all. Nothing in this repo reads a high-water mark yet,
  and it is cheaper than it looks on the host: the firmware already paints new
  task stacks with `0xA5` (four `#165` immediates in the image), so the mark can
  be read back without painting anything first.
- **The frames of packages 1, 2 and 3.** At upstream `7f030deba` none of them
  links with either compiler Section 2 measures, so there is no ELF to profile;
  packages 2 and 3 carry the stack-heaviest functions.
- **The macOS and Windows simulators.** Their compile-time limits are in the
  matrix, which is a preprocessor answer and needs no host. Their frames and
  their thread stack limits are not measured; the lane profiles the host it runs
  on, and CI runs Linux.
- **Interrupt and DMCP reserve.** Neither is measured, and both come out of the
  same band.
- **Whether the numbers hold on silicon.** They are read from images and ELFs.
  No reading on this page has been confirmed against a running DM42.
