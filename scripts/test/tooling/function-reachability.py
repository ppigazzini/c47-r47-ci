#!/usr/bin/env python3
"""Report c43 testSuite direct function reachability."""

from __future__ import annotations

import re
import sys
from pathlib import Path


FUNC_TABLE_RE = re.compile(
    r"const\s+funcTest_t\s+funcTestNoParam\s*\[\s*\]\s*=\s*\{(?P<body>.*?)\n\};",
    re.DOTALL,
)
FUNC_ENTRY_RE = re.compile(r"\{\s*\"(?P<name>[^\"]+)\"\s*,")
LAST_ITEM_RE = re.compile(r"(?:#\s*define\s+LAST_ITEM\s+|\bLAST_ITEM\s*=\s*)(\d+)")


def read_text(path: Path) -> str:
    return path.read_text(encoding="utf-8", errors="replace")


def count_registered_functions(upstream_dir: Path) -> tuple[int, int, Path]:
    suite = upstream_dir / "src" / "testSuite" / "testSuite.c"
    text = read_text(suite)
    match = FUNC_TABLE_RE.search(text)
    if not match:
        raise ValueError(f"funcTestNoParam[] not found in {suite}")

    names = FUNC_ENTRY_RE.findall(match.group("body"))
    return len(names), len(set(names)), suite


def find_last_item(upstream_dir: Path) -> tuple[int | None, Path | None]:
    source_root = upstream_dir / "src" / "c47"
    candidates = sorted(source_root.rglob("*.h")) + sorted(source_root.rglob("*.c"))
    for path in candidates:
        text = read_text(path)
        match = LAST_ITEM_RE.search(text)
        if match:
            return int(match.group(1)), path
    return None, None


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print(f"usage: {Path(argv[0]).name} UPSTREAM_DIR", file=sys.stderr)
        return 2

    upstream_dir = Path(argv[1])
    registered, unique_registered, suite = count_registered_functions(upstream_dir)
    last_item, last_item_source = find_last_item(upstream_dir)

    print("Function reachability")
    print(f"registered testSuite functions: {registered}")
    print(f"unique registered functions: {unique_registered}")
    print(f"registered source: {suite.relative_to(upstream_dir)}")

    if last_item is None or last_item_source is None:
        print("catalog items: unknown")
        print("direct function reachability: unknown")
        print("catalog source: LAST_ITEM not found under src/c47")
        return 0

    percent = unique_registered * 100 / last_item if last_item else 0
    unreachable = max(last_item - unique_registered, 0)
    print(f"catalog items: {last_item}")
    print(f"catalog source: {last_item_source.relative_to(upstream_dir)}")
    print(f"unregistered catalog items: {unreachable}")
    print(f"direct function reachability: {percent:.2f}%")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
