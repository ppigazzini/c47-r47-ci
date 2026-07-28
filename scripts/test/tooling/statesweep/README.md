# statesweep.py - mutate a state file, then hold the calculator to three properties

This exists because the same defect kept being found by hand, one instance per
review round, always in whichever guard had been written last. The sweep finds
the class in one run.

It is **not a lane** (nothing in `.github/workflows/` calls it) and this page
does not claim it is. It needs a built upstream clone; run it there.

```bash
cd "$upstream_clone"                       # make simc47 t47 first
./t47 --reset --exec 'savest st.sav'       # the seed: an ordinary saved state
C43_TREE=$PWD python3 "$harness/scripts/test/tooling/statesweep/statesweep.py" st.sav
```

Every mutant is loaded, saved, loaded again and saved again, and each of these
is a defect if it fails - none is a matter of taste:

| | what it says |
|---|---|
| **RC** | the calculator must not crash, hang or trip a sanitizer on any file |
| **FIX** | `save(load(x))` must be a fixed point: a file the calculator wrote and reads back as something else is a file that destroys state |
| **SANE** | the section headers the calculator wrote must still be the sections a reader finds in what it wrote |

Mutations: every counted section's count line set to each of fifteen adversarial
values (0, 1, 3, 17, 18, 19, 28, 37, 45, 200, 500, 32767, -1, 65535, `abc`), and
truncation at four offsets into every section. 210 mutants, about six minutes
under ASan.

**The seed decides how much of this is real.** A reset calculator's state file
has no registers, no programs, no stats and no assignments, so most mutants
mutate a count over nothing. Build a fat one and sweep that too:

```bash
./t47 --reset --exec 'nim 0.35; xeq STO 00; nim 99999; xeq STO 01;
  nim 2.5; nim 7; xeq COMPLEX; xeq STO 02;
  nim 3; nim 11; item 433; nim 0.35; nim 99999; item 433; savest fat.sav'
```

which gives 137 global registers, 4 named variables, 28 statistical sums, 37 key
assignments and 2 user menus; graft MYMENU/MYALPHA entries and equations by
editing the file. Both seeds are worth a run; they have found the same defects so
far, which is itself worth knowing.

`d47sweep.py` is the same idea for the `.d47` import path, which is a different
reader - `readToken()` rather than `readLine()`, `standardiseComplex()` on every
complex element, matrix dimensions rather than section counts. 85 mutants. Its
FIX property is weak and its docstring says why.

**FIX is the property that earns its keep.** It caught a state file the
calculator wrote itself: a restore whose EQUATIONS count outran the file left
empty-string formulae, the save wrote them as blank lines, and `readLine()`
skips blank lines - so reloading took the next section header for an equation.
Nothing crashed. Only the round trip showed it.

## Baseline

`baseline.txt` is **empty**, and that is the only state worth keeping it in. It
opened with two entries; both were fixed rather than lived with. Read any name in
the output as a regression.

The differential these tools exist to produce, measured on the fat seed:

| | upstream `199477075` | c43 !1631 branch |
|---|---|---|
| `statesweep.py` | **106** of 210 mutants fail | **0** |
| `d47sweep.py` | **3** of 85 fail | **0** |

On the base most of the 106 are hangs (`rc=124`): a count larger than the
entries that follow ran the section loop past end of file and `doLoad()` never
looked at `ioEof()`. The two that survived the first eight commits were an
allocator table written before its bound was checked, and a program area a file
could resize to nothing; both are fixed on that branch too.
