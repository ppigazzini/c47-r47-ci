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
truncation at four offsets into every section. 210 mutants against a reset
calculator's state file, about six minutes under ASan.

**FIX is the property that earns its keep.** It caught a state file the
calculator wrote itself: a restore whose EQUATIONS count outran the file left
empty-string formulae, the save wrote them as blank lines, and `readLine()`
skips blank lines - so reloading took the next section header for an equation.
Nothing crashed. Only the round trip showed it.

## Baseline

See `baseline.txt`. Two entries at the time of writing, both reproducing
identically on upstream `199477075` and on the c43 !1631 branch, so neither is
that branch's doing. Read a new name in the output as a regression; read a
missing one as a fix, and tighten the file.
