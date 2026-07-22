# Glossary

Audit basis: upstream `8bf795092ff7a03e85c5688abc8d56a90fa583f1`, 2026-07-19.

The words the rest of this set uses without stopping to define them, in two
tiers that must not be confused:

- **Section 1 is the calculator's vocabulary.** Upstream owns it. If a
  definition here disagrees with the c43 source, the source wins and this page
  is the bug.
- **Section 2 is this repository's vocabulary.** We invented it. None of it
  appears in the product, and upstream is not obliged to agree with any of it.

A reader who cannot tell which tier a word is in will look for `lane` in the c43
source and not find it. That is the failure this split exists to prevent.

Every entry names the file that defines it. **No entry carries a count**, even
where the source has one: an item-space bound or a flag count is a number
upstream moves, and [00-architecture.md](00-architecture.md) already owns the
measured figures with the method for re-deriving them.

**What this page does not cover.** It defines terms; it does not explain
subsystems. For what the item table costs, see
[00-architecture.md](00-architecture.md); for where a symbol lives, see
[01-codebase.md](01-codebase.md); for what a detector does, see
[04-debugging.md](04-debugging.md).

## 1. The calculator's terms

Line numbers are at the audit basis above and rot faster than the definitions
do; grep the symbol if a citation misses.

| term | what it is |
|---|---|
| **item** | one addressable calculator function or menu entry: a row of `item_t` carrying a function pointer, a param, catalog and softmenu names, TAM bounds and a status word (`src/c47/typeDefinitions.h:603`) |
| **the item table** | the single flat array `indexOfItems[]`, indexed by item ID, placed in QSPI flash on hardware (`src/c47/items.c:1775`) |
| **`LAST_ITEM`** | the upper bound of the item ID space (`src/c47/items.h:2989`). Also the `INVALID_MENU` sentinel - see the collisions below |
| **softmenu** | a six-column menu descriptor: an ID, a count and a pointer to its items (`src/c47/typeDefinitions.h:523`) |
| **TAM** | the mode that collects an item's argument after its key is pressed - a register number, a digit count. `tam.mode` non-zero means the calculator is in it (`src/c47/typeDefinitions.h:673`). **The acronym is never expanded anywhere in the c43 source**; treat any expansion you have seen as folklore |
| **nim** | Numeric Input Mode: `calcMode == CM_NIM`, the state while digits are being typed into X (`src/c47/defines.h:1634`) |
| **AIM, PEM, EIM, MIM** | the other input modes - Alpha, Program Entry, Equation Input, Matrix Input - all `calcMode` values alongside `CM_NIM` (`src/c47/defines.h:1633`). Read from the enum, not from an upstream statement of the expansions |
| **`calcMode`** | one byte holding which top-level UI mode the calculator is in (`src/c47/c47.h:418`, values at `src/c47/defines.h:1632`) |
| **reg X, the stack** | `REGISTER_X` to `REGISTER_T`, the first four of the lettered registers (`src/c47/defines.h:1202`) |
| **lettered registers** | the fixed block that holds the stack, `L`, and `I`/`J` (`src/c47/defines.h:1205`). **Not** the same as named variables |
| **named variables** | a separate, user-named ID space well above the lettered block (`src/c47/defines.h:1264`) |
| **`I` and `J`** | the matrix index registers, inside the lettered block (`src/c47/defines.h:1215`) |
| **flags** | two disjoint sets with separate APIs: user flags via `getFlag` and system flags via `getSystemFlag` (`src/c47/flags.h:27`). A number is meaningless without knowing which set it indexes |
| **`real34` / `complex34` / longint** | the numeric payloads: `decQuad` (34 digits), a pair of those, and GMP's `mpz_t` (`src/c47/realType.h:13`, `src/c47/longIntegerType.h:23`). Their type tags are `dtReal34`, `dtComplex34`, `dtLongInteger` (`src/c47/typeDefinitions.h:198`) |
| **HAL** | hardware abstraction layer: the adapters between the calculator core and a platform. [00-architecture.md](00-architecture.md) Section 5 owns what it does and does not cover |
| **DMCP, DMCP5** | SwissMicros' firmware platforms - DMCP for the DM42, DMCP5 for the newer board, selected by the `DMCPVERSION` Meson option (`meson.build:120` in the clone) |
| **QSPI, `TO_QSPI`** | the DM42's external flash, and the attribute that places a const table there rather than in scarce internal memory (`src/c47/items.c:1775`) |
| **`.p47`, `.s47`, `.d47`** | the keystroke-program, saved-state and data file extensions (`src/c47/hal/io.h:20`, `:12`, `:15`) |
| **`SNAP`** | the item that captures the LCD to a bitmap (`src/c47/items.h:1452`). Its handler is an **empty stub in the testSuite build** (`src/c47/items.c:1495`), which is why a skipped `SNAP` leaves a stale bitmap behind rather than failing |
| **SHOI** | how many stack lines the hex/binary integer display takes over in base mode, held in `displayStackSHOIDISP` (`src/c47/c47.h:422`). **The acronym is expanded nowhere in the c43 source.** The behaviour is verified; the letters are not |

### c47, r47 and t47 are not three of the same thing

The set names them in one breath, and the source does not treat them alike:

- **`c47` and `r47` are runtime keyboard models**, chosen from `calcModel`
  (`src/c47/c47.h:237`); the R47 family is tested with `isR47FAM`
  (`src/c47/defines.h:625`).
- **`t47` is a build**, not a model: a compile-time `T47` define that strips the
  debug options (`src/c47/defines.h:419`) plus a Jim/Tcl front end
  (`src/t47/dsl.c`).

That asymmetry is why `make t47` alone gives you the R47-based binary - the
target picks a *model* you did not ask for. [02-build.md](02-build.md) owns the
fix (`make simc47 t47`).

## 2. This repository's terms

None of these appear in the c43 source. Where a script owns the definition, the
script wins.

| term | what it is |
|---|---|
| **lane** | one CI job: a `scripts/test/run-*.sh` script that runs unchanged locally, with the workflow as a thin caller. [05-ci.md](05-ci.md) owns the catalogue |
| **the corpus** | the regression `.txt` files the testSuite replays, plus the `*_cov.txt` extensions. **The fuzz lanes reuse the word** for a libFuzzer seed corpus, which is a different thing |
| **driver** | one of the three ways to express a test - a testSuite `.txt` file, a `t47` DSL script, or an in-C `*Cov` function. [03-testing.md](03-testing.md) owns the ranking |
| **baseline** | a checked-in file of accepted findings a lane diffs against: a new finding fails, a vanished one is reported as a likely fix (`scripts/test/run-leakscan.sh`) |
| **ratchet** | a floor that may only rise. The coverage floors are one (`scripts/test/coverage-floors.txt`); the leak scanner's high-water bound is an unrelated second |
| **high-water bound** | the leak scanner's running extreme - the least free memory and the most GMP ever seen - so only growth past the previous extreme is reported (`scripts/test/tooling/leakscan.patch`). Assigning it unconditionally is what invented the `toReal` finding; [07-writing.md](07-writing.md) tells that story |
| **gate vs report-only** | whether a lane fails CI on a finding or merely publishes it. [05-ci.md](05-ci.md) owns which lanes are which, and says plainly that the reason for the report-only five is not recorded |
| **sector** | a named group of source files coverage is aggregated over, so a floor can be set per subsystem (`scripts/test/coverage-floors.txt`). Sector percentages and the global floor use **different denominators** |
| **false pass** | a run that produced *fewer* findings because it died early, so the baseline diff passes. Guarded by completion sentinels in the lane scripts. [04-debugging.md](04-debugging.md) owns the catalogue |
| **negative control** | a run against the **unfixed** tree that must show the bug, proving the check can fail at all. A gate that has never fired is not a gate. **No script enforces this** - it is a discipline, stated in [AGENTS.md](../AGENTS.md) |
| **the pool** | this set's name for the calculator's own heap. **It is not a c43 term**: the source calls it the free list and free memory regions, and allocates from it with `allocC47Blocks` (`src/c47/memory.c:76`). Do not grep the product for "pool" and conclude it is absent |
| **the canary, `POOL_GUARD`** | a by-hand patch that writes a position-dependent value around each allocated block to catch an overrun *inside* the pool - the class ASan and Valgrind are structurally blind to. Not a lane. [04-debugging.md](04-debugging.md) Section 5 owns it |
| **sweep** | driving one operation across every item, or every stack type, to find the case that breaks. Not a garbage-collection term |
| **tooling overlay** | a not-yet-upstream patch under `scripts/test/tooling/` applied onto the freshly synced clone, because this repo may not carry product code |
| **`HARNESS_WORK`** | the single scratch root every lane derives its paths from. Two lanes sharing one destroy each other's clone (`scripts/test/lib/common.sh`) |
| **`UPSTREAM_COMMIT`** | a full 40-character SHA pinning the product clone; empty means resolve `UPSTREAM_REF`. It is what turns any lane into a bisect probe (`scripts/test/lib/common.sh`) |

## 3. Words that mean two things

Each of these has cost someone time. The entry is the disambiguation, not the
definition.

| word | meaning A | meaning B |
|---|---|---|
| **`LAST_ITEM`** | one past the last real item ID | the `INVALID_MENU` sentinel (`src/c47/items.h:2997`) |
| **softmenu** | the descriptor struct, and the global array | the bottom row on screen. A third type, `softmenuStack_t`, is the display stack (`src/c47/typeDefinitions.h:545`) |
| **TAM** | the argument-entry mode | a bezel state, and a display line (`src/c47/defines.h:1430`) |
| **tag** | the `dataType` enum in a register header (`src/c47/typeDefinitions.h:419`) | the adjacent 5-bit `tag` field in the same word, carrying short-integer base, real34 angular mode or long-integer sign (`src/c47/typeDefinitions.h:420`) |
| **`I`** | the matrix index register | `FLAG_I`, at the same numeric index in a different space (`src/c47/defines.h:825`) |
| **`calcMode`** | the global UI mode | a member of `softmenuStack_t` holding the parent mode (`src/c47/typeDefinitions.h:552`) |
| **nim** | Numeric Input Mode | the `const char *nim` argument of `displayNim` (`src/c47/screen.h:251`) |
| **register** | a lettered register, including the stack | a named variable, in a wholly separate ID space |
| **corpus** | the testSuite regression files | a libFuzzer seed corpus |
| **ratchet** | the coverage floors | the leak scanner's high-water bound |
| **driver** | one of the three ways to write a test | `--keyscan`, the state-machine driver |
| **guard** | the `POOL_GUARD` canary | the `build.guard` build directory, and ordinary "guarded by" prose |
