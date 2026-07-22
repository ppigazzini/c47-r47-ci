#!/usr/bin/env python3
"""Audit the coverage corpus patch for common wiring mistakes."""

from __future__ import annotations

import re
import sys
from pathlib import Path


ADDED_TEST_RE = re.compile(r"^diff --git a/src/testSuite/tests/([^\s]+\.txt) b/src/testSuite/tests/\1$")
TEST_LIST_RE = re.compile(r"^diff --git a/src/testSuite/tests/testSuiteList\.txt b/src/testSuite/tests/testSuiteList\.txt$")


def collect_patch_facts(lines: list[str]) -> tuple[set[str], set[str]]:
    added_tests: set[str] = set()
    listed_tests: set[str] = set()
    in_test_list = False

    for line in lines:
        if TEST_LIST_RE.match(line):
            in_test_list = True
            continue

        test_match = ADDED_TEST_RE.match(line)
        if test_match:
            test_file = test_match.group(1)
            if test_file != "testSuiteList.txt":
                added_tests.add(test_file.removesuffix(".txt"))
            in_test_list = False
            continue

        if line.startswith("diff --git "):
            in_test_list = False
            continue

        if in_test_list and line.startswith("+") and not line.startswith("+++"):
            entry = line[1:].strip()
            # testSuiteList.txt comments start with ';', not '#'.
            if entry and not entry.startswith(("#", ";")):
                listed_tests.add(entry)

    return added_tests, listed_tests


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print(f"usage: {Path(argv[0]).name} COVERAGE_PATCH", file=sys.stderr)
        return 2

    patch = Path(argv[1])
    lines = patch.read_text(encoding="utf-8", errors="replace").splitlines()
    added_tests, listed_tests = collect_patch_facts(lines)
    missing = sorted(added_tests - listed_tests)

    print("Coverage patch audit")
    print(f"added coverage tests: {len(added_tests)}")
    print(f"testSuiteList additions: {len(listed_tests)}")

    if missing:
        print("missing from testSuiteList:")
        for test in missing:
            print(f"  {test}")
        return 1

    print("all added coverage tests are listed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
