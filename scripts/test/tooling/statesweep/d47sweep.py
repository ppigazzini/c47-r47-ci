#!/usr/bin/env python3
"""Mutation sweep for the .d47 data-file import path.

The state-file sweep does not touch this reader, and it is a different reader:
readToken()/readComplexToken() instead of readLine(), standardiseComplex() on
every complex element, and matrix dimensions rather than section counts.

Two properties, and the weaker one is labelled as such:

  RC   no crash, no hang, no sanitizer report - the detector that earns its keep
       on this path
  FIX  import, export, import, export must agree. WEAK here, and deliberately
       recorded as weak: expreg writes whatever R00 currently holds, so a mutant
       the importer rejects outright still exports a well-formed file and passes.
       FIX only catches a mutant that IS imported and then re-exported
       differently. Do not read a clean FIX on this path as "the import worked".
"""

import os
import subprocess
import sys

C43 = os.environ.get("C43_TREE", os.getcwd())
T47 = os.environ.get("T47", "./t47")
BINARY = T47 if os.path.isabs(T47) else os.path.join(C43, T47)
TIMEOUT = int(os.environ.get("SWEEP_TIMEOUT", "25"))

HDR = "DATA_FILE_REVISION\n0\nC47/R47_data_file_00\n10000026\nGLOBAL_REGISTERS\n"

# (name, body after the register count line)
BODIES = {
    "real": "R000\nReal\n0.35\n",
    "cplx": "R000\nCplx\n(0.35-i99999)\n",
    "rema": "R000\nRema\n2 2\n0.35\n99999\n-2.5e-3\n4\n",
    "cxma": "R000\nCxma\n2 2\n(0.35-i99999)\n( 3 - i 4 )\ni4\n(-2.5e-3+i4)\n",
}
COUNTS = ["0", "1", "2", "500", "32767", "-1", "65535", "abc"]
DIMS = ["0 0", "1 1", "2 2", "0 2", "2 0", "500 500", "65535 65535", "-1 -1", "abc def"]
ELEMENTS = ["", " ", "(", ")", "()", "i", "(i", "1" * 300, "1" * 3000, "(" + "1" * 3000 + "+i4)", "0.35", "(1e6144+i1e-6144)"]


def run(script):
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


def check(text):
    with open(os.path.join(C43, "dw_in.d47"), "w") as handle:
        handle.write(text)
    for stale in ("dw_a.d47", "dw_b.d47"):
        path = os.path.join(C43, stale)
        if os.path.exists(path):
            os.unlink(path)

    rc, err = run("impreg dw_in.d47; expreg 00 dw_a.d47")
    asan = " ASAN" if "AddressSanitizer" in err else ""
    if rc != 0 or asan:
        return "RC", f"import/export rc={rc}{asan}"
    rc, err = run("impreg dw_a.d47; expreg 00 dw_b.d47")
    asan = " ASAN" if "AddressSanitizer" in err else ""
    if rc != 0 or asan:
        return "RC", f"reimport of our own file rc={rc}{asan}"
    try:
        with open(os.path.join(C43, "dw_a.d47")) as handle:
            first = handle.read()
        with open(os.path.join(C43, "dw_b.d47")) as handle:
            second = handle.read()
    except OSError as exc:
        return "RC", f"no output file: {exc}"
    if first != second:
        return "FIX", "import/export is not a fixed point"
    return None, None


def main():
    failures = []
    total = 0

    for name, body in BODIES.items():
        for count in COUNTS:
            total += 1
            kind, why = check(HDR + count + "\n" + body)
            if kind:
                failures.append((f"{name}, register count {count}", kind, why))

    for dims in DIMS:
        for name in ("rema", "cxma"):
            head = "R000\nRema\n" if name == "rema" else "R000\nCxma\n"
            tail = "0.35\n99999\n-2.5e-3\n4\n"
            total += 1
            kind, why = check(HDR + "1\n" + head + dims + "\n" + tail)
            if kind:
                failures.append((f"{name} dims '{dims}'", kind, why))

    for element in ELEMENTS:
        for tag in ("Cplx", "Real"):
            total += 1
            kind, why = check(HDR + "1\nR000\n" + tag + "\n" + element + "\n")
            if kind:
                shown = element[:14] + ("..." if len(element) > 14 else "")
                failures.append((f"{tag} element '{shown}' ({len(element)}B)", kind, why))

    for cut in range(1, 12):
        total += 1
        text = HDR + "1\n" + BODIES["cxma"]
        kind, why = check("\n".join(text.split("\n")[:cut]))
        if kind:
            failures.append((f"truncated to {cut} line(s)", kind, why))

    print(f"d47 sweep: {total} mutants")
    for what, kind, why in failures:
        print(f"  {kind:<4} {what:<44} {why}")
    print(f"  {len(failures)} failure(s)")
    return 1 if failures else 0


sys.exit(main())
