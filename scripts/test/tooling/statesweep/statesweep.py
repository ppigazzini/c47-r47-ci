#!/usr/bin/env python3
"""Systematic state-file mutation sweep.

For every mutant: load it, save it, load THAT, save again. Three properties, and
a failure of any one is a real defect, not a taste question:

  RC     the calculator must not crash, hang or report a sanitizer error
  FIX    save(load(save(load(m)))) == save(load(m)) - what the loader made of the
         file must survive a round trip, or the calculator has written a file it
         reads back as something else
  SANE   the file the calculator writes must still parse as sections: the section
         headers it wrote must be the ones a reader finds

Mutations: every count line set to each adversarial value, and truncation at
every section boundary.
"""

import os
import subprocess
import sys

C43 = os.environ.get("C43_TREE", os.getcwd())  # a built upstream clone
T47 = os.environ.get("T47", "./t47")  # headless binary in it (make simc47 t47)
TIMEOUT = int(os.environ.get("SWEEP_TIMEOUT", "25"))
# subprocess resolves the program against the PARENT's cwd, not the cwd= it is
# handed, so a relative T47 has to be joined here or the sweep cannot be run
# from anywhere but the clone - which is the one place the README does not say.
BINARY = T47 if os.path.isabs(T47) else os.path.join(C43, T47)

# Sections whose header line is followed by a count line.
COUNTED = [
    "GLOBAL_REGISTERS",
    "LOCAL_REGISTERS",
    "NAMED_VARIABLES",
    "STATISTICAL_SUMS",
    "KEYBOARD_ASSIGNMENTS",
    "KEYBOARD_ARGUMENTS",
    "MYMENU",
    "MYALPHA",
    "USER_MENUS",
    "EQUATIONS",
]
VALUES = ["0", "1", "3", "17", "18", "19", "28", "37", "45", "200", "500", "32767", "-1", "65535", "abc"]
SECTION_NAMES = set(COUNTED) | {
    "GLOBAL_FLAGS",
    "LOCAL_FLAGS",
    "SYSTEM_FLAGS",
    "SYSTEM_FLAGS1",
    "PROGRAMS",
    "OTHER_CONFIGURATION_STUFF",
    "Cmnt",
}


def run(script):
    """Drive the calculator once; a timeout is a hang and counts as a failure."""
    try:
        done = subprocess.run(
            [BINARY, "--reset", "--exec", script],
            cwd=C43,
            capture_output=True,
            timeout=TIMEOUT,
            env={**os.environ, "ASAN_OPTIONS": "detect_leaks=0"},
            check=False,
        )
    except subprocess.TimeoutExpired:
        return 124, ""
    return done.returncode, done.stderr.decode("utf-8", "replace")


def read(name):
    with open(os.path.join(C43, name)) as handle:
        return handle.read()


def write(name, text):
    with open(os.path.join(C43, name), "w") as handle:
        handle.write(text)


def sections(name):
    """The section headers a reader finds in a file the calculator wrote."""
    return [line for line in read(name).split("\n") if line in SECTION_NAMES]


def check(text):
    """Return (property, detail) for a mutant, or (None, None) if it holds."""
    write("sw_in.sav", text)
    for stale in ("sw_a.sav", "sw_b.sav"):
        path = os.path.join(C43, stale)
        if os.path.exists(path):
            os.unlink(path)

    rc, err = run("loadst sw_in.sav; savest sw_a.sav")
    asan = " ASAN" if "AddressSanitizer" in err else ""
    if rc != 0 or asan:
        return "RC", f"first load/save rc={rc}{asan}"

    rc, err = run("loadst sw_a.sav; savest sw_b.sav")
    asan = " ASAN" if "AddressSanitizer" in err else ""
    if rc != 0 or asan:
        return "RC", f"reload of our own file rc={rc}{asan}"

    try:
        first, second = read("sw_a.sav"), read("sw_b.sav")
    except OSError as exc:
        return "RC", f"no output file: {exc}"
    if first != second:
        return "FIX", "save(load(x)) is not a fixed point"

    before, after = sections("sw_a.sav"), sections("sw_b.sav")
    if before != after:
        return "SANE", f"section list changed: {before} -> {after}"
    return None, None


def main():
    # The seed is an ordinary saved state: ./t47 --reset --exec 'savest st.sav'
    seed = sys.argv[1] if len(sys.argv) > 1 else "st.sav"
    base = read(seed).split("\n")
    failures = []
    total = 0

    for section in COUNTED:
        if section not in base:
            continue
        at = base.index(section)
        for value in VALUES:
            mutant = list(base)
            mutant[at + 1] = value
            total += 1
            kind, why = check("\n".join(mutant))
            if kind:
                failures.append((f"{section} count {value}", kind, why))

    for section in sorted(SECTION_NAMES):
        if section not in base:
            continue
        at = base.index(section)
        for cut in (at, at + 1, at + 2, at + 4):
            if cut >= len(base):
                continue
            total += 1
            kind, why = check("\n".join(base[:cut]))
            if kind:
                failures.append((f"truncated {cut - at} line(s) into {section}", kind, why))

    print(f"seed {seed}: {total} mutants")
    for what, kind, why in failures:
        print(f"  {kind:<4} {what:<44} {why}")
    print(f"  {len(failures)} failure(s)")
    return 1 if failures else 0


sys.exit(main())
