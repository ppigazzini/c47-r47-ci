# C47 Architecture

A measured architecture analysis of the upstream C47 calculator application:
what shape the code is in, why, and what that costs anyone changing it.

Read this before proposing any structural change. Read
[01-codebase.md](01-codebase.md) instead if you only need to find your way around
the tree.

Subject: `https://gitlab.com/rpncalculators/c43.git` (the repository keeps the
older `c43` name; the application it builds is C47). Commit analysed:
`33328e4cc25588eb7504f38f4076f8feae3ae766`. Every figure is measured from git
objects at that commit or from the `build.sim/` object tree; the method for each
is stated with it, and every load-bearing claim is indexed in Annex C. Line
counts are blob lines, not SLOC: an upper bound, used for relative scale only.

## Read this before quoting a number

**Sections 1 to 8 and Annex A are measured fact.** Sections 9, 10 and 11 are
**assessment and an unadopted proposal** - see the warning before Section 9.

**The structural conclusions hold; the fine-grained counts drift with upstream.**
Measured at `33328e4cc`:

| figure | value |
|---|---|
| `c47.h` lines / `#include`s | 639 / 134 |
| `.c` files including `c47.h` | 228 of 229 |
| `LAST_ITEM` | 2870 |
| `extern` declarations in `c47.h` | 345 |
| `DMCP_BUILD` uses / files | 414 / 45 |
| `EXTRA_INFO_ON_CALC_ERROR` uses / files | 1800 / 172 |
| headers in `src/c47` | 243 |
| `PC_BUILD` uses | 800 |
| `#if`/`#ifdef`/`#ifndef`/`#elif` | 2781 |
| `src` `.c`/`.h` files / lines | 525 / 179885 |
| DMCP / DMCP5 hal adapters | 4 each |
| commits | 13804 |

The conclusions do not move - one god header, one large single cycle, a
preprocessor-based portability layer - but **re-measure before quoting any
specific count**; that is what the counts are for. Annex A gives the method for
each. The quick ones:

```bash
cd <c43-clone>
grep -c '^\s*#include' src/c47/c47.h
grep -rl '#include "c47.h"' src/c47 --include=*.c | wc -l
grep -rho '\bPC_BUILD\b' src/c47 --include=*.c --include=*.h | wc -l
```

The `nm` link-graph metrics in Section 8 and Annex A (edge count, the SCC size,
CCD/ACD/NCCD, the degree tables) are measured from a full object build and are
**not re-derived at `33328e4cc`**; re-run the Annex A method against a fresh
build before quoting them.

This document describes the upstream product. It is not a plan of record for it.

## 1. The product

A high-precision RPN scientific calculator descended from WP43, targeting the
SwissMicros DM42 family. One library, several targets.

Repository: 13804 commits since 2018-12-23, 35 contributors, of whom the top five
account for 11636 -- a small-core project with a long tail.

| target | what it is |
|---|---|
| `c47`, `r47` | GTK 3 desktop simulator (two keyboard layouts) |
| `C47.elf`, `C47_pre.elf`, `R47.elf`, `R47_pre.elf` | DM42 (DMCP) firmware |
| `generateConstants`, `generateCatalogs`, `generateTestPgms`, `ttf2RasterFonts`, `forcecrc32` | build-time generators |

Plus two harnesses: `src/testSuite` (the behavioural corpus runner) and `src/t47`
(a Jim/Tcl scripting DSL).

meson is the build; the 54-target `Makefile` wraps `meson setup` / `ninja`. 15
`meson.build` files. Dependencies are explicit: `dep/decNumberICU` vendored,
`dep/jimtcl` + `dep/DMCP_SDK` + `dep/DMCP5_SDK` as submodules, GMP via
`subprojects/gmp-6.2.1.wrap`, GTK 3 and FreeType from the system.

## 2. Repository map

```
  893 src        190 res        63 docs       38 dep
   15 PROGRAMS     6 tools        3 subprojects
```

`src` .c/.h only: 525 files / 179885 lines.

```
  area                             files    lines
  src/c47/(root)                      81    71003   <- 46% of the library
  src/c47/mathematics                257    44230
  src/c47/solver                      18    10180
  src/c47/c47Extensions               19     9813
  src/c47-gtk                         10     8241
  src/c47/programming                 15     5877
  src/testSuite                        7     5094
  src/generateTestPgms                 1     4245
  src/c47/distributions               33     4237
  src/t47                             14     3902
  src/c47/ui                           6     3544
  src/c47/printing                     4     3409
  src/c47/browsers                     9     1083
  src/c47/logicalOps                  23     1072
  src/generateConstants                1      960
  src/c47-dmcp5                        8      715
  src/c47-dmcp                         8      689
  src/ttf2RasterFonts                  2      536
  src/c47/hal                          5      497
  src/c47/core                         2      393
  src/generateCatalogs                 1      134
  src/generated                        1       31
```

The library `src/c47` is 472 files / 155338 lines, of which 229 are `.c`.

368 of the 893 `src` files are not `.c`/`.h`: 325 `.txt` (mostly the corpus), 14
`.xlsx`, 11 `meson.build`, 4 `.py`, and assorted `.rc`/`.md`/`.ld`/`.in`.

Three directory names do not describe their contents:

- **`core/` is 393 lines**: `freeList.c` (327) + `freeList.h` (66). An allocator,
  not a core.
- **`ui/` is 6 files**: `matrixEditor.c` (1917), `tam.c` (1400), `tone.c` (38) and
  headers. The user interface -- `screen.c` (6623), `display.c` (4012),
  `keyboard.c` (4987), `softmenus.c` (4428), `statusBar.c` (1098) -- is in the
  root.
- **`hal/` is 5 headers and zero `.c`**. That one is deliberate (s5).

`mathematics/`, `solver/`, `distributions/`, `logicalOps/`, `programming/`,
`browsers/` and `printing/` are cohesive. The remaining 46% of the library lives
in an 81-file flat root with no subdirectory for display, input, persistence or
state, though each exists as a concept and each has several files.

```
  6623 screen.c        2538 defines.h       1279 charString.c
  4987 keyboard.c      2416 registers.c     1258 conversionUnits.c
  4734 items.c         2228 config.c        1258 c47.c
  4428 softmenus.c     2147 plotstat.c      1224 dateTime.c
  4012 display.c       1570 registerValueConversions.c
  3048 items.h         1484 saveRestoreBackup.c
  2789 bufferize.c     1483 stringFuncs.c
  2793 saveRestoreCalcState.c              1346 curveFitting.c
```

`src/index spreadsheet/` (16 files, a space in the directory name) holds the
design source of truth for keyboard layouts, CONFIG defaults, unit conversions and
item indices as binary `.xlsx`. Two of the filenames carry their own staleness
warning: `items4_108.13.04 (way out of date).xlsx`, `HOME Menu_(doubtful to be
accurate but keep it).xlsx`.

A spreadsheet is also a build input, but not one of these: CI clones and builds
`xlsxio` from source to convert `res/fonts/sortingOrder.xlsx` to CSV
(`.gitlab-ci.yml:38-39`). The files under `src/index spreadsheet/` are design
source consumed by hand, which is why `items.c:1777` records that the item table
was "generated (manually)".

## 2.1 The logical components

The directories do not name the components, so this table does. Levels are what
the dependency evidence supports, not a plan: a component calls downward freely,
and every upward call is one of the violations catalogued in Section 8.3.

| L | component | owns | entry point |
|---|---|---|---|
| 0 | platform | nothing; five headers | `hal/io.h`, `hal/lcd.h` |
| 1 | block allocator | `ram`, `freeMemoryRegions[]` | `memory.c:76` `allocC47Blocks` |
| 2 | primitives | glyphs, string and real helpers | `charString.c`, `realType.c`, `fonts.c`, `sort.c` |
| 3 | error signalling | `lastErrorCode`, `errorMessageRegisterLine` | `error.c:261` `displayCalcErrorMessage` |
| 4 | register and variable store | `globalRegister[]`, `allNamedVariables` | `registers.c:212` `getRegisterDataPointer` |
| 4 | stack and undo | undo snapshot, lift semantics | `stack.c:20` `liftStack` |
| 5 | types and conversions | `shortIntegerMask`, `denMax` | `registerValueConversions.c` |
| 6 | mathematics | the four type-dispatch tables | `mathematics/addition.c:10` |
| 7 | derived numerics | statistical sums, unit tables | `stats.c`, `conversionUnits.c` |
| 8 | program store | program memory, `labelList`, `programList` | `programming/manage.c:102` |
| 9 | value formatting | `displayFormat*`, grouping | `display.c:228` `real34ToDisplayString` |
| 10 | screen rendering | `lcd_buffer`, cursor, status bar | `screen.c:5993` `refreshScreen` |
| 11 | dispatch and input | `indexOfItems[]`, `calcMode`, `tam` | `items.c:237` `reallyRunFunction` |
| 11 | program execution | subroutine frames, local flags | `lblGtoXeq.c:750` `executeOneStep` |
| 11 | solvers and equations | `currentSolver*`, `allFormulae` | `solver/solve.c:439` |
| 12 | application | file formats, config | `saveRestoreBackup.c:242` `saveCalc` |

Levels 9 to 11 are one block in practice, not three. `display.c` and `screen.c`
are mutually recursive (`display.c:3511` against `screen.c:2551`), as are
`screen.c` and `softmenus.c`, and `screen.c` and `items.c`. They are listed
apart because that is the shape a split would take, not because the split exists.

**Three components are fused in the source, and each fusion is a finding.**

- **Number entry and alpha entry are one component.** They share a buffer, and
  `c47.c:122` says so: `char *aimBuffer; // aimBuffer is also used for NIM`.
  `addItemToBuffer` routes AIM, TAM, NIM and MIM from one if/else chain
  (`bufferize.c:445`).
- **The matrix type and the matrix editor are one component.**
  `mathematics/matrix.h:234-236` declares `showMatrixEditor`, `mimEnter` and
  `mimAddNumber`, all implemented in `ui/matrixEditor.c`. A maths header exports
  a user interface.
- **Statistics and plotting have no seam.** `plotstat.c` reads the statistics
  matrix, computes screen coordinates and draws the regression line in the same
  file.

**Why the components have to be inferred rather than read off.** `src/c47/c47.c`
defines exactly **one** function; everything else in it is global variable
definitions for every component in the system, declared through the 345 `extern`s
in `c47.h`. There is almost no file-private state anywhere, so a component owns
its globals by convention only - nothing enforces it. That is the root cause of
the coupling this page measures, and it is why "which module owns this variable"
is a question the compiler cannot answer.

## 3. The god header and the global state

- `src/c47/c47.h`: **639 lines, 134 `#include` directives.**
- **Every compiled library file includes it**: 228 of the 229 `.c` under
  `src/c47`; the one that does not, `reservedRegisterLookupGenerator.c`, is not in
  `src/c47/meson.build`. The real figure is 228 of 228.
- For most of those files it is the only project header they include:

```
  228 c47.h        1 version.h        1 softmenuCatalogs.h        1 reservedRegisterLookup.h
```

- `c47.h` declares **345 `extern` symbols, of which 314 are mutable globals**;
  the other 31 are `* const` (the function-pointer tables `addition`,
  `subtraction`, `multiplication`, `division`, ...), not counted as mutable.

The library has exactly one module boundary and it encloses the whole library.
Every translation unit sees every declaration. Consequences:

1. **No encapsulation exists to violate.** Any function in any file may read or
   write any of the 314 globals. Who mutates `calcMode`, `lastFunc` or
   `systemFlags` is answerable only by repository-wide grep.
2. **Every header edit rebuilds the library.** `defines.h` takes 396 commits a
   year (s7); each invalidates all 228 TUs.
3. **Unit-test isolation is impossible by construction.** A leaf function's header
   drags in `c47.h`, which links the world. The end-to-end test strategy (s7) is a
   rational response to this, not an oversight.
4. **No layering is compiler-checkable.** `mathematics/` may call `screen.c` and
   nothing stops it. It does (s8.3).

`c47.h` is not a public API header. It is a bundle: 134 includes so nobody has to
decide which one they need. That is a real ergonomic benefit purchased with the
entire dependency structure of the project.

## 4. Dispatch: the item table

`item_t` (`typeDefinitions.h:603-615`):

```c
  typedef struct {
    void     (*func)(uint16_t);  ///< Function called to execute the item
    uint16_t param;
    char     itemCatalogName [16];
    char     itemSoftmenuName[16];
    uint16_t tamMinMax;
    uint16_t status;             ///< Catalog, stack lift status and undo status
  } item_t;
```

`indexOfItems[]` (`items.c:1775-4734`) is indexed by item number. `LAST_ITEM` is
2870 (`items.h:2989`), so the table has **2871 slots**. 2587 rows are
brace-initialised at source level; 2870 carry a `/* N */` index comment.

Every command is a row: a function pointer, a parameter, catalogue and menu names,
a TAM argument range, status bits. Keys, menus, catalogues, programs and the
corpus all address commands by item number.

**This is a good architecture.** One table is the single source of truth for the
command set; adding a command is a row plus a function; `softmenus.c` never names
a maths function, it names item numbers.

Three costs follow:

- It is why `items.c` (535 commits/yr) and `items.h` (247) are the two hottest
  files and `defines.h` (396) is third: item numbers are `#define`s, so every new
  command touches all three. Merge contention there is structural.
- `item_t` carries four concerns: execution (`func`, `param`), presentation (two
  16-byte names), input validation (`tamMinMax`) and semantics (`status` packs
  catalogue + stack-lift + undo). The cleaner shape survives as a comment above it
  (`//uint16_t tamMin; //uint8_t stackLiftStatus; ...`); the fields are packed to
  save DM42 flash. The packing is undocumented at the type and spread across
  `CAT_*`, `SLS_*`, `US_*`, `EIM_*`, `PTP_*`, `HG_*` in `defines.h`.
- **`func` is a function pointer, so linking the table links the calculator.** This
  is the dominant structural fact of the codebase (s8).

### 4.1 The 887 stubs

`items.c` is 4734 lines:

```
  2960  the table literal    (62%)
   893  generator stubs      (19%)
   881  actual code          (19%)
```

`items.c:778-1670`:

```c
  #if defined(GENERATE_CATALOGS) || defined(GENERATE_TESTPGMS)
      void fnAsnViewer  (uint16_t unusedButMandatoryParameter) {}
      void fnLnBeta     (uint16_t unusedButMandatoryParameter) {}
      ... x887
  #endif
```

`src/generateCatalogs/meson.build:4` passes `-DGENERATE_CATALOGS`.

The generators need only the table's DATA -- names, params, status -- to emit
catalogues. Because `item_t` holds a function pointer, linking the data drags in
every command implementation, which drags in the calculator. With no component
boundary there is no way to link the table alone, so every command is defined as
an empty stub. **893 dead lines, 19% of the hottest file in the repository, exist
to satisfy a linker.**

## 5. The HAL

`src/c47/hal/` is 5 headers and no implementation:

```
  audio.h 68   gui.h 19   io.h 236   lcd.h 144   print_ir.h 30      (497 lines)
```

Four adapter sets implement them:

```
  src/c47-gtk/hal/    audio.c gui.c io.c lcd.c print_ir.c
  src/testSuite/hal/  audio.c gui.c io.c lcd.c print_ir.c
  src/c47-dmcp/hal/   audio.c console.c io.c print_ir.c
  src/c47-dmcp5/hal/  audio.c console.c io.c print_ir.c
```

The library calls the contract rather than the platform: `saveRestoreCalcState.c`,
`saveRestorePrograms.c` and `saveRestoreBackup.c` call `ioFileOpen`, defined only
in the four adapters.

**This is the best-designed part of the codebase and it is what makes the project
testable.** `src/testSuite` runs the whole calculator with no window, no GTK main
loop and no hardware: its `hal/gui.c` is three empty stubs, its `hal/lcd.c`
renders to a buffer.

Four qualifications:

**5.1 The contract is the DM42 vendor's API.** `hal/lcd.h:29-31`:

```c
  // lcd_fill_rect from dmcp.h
  // lcd_refresh   from dmcp.h
  // LCD_write_line from dmcp.h
```

On DMCP the SDK provides these and no adapter exists (hence 4 files, not 5). On
GTK and testSuite an adapter emulates the DM42. The dependency is inverted from
the textbook shape: rather than the library defining a neutral port each platform
implements, the library uses SwissMicros' API as its port, and every non-DMCP
target pays to emulate it. Porting to a new device means implementing `dmcp.h`.

**5.2 Two of five headers are preprocessor forks, not interfaces.**
`grep -c DMCP_BUILD`: `gui.h` 3, `lcd.h` 2, others 0. `hal/gui.h` compiles the
contract away on DMCP:

```c
  #if defined(DMCP_BUILD) || (SIMULATOR_ON_SCREEN_KEYBOARD == 0)
    #define calcModeNormalGui()
  #else
    void calcModeNormalGui (void);
  #endif
```

An interface whose shape changes per target is a compile-time fork. The adapter
cannot be swapped or mocked without recompiling the library.

**5.3 The HAL leaks glib into the library.** `hal/lcd.h:40` declares
`extern gboolean ui_is_active;`. Twelve library files reference glib/gtk
directly (`git grep -lE 'gboolean|GtkWidget|cairo_t|gtk/gtk\.h' -- src/c47`):

```
  c47.h (#include <gtk/gtk.h> at 4 sites)   screen.c   screen.h
  timer.c   timer.h   programming/input.c   hal/lcd.h
  keyboard.c   keyboard.h   typeDefinitions.h
  c47Extensions/keyboardTweak.c   c47Extensions/keyboardTweak.h
```

The last five carry the types in declarations rather than definitions -
`typeDefinitions.h:811` is `GtkWidget *keyImage[4];`, `keyboard.c:338` declares
`btnFnClicked(GtkWidget*, gpointer)` - which is why a narrower grep reports
seven.

`screen.c:114` defines `gboolean drawScreen(GtkWidget *widget, cairo_t *cr,
gpointer data)`; `screen.c:492` `refreshLcd`; `timer.c:104` `refreshTimer`. These
are GTK callbacks defined **inside the library**, not in `src/c47-gtk/`. The
library is not platform-independent code calling a HAL; it is a
preprocessor-multiplexed superset of all platforms that also has a HAL. The HAL
covers file I/O, audio, printing and LCD primitives. It does not cover the event
loop or the drawing surface, which the library reaches directly.

**5.4 The testSuite is display-less, not GTK-less.** `src/testSuite/meson.build`
links `gtk_dep`; `testSuite.c:29` declares `GtkWidget *screen;`. The harness must
define a GTK object to satisfy the library's own references. This is 5.3 charging
rent: because the library defines GTK callbacks, every target that links the
library links GTK -- including the one whose purpose is not to have a GUI.

## 6. Portability is `#if`, not the HAL

Measured over `src/c47`:

```
  #if / #ifdef / #ifndef / #elif directives        2781      (~1 per 56 lines)
  PC_BUILD                     800 uses in  59 files
  DMCP_BUILD                   414 uses in  45 files
    -> union 67 distinct files; 37 contain BOTH
  EXTRA_INFO_ON_CALC_ERROR    1800 uses in 172 files   (36% of the library)
  TESTSUITE_BUILD               28 uses in   9 files
  SIMULATOR_ON_SCREEN_KEYBOARD  12 uses in   2 files
  HARDWARE_MODEL                 9 uses in   4 files
```

`PC_BUILD` + `DMCP_BUILD` = 1214 conditionals across 67 files, against a 497-line
HAL. That is the real portability layer. The 37 dual-branch files are where a
reader must hold two targets at once.

`EXTRA_INFO_ON_CALC_ERROR` is a different mechanism: it gates verbose error
strings so the DM42 firmware fits in flash. It is a flash-budget switch expressed
as preprocessor noise in 36% of the source files.

Only one branch is compiled at a time, so the other is never type-checked by that
build. CI compiling every target (s7) is the correct mitigation and is
load-bearing.

## 7. Tests, CI and change

**The corpus is data-driven and this is a genuine strength.** `src/testSuite` is
331 files: **322 `.txt`** tests, 6 `.c`, a `.py`, a header, a `meson.build`. Tests
are declarative:

```
  In: FL_SPCRES=0 FL_CPXRES=0 SD=0 RMODE=0 IM=2compl SS=4 WS=64
  Func: fnLnBeta
```

The runner is small; the corpus is data; adding coverage costs a text file and is
readable by domain experts who are not C programmers. For a calculator -- where
the specification is "given this state and this key, produce this value" -- this is
the right shape.

**CI builds every target.** `.gitlab-ci.yml` (170 lines): stages
build/test/upload/release; jobs for macOS, Linux, Windows (msys2), dmcp, dmcp5,
dmcp5r47, `testSuite:` (`make test`) and `codeDocs:`.

**The corpus asserts the screen in one file.** `graphs_cov.txt` renders plots
through `SNAP` and pins a SHA-256 of the resulting bitmap, which covers the
grapher, the fonts and the blitter. There is no other golden-image or LCD-buffer
assertion: the rest of what is reached through `screen.c` / `display.c` /
`statusBar.c` / `softmenus.c` -- 16161 lines, all hot -- is verified by human
inspection alone.

**Churn** (12-month window, existing paths only, five mass-sweep commits excluded:
a 455-file "Header files centralization", a 407-file licence sweep, two "White
space changes" of 157 and 176, a 105-file "import master"):

```
  commits touching src/c47      2421   (5 sweeps)
  file-touches, sweeps excluded  6763
  cold (0 non-sweep commits)  111 of 472 = 23%
    hottest  5% of files (23) = 57% of churn
    hottest  8% of files (37) = 67% of churn
    hottest 20% of files (94) = 85% of churn

  535 items.c        224 keyboard.c              157 config.c
  410 softmenus.c    194 c47Extensions/addons.c  141 display.c
  396 defines.h      173 mathematics/matrix.c
  331 screen.c       247 items.h
```

The threshold is not load-bearing: at >50 files the answer is 27%/71%, at >200 and
>400 it is 23%/64%. Only "no exclusion" gives 0%, which is the artefact. Read it
as: roughly a quarter cold, hot 8% carries about two thirds.

Churn concentrates in the catalogue of what the calculator can do and its
presentation. The mathematics (257 files, 44230 lines) is comparatively stable;
only `matrix.c` reaches the top ten.

**A caution on the "92% cold" figure** sometimes quoted for this codebase. The
8%-hot half is confirmed above. The 92%-cold half does not survive a 12-month
window: 77% of files saw at least one non-sweep commit. Both may be true of
different windows; the original method was not reproduced here, so do not rely
on "92% cold" without one.

## 8. Physical structure

### 8.1 The header graph is not levelizable

Over all 243 headers in `src/c47` (243 edges), one strongly-connected component of
size > 1:

```
  c47.h:120,165  ->  solver/solver.h:12  ->  solver/finite_differences.h:5  ->  c47.h
```

The cycle runs through the god header and compiles only because include guards mask
it. Guards suppress the symptom, not the cycle. One cycle of three is small in
count and total in effect: nothing below it can be compiled, tested or reasoned
about in isolation, because the bottom of the graph includes the top.

### 8.2 The link graph: 97% of the library is one cycle

C47 has **no object partition**: meson emits one `.o` per `.c`. The `c47` target
links `build.sim/src/c47-gtk/c47.p/` = 246 objects, of which **228 are from
`src/c47`** -- one per compiled source. **For C47 the file graph IS the link
graph**; there is no coarser structure to analyse.

`nm` over those 228 objects (undefined symbols resolved against the object that
defines them) gives whole-program truth:

```
  link units                            228
  edges                                2408
  files trapped in cycles         222 = 97%      one SCC
  CCD                                 50624
  ACD                                 222.0      (97% of the library)
  NCCD                                32.10
  globals defined by >1 object       0 of 3023
```

**C47 is one cycle of 222 files.** ACD 222.0 means the average file transitively
depends on 222 of 228. NCCD 32.10 is thirty-two times a balanced binary tree of the
same size -- the signature of one dominant cycle, not of untidiness.

The symbol space is clean: 3023 globals, none defined twice. C47's problem is not
ambiguity about who owns what; it is that everyone can reach everyone.

The files outside the cycle are the proof rather than the exception: `fonts.c`,
`printing/martelFonts.c`, `printing/printerFont8.c` (font data),
`mathematics/pcg_basic.c` (a vendored PRNG), and
`reservedRegisterLookupGenerator.c` (not in the library build). **No part of C47's
own logic is outside the cycle.**

This inverts the obvious reading of s3. With a mutual-recursion knot of this size,
per-component headers are not merely neglected -- they are unwritable: any
component header would need the declarations of the components that call back into
it. **`c47.h` is not the disease. It is what makes the disease survivable.**

### 8.3 What closes the cycle

**`item_t.func` is the dominant edge.** `items.c` dispatches to **205 of the 229
files**. The table touches 90% of the library, and every command calls back into
`items.c`, `registers.c`, `flags.c` and `error.c`.

**A base component reaches a high-level feature.** Shortest cycle through
`mathematics/addition.c`:

```
  mathematics/addition.c  --fnSwapXY()-->        stack.c
  stack.c                 --fnEqSolvGraph()-->   solver/graph.c
  solver/graph.c          --addComplex()-->      mathematics/addition.c
```

**This illustration is from the prior object build and its middle edge no longer
holds:** at `33328e4cc`, `fnEqSolvGraph` is called from `c47Extensions/graphs.c`
and `keyboard.c`, not from `stack.c` (in `stack.c` the symbol appears only in a
comment). Re-derive the shortest cycle against a current build (Annex A) before
quoting it. The structural point stands - a base component transitively reaches a
high-level feature - but the specific edge must be re-measured.

**The compute level already exists by content.** Measured against the true UI
surface (`lcd_fill_rect`, `showString`/`showGlyph`, `showSoftmenu`,
`drawScreen`/`refreshLcd`, `GtkWidget`, `cairo_`, `btnPressed`):

```
  distributions/   0/16   files touch UI    CLEAN
  logicalOps/      0/11   files touch UI    CLEAN
  core/            0/1    files touch UI    CLEAN
  mathematics/     6/128  files touch UI    95.3% CLEAN
  ---------------------------------------------------
  solver/ 6/8    programming/ 5/7    browsers/ 4/4    ui/ 3/3
```

**153 of the 156 `.c` files in mathematics/distributions/logicalOps/core never
touch the UI** (34278 of the 46253 `.c` lines in those four directories; blob
lines, `.c` only). Probe with the full render surface: a set that omits
`refreshScreen`, `refreshRegisterLine` and `popSoftmenu` reports three files
rather than six. The six:

```
  mathematics/int.c:24        refreshLcd(NULL);        // integration refreshes the LCD
  mathematics/matrix.c:1469   showSoftmenu(-MNU_SIMQ); // matrix maths opens a menu
  mathematics/matrix.c:1470   showSoftmenu(-MNU_TAM);
  mathematics/prime.c:818     refreshScreen(253);      // factorising reports progress
  mathematics/rdp.c:119       refreshRegisterLine(REGISTER_X);
  mathematics/round.c:120     refreshRegisterLine(REGISTER_X);
  mathematics/rsd.c:152       refreshRegisterLine(REGISTER_X);
```

These six are not mathematics. They are interactive commands filed under
`mathematics/` because that is where their arithmetic lives. Moving them makes
the numeric core UI-free by content rather than by percentage.

Note what is NOT UI: `displayCalcErrorMessage` / `moreInfoOnError` (the library's
error channel) and the `charString` helpers (text utilities). Counting those as UI
classifies the allocator as a user-interface component.

**The edge 151 files ride: `error.c` is two modules in one file.**
`displayCalcErrorMessage` renders nothing. Its success path is three assignments
-- `lastErrorCode`, `errorMessageRegisterLine`, `screenUpdatingMode`
(`error.c:277-279`) -- and the message is painted much later by
`_refreshRegisterLine` (`screen.c:3723`), which is why the name misleads. But the
same translation unit holds `displayBugScreen` (`error.c:333`), a real renderer:
it writes `calcMode`, calls `hideCursor`, `lcd_fill_rect` (`error.c:345`) and
`showString` (`error.c:348`). The two validation-failure paths of
`displayCalcErrorMessage` call it.

So every file that merely wants to *signal* an error links, through one file, to
the renderer, the fonts and a `calcMode` write. That is the mass of the cycle,
and the two halves share nothing but `errorMessage`. Splitting the file is the
cheapest structural cut available.

**The cycle is not only calls.** `temporaryInformation` is a return channel made
of a global: 56 files write it, 13 read it, and the readers are `display.c` and
`keyboard.c` deciding what to draw. `lastErrorCode` works the same way -- error
flag, control-flow gate and render input on one `uint8_t`. No call goes upward;
a value does. A call-graph tool cannot see this, which is why "97% is one SCC"
has never come with an explanation.

What this buys the reader: the numeric core is cleaner than the SCC suggests.
`calcMode` appears **zero** times in `mathematics/`, `distributions/`,
`logicalOps/`, `registers.c` and `memory.c`. The maths does not know what mode
the calculator is in.

**What a cut would cost.** The upward edges are not evenly spread; they fall into
a few classes, and one of them carries most of the weight:

| class | edges | where |
|---|---|---|
| the error TU | 1 structural cut, 6 sites | `error.c:339-380` - splits the state-setter from the bug screen, and 151 files stop reaching the renderer |
| misfiled maths | 6 files | `int.c`, `matrix.c`, `prime.c`, `rdp.c`, `round.c`, `rsd.c` - move them, do not rewrite them |
| conversion re-enters dispatch | 3 | `conversionUnits.c:761,779,782` call `runFunction` rather than the conversion directly |
| store reaches formatting | 1 | `registers.c:1585` calls `shortIntegerToDisplayString` |
| primitives reach up | 2 | `charString.c:241,297` - a string helper calling the bug screen |
| flags, timer, store reach up | 6 | `flags.c:359`, `store.c:199`, `timer.c:189` and neighbours |
| the data channel | 56 writers | `temporaryInformation` - not cuttable by moving files; the writers must return a status instead |

The first six classes are about 40 call sites. The seventh is the hard one, and
it is why moving files alone will not dissolve the cycle.

**Base services are trapped by single edges.** Degrees inside the cycle:

```
  file                          in   out
  registers.c                   65    23
  registerValueConversions.c    70    14
  error.c                       72     8
  flags.c                       68     9
  charString.c                  41     1
  screen.c                      39    33
```

`charString.c` has three outgoing edges: `displayBugScreen()` in `error.c`, and
`findGlyph()`/`generateNotFoundGlyph()` in `fonts.c`. Only the `error.c` edge
enters the cycle (`fonts.c` is outside it) -- a 2-cycle at the bottom of the graph:
the string utility calls the error reporter to report a bug; the error reporter
calls the string utility to format its message.

`flags.c` (68 dependents) calls up into the UI on every flag change:

```
  flags.c -> fnRefreshState()        in c47Extensions/radioButtonCatalog.c  x6
          -> leaveTamModeIfEnabled() in ui/tam.c                            x3
          -> showAlphaModeonGui()    in c47Extensions/keyboardTweak.c       x2
          -> reallyClearStatusBar()  in screen.c                            x1
          -> calcModeNormal/Aim()    in calcMode.c                          x3
  error.c -> showString()            in screen.c                            x3
          -> printTrace()            in printing/print.c                    x1
```

These are one defect: **"state changed -> tell the UI", written as a
downward-to-upward call.**

---

> **Everything from here to Annex A is assessment and proposal, not fact, and
> not a plan of record.**
>
> Sections 1 to 8 measure what the code *is*. Sections 9 to 11 judge it against
> external practice and sketch what changing it would cost. That analysis was
> produced as an audit input for a separate port project, **not** in agreement
> with the upstream c43 maintainers.
>
> **Nothing in Section 11 is scheduled, accepted, or endorsed by upstream.** Do
> not start splitting `item_t` because a document in a CI repository lists it as
> step 1. Any structural change to c43 goes through upstream review as a merge
> request, on its own merits.
>
> Read Sections 9 to 11 for one thing only: if you are about to touch this
> architecture, they tell you which edges are load-bearing and roughly what a
> cut would cost. That is useful. It is not a mandate.

## 9. Measured against 2026 best practice

References in Annex B. This is a judgement against external criteria, not a
measurement of c43.

| practice | asks | C47 | verdict |
|---|---|---|---|
| Levelizable physical design (Lakos) | dependency graph acyclic | 222 of 228 in one SCC; NCCD 32.10 | **FAIL** |
| Component = `.h`/`.c` with a narrow header | headers declare their own | one 639-line bundle in 228/228 files | **FAIL** |
| Information hiding (Parnas) | modules hide their data | 314 mutable globals, all public | **FAIL** |
| HAL as function-pointer struct, link-time substitution | swap the adapter without recompiling | `#if DMCP_BUILD` forks inside `hal/gui.h`, `hal/lcd.h` | **FAIL** |
| Dependency inversion | the app defines the port | the port IS `dmcp.h`; other targets emulate the DM42 | **FAIL** |
| Application layer hardware-agnostic | no toolkit types above the HAL | `gboolean`/`GtkWidget*`/`cairo_t*` in 12 library files | **FAIL** |
| Features not switched at compile time | runtime flags / plugins | 2781 conditionals; `EXTRA_INFO` in 172 files | **FAIL** |
| Build-input provenance diffable | text sources | keyboard layout + CONFIG defaults in binary `.xlsx` | **FAIL** |
| Table-driven dispatch | data, not switch forests | `indexOfItems[]`, 2871 slots | **PASS**, exemplary |
| Tests as data | corpus over code | 322 `.txt` vs 6 `.c` runner | **PASS**, exemplary |
| Every target built in CI | no untested branch | macOS/Linux/Windows/dmcp/dmcp5/testSuite | **PASS** |
| Generated artefacts reproducible | one source of truth | generators are targets, but outputs are also checked in and nothing diffs them; some inputs are `.xlsx` | **WEAK** |

8 fail, 3 pass, 1 weak. The three passes are what most projects get wrong and C47
gets right. Every failure traces to one root.

## 10. Verdict

**C47's physical architecture is a single 222-file cycle, and the edge that closes
it is the function pointer inside its best design decision.** The item table is
simultaneously what the project got most right -- one table, data-driven dispatch
-- and the mechanism by which every file became reachable from every other. That is
the ordinary way a good logical idea, with no physical discipline to bound it,
consumes a codebase.

The team's structural thinking is real and visible in the table and the corpus. The
physical structure was never enforced, so it decayed into a knot, and the god
header is what makes a knot survivable. Every other complaint here -- no unit
tests, no isolation, `#if` portability, a taxonomy that misleads -- is a
consequence of 222 files that cannot be compiled apart.

The ledger is better than that sounds: the chokepoints are six files, the cheapest
cut is one line, and the fix does not touch the good idea. The table stays one
table. Dispatch stays data-driven. `func` moves to a parallel array.

## 11. What a fix would cost (proposal, not a plan)

**Unadopted.** No upstream maintainer has agreed to any of this. It is recorded
because the measurements behind it are useful when weighing a change, and
because knowing which single edge closes the cycle is worth knowing even if
nobody ever cuts it.

Each step is independently shippable and independently valuable, which is the only
way a project of this size moves. Order is forced by dependency, not by cost.

```
  1. SPLIT item_t INTO items_data + items_bind.
       items_data.c  { param, itemCatalogName, itemSoftmenuName, tamMinMax, status }
                     pure data, no pointers. A LEAF. The generators link it ALONE
                     and the 887 stubs (893 lines) delete themselves.
       items_bind.c  void (*itemFunc[LAST_ITEM+1])(uint16_t), parallel-indexed.
                     The only component holding dispatch edges.
       Measured effect: 224 -> 114 files trapped; ACD 221 -> 108; NCCD 32 -> 15.7.
       Everything below is second-order to this.

  2. INVERT the plot-from-compute edge (fnEqSolvGraph): the caller replots,
       compute does not. Re-identify the exact edge against a current build - the
       prior stack.c -> solver/graph.c edge no longer holds (fnEqSolvGraph is
       called from graphs.c and keyboard.c at 33328e4cc).

  3. ESCALATE the six compute->UI files: int.c, matrix.c, prime.c, rdp.c,
       round.c, rsd.c.
       Buys a 46253-line level that can be compiled and tested alone.

  4. CUT the four single-edge base traps: charString->error, realType->
       registerValueConversions, debug->registers, sort->charString. Worth four
       files, but they are 137 dependents' worth of base component and they make a
       base layer writable. Cheap; not a headline.

  5. INVERT the base services' UI notifications (flags.c, error.c): the service
       raises, the app subscribes.

  6. RE-MEASURE with `nm` over build.sim/ (Annex A). Then decompose the residual
       mesh with sustained escalation. No shortcut exists.

  7. ONLY THEN directories. Every step above is compiler- or linker-enforceable;
       this one is merely tidy, and doing it first produces an honest-looking tree
       with a god header still underneath.
```

Target structure, once the graph permits it -- `#include` points DOWN only:

```
  src/
    c47/
      port/     L0  lcd.h io.h audio.h print_ir.h gui.h + vtable types.
                    INTERFACES ONLY. No #if. No glib.
      base/     L1  typeDefinitions defines charString sort freeList memory
                    error realType fonts
      value/    L2  registers registerValueConversions dataTypes flags stack
                    longInteger real34
      compute/  L3  mathematics/ distributions/ logicalOps/ curveFitting stats
                    conversionUnits dateTime            <- 153/156 already clean
      engine/   L4  items_data items_bind dispatch programming/ solver/
                    saveRestore*
      present/  L5  screen display softmenus statusBar bufferize plotstat printing
      app/      L6  c47.c config keyboard timer assign ui/ browsers/
    targets/
      gtk/          main + port adapters + the GTK callbacks that today live in
                    src/c47/screen.c and timer.c -- moving them is what makes
                    `gboolean` disappear from the library
      dmcp/ dmcp5/  main + port adapters
      testsuite/    main + port adapters + the corpus runner
    tools/          generateConstants generateCatalogs generateTestPgms
                    ttf2RasterFonts        (unchanged: already correct)
  tests/            the 322 .txt corpus (data, not source)
  design/           the spreadsheets, converted to CSV/TSV so provenance is
                    diffable and CI stops building xlsxio
```

Two changes to the HAL, in order: define the port in C47's own terms so the DMCP
adapter becomes the thin one (5.1); then make a port a struct of function pointers
selected at startup, so the adapter is substitutable and `gboolean` in a
platform-neutral header becomes unwritable (5.2, 5.3). Route
`EXTRA_INFO_ON_CALC_ERROR` through one reporting component whose implementation is
chosen per target -- a full one for PC/testSuite, a `(void)` stub for DMCP. 1800
`#if` sites become one component and a link choice, and the flash saving is kept.

Deliberately NOT proposed: the item table stays one table; `items.c`/`screen.c`/
`softmenus.c` stay whole files (they are the hot set, s7 -- splitting them buys
nothing and costs every future merge); the corpus stays `.txt`; the generators stay
build targets; meson stays.

---

# ANNEX A: Metrics and tools

## A.1 The metrics

| metric | definition | C47 today | healthy |
|---|---|---|---|
| **Files trapped in cycles** | vertices in any strongly-connected component of size > 1, over the link graph | **222 of 228 = 97%** | 0 |
| **CCD** (cumulative component dependency) | sum over components of CD(v), where CD(v) = components reachable from v including v | **50624** | ~N log2 N |
| **ACD** (average component dependency) | CCD / N. "the average file depends, directly or transitively, on ACD others" | **222.0** (97% of N) | ~log2(N) = ~8 |
| **NCCD** (normalised CCD) | CCD / CCD(balanced binary tree of N nodes). The scale-free comparator | **32.10** | ~1.0; < 2 acceptable |
| **Levelizable** | is the `#include` graph acyclic (Lakos) | **NO** -- one 3-header cycle through `c47.h` | YES |
| **Churn concentration** | share of file-touches in the hottest k% of files, 12mo, sweep commits excluded | hot 8% = 67% | informational; drives which files may be idiomatised |
| **Cold share** | files with zero non-sweep commits in 12mo | 23% | informational |

Two rules for reading them:

- **NCCD is the number to quote.** ACD scales with N, so it cannot be compared
  across projects or across a refactor that changes file count. NCCD can.
- **A single large cycle dominates every one of them.** ACD 222 is not "lots of
  small coupling"; it is the size of the SCC. Fixing coupling in a cyclic codebase
  means breaking the cycle, not reducing edges.

## A.2 Tools to use

| tool | for | invocation |
|---|---|---|
| **`nm`** | **THE link graph. Exact, whole-program, no inference. The primary instrument.** | `nm --defined-only <obj>` -- keep only globals (`T`/`D`/`B`/`R`/`W`); `nm -u <obj>` for undefined. Edge A->B iff A undefines a symbol B defines. |
| **the meson build dir** | the authoritative object list -- never guess it | `build.sim/src/c47-gtk/c47.p/*.o` (the target's `.p` directory) |
| **clang analyzer** | AST call graph per TU; validates one file precisely | `clang -Xclang -analyze -Xclang -analyzer-checker=debug.DumpCallGraph -Isrc/c47 -Isrc/c47/hal -Idep/decNumberICU -Isrc/generated $(pkg-config --cflags gtk+-3.0) -DPC_BUILD=1 -DLINUX=1 -DOS64BIT=1 <file.c>` |
| **Tarjan SCC** | cycles in any graph above | ~30 lines; it is the whole diagnosis |
| **`git log --since --name-only`** | churn | exclude sweep commits (>100 files) |
| `objdump`, `readelf` | relocations, sections | when `nm` is not enough |
| `include-what-you-use` | header hygiene | would flag `c47.h`'s 134-include bundle directly |
| `cflow`, `doxygen`+graphviz, CodeQL | call graphs without a build | only when no build dir exists |

Off-the-shelf products computing these same metrics: **Sonargraph** (implements
Lakos CCD/ACD/NCCD by name, cycle groups, a cycle break-up computer),
**Structure101** (a "tangle" is an SCC), **Lattix** (dependency structure matrix),
**CppDepend**, **CodeScene** (churn x complexity hotspots), and the `lakos` package
(Dart) for a small readable implementation. Nothing in this document required
inventing a metric. The gap is that no one runs them.

## A.3 Tools and methods NOT to use

| do not | why | measured consequence |
|---|---|---|
| **A regex call-graph extractor** | it cannot see calls through function pointers, and C47 dispatches its whole command set through `indexOfItems[].func` | reports 42% of files in cycles; the truth is 97% |
| **A regex definition extractor that does not exclude the stub block** | `items.c`'s 887 `void fnX(uint16_t ...) {}` lines are definitions AND match a call pattern | 815 of 825 command symbols silently dropped as ambiguous; `items.c` then appears to call 211 files |
| **A glob over a build directory to find objects** | it picks up test artefacts and stale entries | wrong N, therefore wrong ACD and NCCD |
| **A filename test to infer obligation** | a split sub-file has no same-named `.c` yet inherits every edge | "71% of the cycle is not upstream's" -- false |
| **`nm --defined-only` counting all symbols** | local symbols dominate and are not the object's surface | a 38-line owner appears to define 3084 symbols |
| **The `#include` graph alone** | include guards mask cycles; the graph looks nearly acyclic | 1 header cycle visible; the 222-file link cycle invisible |
| **Churn without excluding sweep commits** | a 455-file "Header files centralization" touches everything | 0% cold vs the real 23% |
| **File size as a signal** | the megafiles are the hot files; size is upstream's shape, not the defect | `screen.c` at 6623 lines is not the problem; the cycle is |
| **ACD across differently-sized codebases** | it scales with N | use NCCD |

**Rule: ask the build first.** Every wrong number produced while preparing this
document came from reconstructing something the build had already computed.

# ANNEX B: References

- **John Lakos, _Large-Scale C++ Software Design_** (Addison-Wesley, 1996) and
  **_Large-Scale C++ Volume I: Process and Architecture_** (2019). Physical
  design; components; levelization; the acyclic-`#include` criterion; escalation
  and demotion for breaking cycles; CCD / ACD / NCCD.
  <https://www.pearson.com/en-us/subject-catalog/p/Lakos-Large-Scale-C-Volume-I-Process-and-Architecture/P200000009513/9780201717068>
- **David L. Parnas, "On the Criteria To Be Used in Decomposing Systems into
  Modules"** (CACM 15(12), 1972). Information hiding. C47's 314 public mutable
  globals are the direct negation.
- **Embedded firmware layering** (HAL / device / interface / application) with
  dependency inversion, and the function-pointer-struct HAL for link-time
  substitution and mocking.
  <https://www.embeddedsoft.net/hardware-abstraction-layer-design-for-embedded-systems/>
  <https://bugprove.com/firmware-architecture/>
- **Compile-time feature switching considered harmful**; prefer runtime flags or
  link-time selection. <https://cor3ntin.github.io/posts/undef_preprocessor/>
- **Pruijt et al., "The accuracy of dependency analysis in static architecture
  compliance checking"** (Softw. Pract. Exper., 2017). Why the instrument matters.
  <https://onlinelibrary.wiley.com/doi/full/10.1002/spe.2421>
- Tooling: **Sonargraph** <https://www.hello2morrow.com/products/sonargraph/architect>
  (CCD/ACD/NCCD explained: <https://blog.hello2morrow.com/2014/12/assess-and-control-component-coupling-with-sonargraph-explorer/>);
  **Structure101** <https://www.sonarsource.com/structure101/>;
  **CppDepend** <https://www.cppdepend.com/documentation/code-metrics>;
  **clang::CallGraph** <https://clang.llvm.org/doxygen/classclang_1_1CallGraph.html>;
  **GNU cflow** <http://www.gnu.org/s/cflow/manual/cflow.html>;
  **lakos (Dart)** <https://pub.dev/packages/lakos>.

# ANNEX C: Evidence index

| claim | evidence |
|---|---|
| god header | `src/c47/c47.h` 639 lines, 134 includes; 228 of 229 `.c` include it; the 229th is not in `src/c47/meson.build` |
| 314 globals | `grep -E '^\s*extern ' src/c47/c47.h` = 345, minus `const` function-pointer tables = 314 |
| `core/` is an allocator | `src/c47/core/freeList.{c,h}` = 393 lines |
| hal contract | `src/c47/hal/{audio,gui,io,lcd,print_ir}.h` = 497 lines, no `.c` |
| hal adapters | `src/{c47-gtk,testSuite}/hal/*.c` (5 each); `src/c47-dmcp{,5}/hal/*.c` (4 each) |
| hal is the DMCP API | `src/c47/hal/lcd.h:29-31` |
| glib in the hal | `src/c47/hal/lcd.h:40` `extern gboolean ui_is_active;` |
| gtk inside the library | 12 files; `c47.h`, `screen.c:114,492`, `screen.h`, `timer.c:104`, `timer.h`, `programming/input.c:76`, `hal/lcd.h`, `keyboard.c/.h`, `typeDefinitions.h:811`, `c47Extensions/keyboardTweak.c/.h` |
| testSuite links gtk | `src/testSuite/meson.build` `dependencies: [gtk_dep, gmp_dep, m_dep]`; `testSuite.c:29` `GtkWidget *screen;` |
| conditionals | `grep -rhoE '^\s*#\s*(if\|ifdef\|ifndef\|elif)' src/c47` = 2781; PC_BUILD/DMCP_BUILD union = 67 files, 37 both |
| item_t | `typeDefinitions.h:603-615`; `func` at `:604`; `LAST_ITEM 2870` at `items.h:2989` = 2871 slots; table `items.c:1775-4734` |
| the 887 stubs | `items.c:778-1670`, 893 lines; guard `#if defined(GENERATE_CATALOGS) \|\| defined(GENERATE_TESTPGMS)`; `src/generateCatalogs/meson.build:4` passes `-DGENERATE_CATALOGS` |
| dispatch reach | the table's `func` symbols resolve to 205 of 229 files |
| header cycle | `c47.h:120,165` -> `solver/solver.h:12` -> `solver/finite_differences.h:5` -> `c47.h` |
| link graph | `nm` over `build.sim/src/c47-gtk/c47.p/*.o` (228 objects): 2408 edges; 222/228 in one SCC; CCD 50624; ACD 222.0; NCCD 32.10; 3023 globals, 0 duplicated |
| no object partition | 228 objects for 229 `.c` -- one per compiled source |
| the maths cycle | `addition.c --fnSwapXY--> stack.c --fnEqSolvGraph--> solver/graph.c --addComplex--> addition.c` |
| compute is clean | 150 of 156 `.c` in mathematics/distributions/logicalOps/core touch no true-UI symbol; the six exceptions are `int.c`, `matrix.c`, `prime.c`, `rdp.c`, `round.c`, `rsd.c` |
| base traps | `charString.c` in=41 out=1 (`displayBugScreen` in `error.c`); `error.c` in=72 out=8; `flags.c` in=68 out=9 |
| split effect | removing the dispatch edges: 224 -> 114 trapped; ACD 221.1 -> 108.4; NCCD 31.94 -> 15.67 |
| churn | 12mo window, existing paths, 5 sweeps >100 files excluded; stable for thresholds 100-400 |
| corpus | `src/testSuite`: 322 `.txt`, 6 `.c` |
| CI | `.gitlab-ci.yml` 170 lines; jobs macOS/Linux/Windows/dmcp/dmcp5/dmcp5r47/testSuite/codeDocs |
| build | 15 `meson.build`; `Makefile` (54 targets) wraps `meson`/`ninja` |
| xlsx build inputs | `.gitlab-ci.yml:38-39` builds `xlsxio` to convert `sortingOrder.xlsx`; `src/index spreadsheet/` (16 files, spaces in the name) |
| scale | `git rev-list --count` = 13804; `git shortlog -sn` = 35 authors; first commit 2018-12-23 |
