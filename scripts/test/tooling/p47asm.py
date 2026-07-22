#!/usr/bin/env python3
"""Assemble a C47 .p47 program file from a mnemonic listing.

The byte encoding (verified against upstream's loader, saveRestorePrograms.c): an opcode below 128 is one byte, otherwise two
(`0x80|(op>>8), op&0xff`); a name operand is `253 len bytes...` (STRING_LABEL_VARIABLE); a numeric literal is
`114 8 len ascii-digits...` (ITM_LITERAL + long-integer tag); END is the two-byte opcode; the trailing `.END.` `255 255` is
written to the file but excluded from the PROGRAM byte count. One byte per line, after the six header lines.

Opcode numbers are parsed from the resolved clone's src/c47/items.h (`--items`), so the tool follows upstream renumbering
instead of pinning numbers here. Listing syntax, one instruction per line ('#' comments):

    LBL 'A'          ; name operands in single quotes (ASCII only)
    ITM_PGMSLV 'A'   ; any ITM_* name from items.h works verbatim
    LIT 2            ; numeric literal
    ENTER
    SOLVE 'x'
    STO 99           ; bare integer = numbered register operand, one byte
    RTN
    END              ; explicit; the final .END. is appended automatically

`--selftest` assembles five embedded programs and compares them byte-for-byte against streams that were executed against
upstream (the self-nesting repros of c43 MR !1610): a drifted encoder fails loudly rather than emitting plausible garbage.
"""

import argparse
import re
import sys

# Friendly aliases -> items.h names. Anything not listed here must be written as its ITM_* name.
ALIASES = {
    "LBL": "ITM_LBL", "RTN": "ITM_RTN", "ENTER": "ITM_ENTER", "END": "ITM_END",
    "STO": "ITM_STO", "RCL": "ITM_RCL", "ADD": "ITM_ADD", "SUB": "ITM_SUB",
    "PGMSLV": "ITM_PGMSLV", "PGMINT": "ITM_PGMINT", "PGMPLT": "ITM_PGMPLT",
    "SOLVE": "ITM_SOLVE", "INTYX": "ITM_INTEGRAL_YX", "PLTF": "ITM_PLTf",
    "SUMN": "ITM_SIGMAn", "MEM": "ITM_MEM",
}
STRING_LABEL_VARIABLE = 253
ITM_LITERAL = 114
LITERAL_LONG_INTEGER_TAG = 8


def parse_items(path):
    table = {}
    rx = re.compile(r"^#define\s+(ITM_\w+)\s+(\d+)")
    with open(path, encoding="utf-8", errors="replace") as fh:
        for line in fh:
            m = rx.match(line)
            if m:
                table[m.group(1)] = int(m.group(2))
    if "ITM_LBL" not in table or "ITM_END" not in table:
        sys.exit(f"p47asm: {path} does not look like items.h (no ITM_LBL/ITM_END)")
    return table


def emit_op(op):
    return [op] if op < 128 else [0x80 | (op >> 8), op & 0xFF]


def assemble(listing, items):
    body = []
    for lineno, raw in enumerate(listing.splitlines(), 1):
        line = raw.split("#", 1)[0].split(";", 1)[0].strip()
        if not line:
            continue
        parts = line.split(None, 1)
        mnem = parts[0].upper() if not parts[0].startswith("ITM_") else parts[0]
        name = ALIASES.get(mnem, parts[0] if parts[0].startswith("ITM_") else None)
        if name is None or name not in items:
            sys.exit(f"p47asm: line {lineno}: unknown mnemonic '{parts[0]}' (not an alias, not in items.h)")
        arg = parts[1].strip() if len(parts) > 1 else None
        body_op = emit_op(items[name])
        if arg is None:
            body += body_op
        elif arg.startswith("'") and arg.endswith("'") and len(arg) >= 3:
            s = arg[1:-1]
            if not s.isascii():
                sys.exit(f"p47asm: line {lineno}: name operand must be ASCII: {arg}")
            body += body_op + [STRING_LABEL_VARIABLE, len(s)] + [ord(c) for c in s]
        elif arg.isdigit() and name in ("ITM_STO", "ITM_RCL"):
            n = int(arg)
            if n > 99:
                sys.exit(f"p47asm: line {lineno}: register operand out of range: {n}")
            body += body_op + [n]
        else:
            sys.exit(f"p47asm: line {lineno}: unsupported operand '{arg}' for {name}")
    return body


def assemble_program(listing, items):
    # LIT is not an item: expand it before instruction assembly.
    out = []
    for raw in listing.splitlines():
        line = raw.split("#", 1)[0].split(";", 1)[0].strip()
        if not line:
            continue
        parts = line.split(None, 1)
        if parts[0].upper() == "LIT":
            digits = parts[1].strip()
            if not digits.isdigit():
                sys.exit(f"p47asm: LIT takes a non-negative integer, got '{parts[1]}'")
            out.append(("LITERAL", digits))
        else:
            out.append(("INSN", line))
    body = []
    for kind, payload in out:
        if kind == "LITERAL":
            body += [ITM_LITERAL, LITERAL_LONG_INTEGER_TAG, len(payload)] + [ord(c) for c in payload]
        else:
            body += assemble(payload, items)
    return body


def write_p47(body, path):
    with open(path, "w", encoding="ascii") as fh:
        fh.write("PROGRAM_FILE_FORMAT\n0\nC47_program_file_version\n1\nPROGRAM\n%d\n" % len(body))
        for b in body:
            fh.write("%d\n" % b)
        fh.write("255\n255\n")


SELFTEST = [
    # (name, listing, expected byte stream - each executed against upstream c43 in MR !1610 work)
    ("selfslv", "LBL 'A'\nPGMSLV 'A'\nLIT 2\nENTER\nLIT 3\nSOLVE 'x'\nRTN\nEND",
     [1, 253, 1, 65, 134, 11, 253, 1, 65, 114, 8, 1, 50, 35, 114, 8, 1, 51, 134, 72, 253, 1, 120, 4, 133, 178]),
    ("selfint", "LBL 'A'\nPGMINT 'A'\nLIT 0\nENTER\nLIT 1\nINTYX 'x'\nRTN\nEND",
     [1, 253, 1, 65, 134, 10, 253, 1, 65, 114, 8, 1, 48, 35, 114, 8, 1, 49, 134, 154, 253, 1, 120, 4, 133, 178]),
    ("selfsum", "LBL 'A'\nLIT 1\nENTER\nLIT 2\nENTER\nLIT 1\nSUMN 'A'\nRTN\nEND",
     [1, 253, 1, 65, 114, 8, 1, 49, 35, 114, 8, 1, 50, 35, 114, 8, 1, 49, 134, 136, 253, 1, 65, 4, 133, 178]),
    ("selfplt", "LBL 'P'\nPGMPLT 'P'\nLIT 1\nENTER\nLIT 5\nPLTF 'x'\nRTN\nEND",
     [1, 253, 1, 80, 138, 172, 253, 1, 80, 114, 8, 1, 49, 35, 114, 8, 1, 53, 138, 174, 253, 1, 120, 4, 133, 178]),
    ("spdeep", "LBL 'A'\nPGMSLV 'A'\nMEM\nSTO 99\nLIT 2\nENTER\nLIT 3\nSOLVE 'x'\nRTN\nEND",
     [1, 253, 1, 65, 134, 11, 253, 1, 65, 133, 239, 44, 99, 114, 8, 1, 50, 35, 114, 8, 1, 51, 134, 72, 253, 1, 120, 4, 133, 178]),
]


def selftest(items):
    failed = 0
    for name, listing, expected in SELFTEST:
        got = assemble_program(listing, items)
        if got != expected:
            print(f"SELFTEST FAIL {name}:\n  expected {expected}\n  got      {got}")
            failed += 1
        else:
            print(f"selftest ok: {name} ({len(got)} bytes)")
    return failed


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--items", required=True, help="path to the resolved clone's src/c47/items.h")
    ap.add_argument("--selftest", action="store_true", help="verify the encoder against executed byte streams")
    ap.add_argument("listing", nargs="?", help="program listing file")
    ap.add_argument("output", nargs="?", help=".p47 output path")
    args = ap.parse_args()
    items = parse_items(args.items)
    if args.selftest:
        sys.exit(1 if selftest(items) else 0)
    if not args.listing or not args.output:
        ap.error("listing and output are required unless --selftest")
    body = assemble_program(open(args.listing, encoding="ascii").read(), items)
    write_p47(body, args.output)
    print(f"p47asm: wrote {args.output} ({len(body)} program bytes + .END.)")


if __name__ == "__main__":
    main()
