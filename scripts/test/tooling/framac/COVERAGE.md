# Frama-C coverage accounting (Milestone M5)

What the Frama-C lanes actually reach in upstream c43, and what they cannot -
the honest denominator behind the four gates (M0 parse, M1 Eva, M2 regression,
M3 WP, M4 nonterm). Measured at upstream master `ccafdfe51`, Frama-C 32.1.

The one-line truth: **Frama-C reaches a curated niche by design, and its value is
proof-depth (over all inputs, or a real proof of a fix), not breadth.** The
numbers below make that concrete rather than letting "we added Frama-C" imply
coverage it does not have.

## Denominators (measured)

| unit | count | how |
|---|---|---|
| library `.c` files (`src/c47`) | 229 | `find src/c47 -name '*.c' \| wc -l` |
| `void fn*(uint16_t)` command functions | 652 | `git grep -hoE '^ *void +fn[A-Za-z0-9_]+ *\(uint16_t'` deduped |
| all function definitions (approx) | ~2594 | top-level definition grep, upper bound |
| files whose VALUES flow through decNumber/GMP (Tier D) | 192 / 229 | grep `real34\|decNumber\|mpz_\|longInteger` |
| GTK/UI files (unmodelable) | 14 / 229 | grep `gtk/gtk.h\|GtkWidget\|cairo_\|drawScreen` |
| numeric-lib-free files (Tier A/B surface) | 37 / 229 | the complement |

## Reached: directly analysed (proof or alarm over all inputs)

~26 c43 functions carry a Frama-C harness or contract. This is ~1% of the
function count - and that is the point: these are the high-risk kernels where a
proof is worth the hand-written harness.

| milestone | c43 functions reached |
|---|---|
| M1 Eva/RTE | `fnAnd/Or/Xor/CountBits` kernels, `fnMaskl/fnMaskr`, `freeListFree/Reduce` insert, `stringNextGlyphNoEndCheck_JM`, shift/rotate family `fnAsr/Sl/Sr/Rl/Rr/Rrc/Lj/Rj` |
| M2 regression | `findKey2ndParam`, `insColRealMatrix`, `insColComplexMatrix`, `calculateEigenvalues`, `indirectAddressing` (complex-matrix dump) |
| M3 WP | `regKStoC`, `regCtoKS`, `TO_BLOCKS`, `fnMaskl` shift precondition |
| M4 nonterm | the integrator nesting (modelled; fix bound proved, unbounded form confirmed) |

Outcomes: PROVED safe/correct - logic ops, freeList insert, register bijection,
block-rounding law, mask shift bound. FINDING - `stringNextGlyphNoEndCheck_JM`
OOB read (plausible-live at `bufferize.c:605`, unconfirmed). REGRESSION-WALLED -
four historic OOBs, three of them ASan/Valgrind-invisible pool overruns. PRECISION
handoffs closed by WP - mask, and (documented deferred) `fnLj` clz relation.

## Reached: parse only (M0, structural, no semantic analysis)

34 files parse and typecheck as one C17 program to the kernel
(`tooling/framac/targets.txt`) - the prerequisite for any Eva/WP work, not
analysis itself. This is ~15% of the 229 `.c` files.

## Out of reach (justified, not silently dropped)

| class | size | why | escape hatch |
|---|---|---|---|
| decNumber/GMP-VALUED code | 192 / 229 files | Eva widens to top, WP encodes nothing useful for 34-digit decimal / bignum | its INDEX/control logic IS reachable by stubbing the value as an opaque blob - the M2 technique (`real34_t` as `{uint32_t[4]}`) |
| GTK / cairo / screen / display | 14 files | toolkit types and the event loop are unmodelable | none; not a Frama-C target |
| whole-program analysis | all | `indexOfItems[].func` + 314 globals = state explosion | none; only per-kernel analysis is tractable |
| pool-internal overruns within `ram` | - | a write past a block but inside the one `ram` malloc is invisible to Eva for the same reason ASan/Valgrind miss it | model the specific buffer as a sized object (M2 does this per-bug) |

## Not yet (reachable, no harness written)

The rest of the 37-file numeric-lib-free surface beyond the ~26 functions above,
plus the Tier-B index/pointer logic inside the 192 numeric files that a stubbed
harness could reach. These are candidates for future rounds, not out-of-reach.

## The dynamic bridge (E-ACSL) - available, not wired

The M1-M3 ACSL contracts could be compiled to runtime checks with E-ACSL and run
under the existing `.txt` corpus for a dynamic second check. Not implemented; a
noted option, listed so the gap is explicit.

## Exit status

Every `src/c47` function falls into one of: **directly analysed** (~26),
**parse-reached** (34 files), **out-of-reach** (192 numeric-valued + 14 UI +
whole-program, each with a reason), or **not-yet** (the reachable remainder). The
directly-analysed set has a green Eva/WP/regression/nonterm gate in CI
(`test-framac.yml`); the out-of-reach set is justified line by line above. No lane
claims coverage it does not have.
