#!/usr/bin/env python3
"""Summarize gcovr JSON coverage by c43 macro sector."""

from __future__ import annotations

import json
import sys
from collections.abc import Iterable
from pathlib import Path


SECTORS: tuple[tuple[str, tuple[str, ...]], ...] = (
    ("core math", ("/mathematics/", "/conversions/", "/distributions/")),
    ("matrix", ("/matrix.c", "/matrix/")),
    ("solver / graph", ("/solver/", "/graph/")),
    ("programming / cli", ("/programming/", "/registers.c", "/items.c")),
    ("serializers", ("saveRestore", "save_restore", "/io/")),
    ("strings / alpha", ("/stringFuncs.c", "/alpha", "/strings/")),
    ("input / editors", ("/bufferize.c", "/keyboard.c", "/tam.c", "/matrixEditor.c", "/editor")),
    ("ui / display / printing", ("/screen.c", "/display.c", "/softmenus.c", "/printing/", "/menus/")),
    ("addons / dmcp", ("/c47Extensions/", "/addons.c", "/dmcp")),
)


def normalized_name(filename: str) -> str:
    return "/" + filename.replace("\\", "/").lstrip("/")


def line_totals(file_entry: dict[str, object]) -> tuple[int, int]:
    total = int(file_entry.get("line_total", file_entry.get("lines", 0)) or 0)
    covered_value = file_entry.get("line_covered", file_entry.get("lines_covered"))
    if covered_value is not None:
        covered = int(covered_value)
    else:
        percent = float(file_entry.get("line_percent", 0) or 0)
        covered = round(total * percent / 100)
    return covered, total


def matches_sector(filename: str, needles: Iterable[str]) -> bool:
    name = normalized_name(filename)
    return any(needle in name for needle in needles)


def load_floors(path: str) -> dict[str, float]:
    """Parse a floors file: `sector name = min_percent` lines, `#` comments.

    The special key `GLOBAL` gates the overall matched-sector line percentage.
    """
    floors: dict[str, float] = {}
    for raw in Path(path).read_text(encoding="utf-8").splitlines():
        line = raw.split("#", 1)[0].strip()
        if not line or "=" not in line:
            continue
        key, _, value = line.partition("=")
        floors[key.strip()] = float(value.strip())
    return floors


def main(argv: list[str]) -> int:
    if not 2 <= len(argv) <= 3:
        print(f"usage: {Path(argv[0]).name} COVERAGE_JSON [FLOORS_FILE]", file=sys.stderr)
        return 2

    floors = load_floors(argv[2]) if len(argv) == 3 else {}

    data = json.loads(Path(argv[1]).read_text(encoding="utf-8"))
    files = data.get("files", [])

    print("Macro sector coverage")
    print("sector | files | covered lines | total lines | line %")
    print("-------|-------|---------------|-------------|-------")

    covered_all = 0
    total_all = 0
    matched_files: set[str] = set()
    sector_percent: dict[str, float] = {}

    for sector, needles in SECTORS:
        sector_covered = 0
        sector_total = 0
        sector_files = 0
        for file_entry in files:
            filename = str(file_entry.get("filename", ""))
            if not matches_sector(filename, needles):
                continue
            covered, total = line_totals(file_entry)
            sector_covered += covered
            sector_total += total
            sector_files += 1
            matched_files.add(filename)
        percent = (sector_covered * 100 / sector_total) if sector_total else 0
        sector_percent[sector] = percent
        covered_all += sector_covered
        total_all += sector_total
        print(f"{sector} | {sector_files} | {sector_covered} | {sector_total} | {percent:.2f}%")

    unmatched_covered = 0
    unmatched_total = 0
    unmatched_files = 0
    for file_entry in files:
        filename = str(file_entry.get("filename", ""))
        if filename in matched_files:
            continue
        covered, total = line_totals(file_entry)
        unmatched_covered += covered
        unmatched_total += total
        unmatched_files += 1

    unmatched_percent = (unmatched_covered * 100 / unmatched_total) if unmatched_total else 0
    total_percent = (covered_all * 100 / total_all) if total_all else 0
    sector_percent["GLOBAL"] = total_percent
    print(f"other c47 | {unmatched_files} | {unmatched_covered} | {unmatched_total} | {unmatched_percent:.2f}%")
    print(f"matched total | {len(matched_files)} | {covered_all} | {total_all} | {total_percent:.2f}%")

    if not floors:
        return 0

    # Gate: fail if any sector with a configured floor is below it. An unknown
    # floor key (typo, renamed sector) is also a failure so the config cannot
    # silently gate nothing.
    print("\nSector gate (floor -> actual)")
    failures: list[str] = []
    for key, floor in sorted(floors.items()):
        actual = sector_percent.get(key)
        if actual is None:
            print(f"  {key}: FAIL (no such sector; check the floors file)")
            failures.append(key)
            continue
        status = "ok" if actual + 1e-9 >= floor else "FAIL"
        print(f"  {key}: {floor:.2f}% floor, {actual:.2f}% actual -> {status}")
        if status == "FAIL":
            failures.append(key)

    if failures:
        print(f"\nSECTOR GATE FAILED: {len(failures)} sector(s) below floor: {', '.join(failures)}")
        return 1
    print("\nSECTOR GATE PASSED")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
