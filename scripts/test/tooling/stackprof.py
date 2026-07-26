#!/usr/bin/env python3
"""Bound the C stack a c47 firmware entry point can reach, from its disassembly.

Reports, per root symbol, an upper bound on bytes of C stack over the direct-call graph, the chain that reaches it, and every reason the
bound could be exceeded anyway. Cross-checks its own frame extraction against `gcc -fstack-usage` when the build tree is available, so a
wrong number fails loudly instead of reading as a measurement.

Functions are keyed by address, never by name: three GMP statics share a name inside one DM42 ELF, and branch targets carry an offset
(`<fn+0x16>`) that only an address resolves. The same lookup separates an internal branch from a tail call.
"""

from __future__ import annotations

import argparse
import bisect
import json
import os
import re
import subprocess
import sys
from pathlib import Path

SYMBOL_RE = re.compile(r"^([0-9a-f]+) <(.+)>:$")
# objdump expands core register lists (`push {r4, r5, lr}`) but prints VFP lists as ranges (`vpush {d8-d13}`); expand_reglist() takes both.
PUSH_RE = re.compile(r"\t(?:push(?:\.w)?|stmdb\s+sp!,)\s+\{([^}]*)\}")
VPUSH_RE = re.compile(r"\t(?:vpush(?:\.w)?|vstmdb\s+sp!,)\s+\{([^}]*)\}")
SUB_SP_IMM_RE = re.compile(r"\tsub(?:\.w|w)?\s+sp,\s*(?:sp,\s*)?#(\d+)")
SUB_SP_REG_RE = re.compile(r"\tsub(?:\.w|w)?\s+sp,\s*(?:sp,\s*)?(?:r\d+|ip|sl|fp|sb)\b")
CALL_RE = re.compile(r"\tblx?\s+([0-9a-f]+) <")
INDIRECT_RE = re.compile(r"\tblx?\s+(?:r\d+|ip|lr|sl|fp|sb)\b")
BRANCH_RE = re.compile(r"\tb(?:\.w|\.n)?\s+([0-9a-f]+) <")
LITERAL_RE = re.compile(r"\t\.word\t0x([0-9a-f]+)")
REG_NUM_RE = re.compile(r"\d+")
# GCC clone suffixes: the ELF symbol carries them, the .su line does not, so a clone has no comparable entry and the self-check skips it.
CLONE_SUFFIX_RE = re.compile(r"\.(?:lto_priv|isra|constprop|part|cold|localalias)(?:\.\d+)*$")


def expand_reglist(spec: str) -> int:
    """Count registers in an objdump register list, expanding `d8-d13` style ranges."""
    total = 0
    for part in spec.split(","):
        part = part.strip()
        if not part:
            continue
        if "-" in part:
            low, high = part.split("-", 1)
            low_num, high_num = REG_NUM_RE.search(low), REG_NUM_RE.search(high)
            total += int(high_num.group()) - int(low_num.group()) + 1 if low_num and high_num else 1
        else:
            total += 1
    return total


class Function:
    """One function: its fixed frame, its resolved callees, and the reasons its bound may be incomplete."""

    __slots__ = ("address", "name", "frame", "calls", "tail_calls", "literals", "indirect", "dynamic", "unresolved")

    def __init__(self, address: int, name: str) -> None:
        self.address = address
        self.name = name
        self.frame = 0
        self.calls: set[int] = set()
        self.tail_calls: set[int] = set()
        self.literals: set[int] = set()
        self.indirect = 0
        self.dynamic = 0
        self.unresolved: set[int] = set()

    @property
    def edges(self) -> set[int]:
        """Callees: direct calls, tail calls, and handlers reached through the function's own literal pool.

        A tail call transfers after the epilogue, so charging the target on top of this frame over-approximates by at most that frame.
        Dropping the edge instead loses whole subtrees - the DM42 ELF has 1507 of them, and every `fn*` dispatch wrapper is one, so
        omitting them scores `fnSin` at 0 B.
        """
        return self.calls | self.tail_calls | self.literals


class Program:
    """The address-keyed call graph read out of one disassembly."""

    def __init__(self, functions: dict[int, Function]) -> None:
        self.functions = functions
        self.starts = sorted(functions)
        self.by_name: dict[str, list[int]] = {}
        for address in self.starts:
            self.by_name.setdefault(functions[address].name, []).append(address)

    def cut(self, names: list[str]) -> list[str]:
        """Drop every edge INTO each named function, and report the names that matched.

        A cut is how a bound is recovered from a re-entrant engine: cutting `execProgram` charges one nested evaluation and stops, so a
        root's number becomes cost-per-level and the depth multiplier stays the reader's to apply. It is destructive and deliberate -
        the point is that it appears in the report, unlike a walk that prunes back edges silently and prints a finite number anyway.
        """
        applied = []
        for name in names:
            address = self.resolve(name)
            if address is None:
                continue
            applied.append(name)
            for function in self.functions.values():
                function.calls.discard(address)
                function.tail_calls.discard(address)
                function.literals.discard(address)
        return applied

    def containing(self, address: int) -> int | None:
        """The function that owns `address`, or None when it lies outside every known function."""
        position = bisect.bisect_right(self.starts, address) - 1
        return self.starts[position] if position >= 0 else None

    def resolve(self, name: str) -> int | None:
        """The single address exporting `name`; None when the name is absent or ambiguous."""
        addresses = self.by_name.get(name, [])
        return addresses[0] if len(addresses) == 1 else None


def load_disassembly(path: Path, follow_literals: bool = True) -> Program:
    functions: dict[int, Function] = {}
    raw_calls: dict[int, set[int]] = {}
    raw_branches: dict[int, set[int]] = {}
    raw_literals: dict[int, set[int]] = {}
    current: Function | None = None

    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        symbol = SYMBOL_RE.match(line)
        if symbol:
            address = int(symbol.group(1), 16)
            current = functions.setdefault(address, Function(address, symbol.group(2)))
            for table in (raw_calls, raw_branches, raw_literals):
                table.setdefault(address, set())
            continue
        if current is None:
            continue
        push = PUSH_RE.search(line)
        if push:
            current.frame += 4 * expand_reglist(push.group(1))
            continue
        vpush = VPUSH_RE.search(line)
        if vpush:
            current.frame += 8 * expand_reglist(vpush.group(1))
            continue
        sub_imm = SUB_SP_IMM_RE.search(line)
        if sub_imm:
            current.frame += int(sub_imm.group(1))
            continue
        if SUB_SP_REG_RE.search(line):
            current.dynamic += 1
            continue
        if INDIRECT_RE.search(line):
            current.indirect += 1
            continue
        call = CALL_RE.search(line)
        if call:
            raw_calls[current.address].add(int(call.group(1), 16))
            continue
        branch = BRANCH_RE.search(line)
        if branch:
            raw_branches[current.address].add(int(branch.group(1), 16))
            continue
        literal = LITERAL_RE.search(line)
        if literal:
            raw_literals[current.address].add(int(literal.group(1), 16))

    program = Program(functions)
    for address, function in functions.items():
        for target in raw_calls[address]:
            owner = program.containing(target)
            if owner is None:
                function.unresolved.add(target)
            else:
                # Self-edges are kept for calls: a `bl` to one's own entry is direct recursion, which is exactly what must be reported as
                # unbounded. Branches below are the opposite case - a `b` to one's own entry is a loop, indistinguishable from a self tail
                # call and vastly more common, so it is dropped.
                function.calls.add(owner)
        for target in raw_branches[address]:
            owner = program.containing(target)
            if owner is not None and owner != address:  # An unconditional branch out of the function is a tail call; one inside it is not.
                function.tail_calls.add(owner)
        if not follow_literals:
            continue
        # c47 dispatches per type by loading handler addresses from the caller's own literal pool (`fnSin` -> processRealComplexMonadic-
        # Function with two `.word` handlers). Accept a literal only when it is Thumb-tagged AND lands exactly on a function start, which
        # no plain datum does; the wider dispatch through the `addition[][]`-style tables in .rodata stays unresolved and is reported.
        for value in raw_literals[address]:
            if value & 1 and (value - 1) in functions and (value - 1) != address:
                function.literals.add(value - 1)
    return program


def condense(program: Program) -> tuple[list[list[int]], dict[int, int], list[set[int]]]:
    """Tarjan SCC condensation of the call graph, iterative so a 3000-node chain cannot blow the interpreter stack.

    Returns the components in reverse topological order, the address-to-component map, and the successor sets of the condensation DAG.
    """
    index: dict[int, int] = {}
    low: dict[int, int] = {}
    on_stack: set[int] = set()
    stack: list[int] = []
    components: list[list[int]] = []
    counter = 0

    for root in program.starts:
        if root in index:
            continue
        index[root] = low[root] = counter
        counter += 1
        stack.append(root)
        on_stack.add(root)
        work: list[tuple[int, list[int]]] = [(root, sorted(program.functions[root].edges))]
        while work:
            node, pending = work[-1]
            if pending:
                child = pending.pop()
                if child not in index:
                    index[child] = low[child] = counter
                    counter += 1
                    stack.append(child)
                    on_stack.add(child)
                    work.append((child, sorted(program.functions[child].edges)))
                elif child in on_stack:
                    low[node] = min(low[node], index[child])
                continue
            work.pop()
            if work:
                low[work[-1][0]] = min(low[work[-1][0]], low[node])
            if low[node] == index[node]:
                component = []
                while True:
                    member = stack.pop()
                    on_stack.discard(member)
                    component.append(member)
                    if member == node:
                        break
                components.append(component)

    component_of = {address: i for i, component in enumerate(components) for address in component}
    successors: list[set[int]] = [set() for _ in components]
    for address, function in program.functions.items():
        source = component_of[address]
        for target in function.edges:
            if component_of[target] != source:
                successors[source].add(component_of[target])
    return components, component_of, successors


class Analysis:
    """Worst-case stack per function over the condensation DAG."""

    def __init__(self, program: Program) -> None:
        self.program = program
        self.components, self.component_of, self.successors = condense(program)
        self.recursive = [len(c) > 1 or any(a in program.functions[a].edges for a in c) for c in self.components]
        # One pass through a component costs at most the sum of its frames. A component that is a cycle has no static bound at all and is
        # reported as such; a walk that merely cuts the back edge would report a finite number for an unbounded recursion.
        self.weight = [sum(program.functions[a].frame for a in c) for c in self.components]
        self.cost: list[int] = [0] * len(self.components)
        self.best: list[int | None] = [None] * len(self.components)
        for i in range(len(self.components)):  # Tarjan emits components in reverse topological order, so every successor is already solved.
            best_cost, best_next = 0, None
            for successor in sorted(self.successors[i]):
                if self.cost[successor] > best_cost:
                    best_cost, best_next = self.cost[successor], successor
            self.cost[i] = self.weight[i] + best_cost
            self.best[i] = best_next

    def worst_path(self, root: int) -> dict[str, object]:
        component: int | None = self.component_of[root]
        chain: list[dict[str, object]] = []
        unbounded = False
        indirect = dynamic = 0
        unresolved: set[int] = set()
        while component is not None:
            members = sorted(self.components[component], key=lambda a: -self.program.functions[a].frame)
            unbounded = unbounded or self.recursive[component]
            for address in members:
                function = self.program.functions[address]
                indirect += function.indirect
                dynamic += function.dynamic
                unresolved |= function.unresolved
            chain.append({
                "bytes": self.weight[component],
                "recursive": self.recursive[component],
                "functions": [self.program.functions[a].name for a in members],
            })
            component = self.best[component]
        return {
            "root": self.program.functions[root].name,
            "bytes": self.cost[self.component_of[root]],
            "unbounded": unbounded,
            "indirect_sites": indirect,
            "dynamic_frames": dynamic,
            "unresolved_targets": len(unresolved),
            "chain": chain,
        }


def load_stack_usage(build_dir: Path) -> tuple[dict[str, set[int]], set[str]]:
    """Read every `-fstack-usage` .su file under a build tree: name -> frame sizes, plus the names GCC marks alloca/VLA."""
    sizes: dict[str, set[int]] = {}
    dynamic: set[str] = set()
    for path in build_dir.rglob("*.su"):
        for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
            fields = line.split("\t")
            if len(fields) < 3:
                continue
            name = fields[0].rsplit(":", 1)[-1]
            sizes.setdefault(name, set()).add(int(fields[1]))
            if "dynamic" in fields[2]:
                dynamic.add(name)
    return sizes, dynamic


def self_check(program: Program, build_dir: Path) -> tuple[int, list[tuple[str, int, int]]]:
    """Compare extracted frames against GCC's own numbers.

    Compares only names that are unambiguous on both sides and static on GCC's: a name shared by two functions cannot be attributed, a
    clone's frame is not the original's, and a dynamic frame has no fixed size to compare against.
    """
    sizes, dynamic = load_stack_usage(build_dir)
    mismatches: list[tuple[str, int, int]] = []
    compared = 0
    for name, addresses in program.by_name.items():
        if len(addresses) != 1 or CLONE_SUFFIX_RE.search(name) or name in dynamic:
            continue
        candidates = sizes.get(name)
        if not candidates or len(candidates) != 1:
            continue
        compared += 1
        expected, frame = next(iter(candidates)), program.functions[addresses[0]].frame
        if expected != frame:
            mismatches.append((name, expected, frame))
    return compared, sorted(mismatches, key=lambda row: -abs(row[1] - row[2]))


def read_chains(path: Path, target: str) -> list[tuple[str, int | None, str]]:
    """Parse the chain baseline: `target label ceiling_bytes chain` rows, `#` comments; keep the rows for one target."""
    chains: list[tuple[str, int | None, str]] = []
    for raw in path.read_text(encoding="utf-8").splitlines():
        fields = raw.split("#", 1)[0].split()
        if len(fields) == 4 and fields[0] == target:
            chains.append((fields[1], int(fields[2]), fields[3]))
    return chains


def report_chain(program: Program, spec: str, band: int | None, label: str = "", ceiling: int | None = None) -> tuple[int, bool]:
    """Sum the frames along a named call chain, checking every link is really an edge.

    The per-level cost of a nested evaluation is a specific chain, not a worst path, so it is stated as one. The edge check is the point:
    an inlining change or a refactor upstream silently breaks the chain, and a sum over a chain that no longer exists is a wrong number
    that still looks like a measurement.
    """
    names = [part.strip() for part in spec.split(",") if part.strip()]
    total, ok = 0, True
    print(f"\n-- {label or 'call chain'}: {' -> '.join(names)} --")
    previous: int | None = None
    for name in names:
        address = program.resolve(name)
        if address is None:
            print(f"  {'?':>8}     {name}   [absent or ambiguous in this build]")
            ok = False
            previous = None
            continue
        if previous is not None and address not in program.functions[previous].edges:
            caller = program.functions[previous]
            if caller.indirect:  # c47 dispatches items through `blx`, so a real link can carry no static edge; say which it is.
                print(f"  {'':>8}     ...   [indirect dispatch: {caller.name} reaches {name} through one of its {caller.indirect} blx sites]")
            else:
                print(f"  {'':>8}     ...   [BROKEN LINK: {caller.name} does not call {name}]")
                ok = False
        frame = program.functions[address].frame
        total += frame
        print(f"  {frame:8d} B   {name}")
        previous = address
    notes = []
    if not ok:
        notes.append("CHAIN INVALID - the sum is not a cost")
    if ceiling is not None and total > ceiling:
        notes.append(f"OVER CEILING {ceiling} B")
        ok = False
    if band and total:
        notes.append(f"{band // total} levels fit the {band} B band")
    print(f"  {total:8d} B   TOTAL per level" + (f"   [{'; '.join(notes)}]" if notes else ""))
    return total, ok


def read_roots(path: Path) -> list[tuple[str, str, int | None]]:
    """Parse a roots file: `symbol = budget_bytes  # label` lines, `#` comments, budget optional."""
    roots: list[tuple[str, str, int | None]] = []
    for raw in path.read_text(encoding="utf-8").splitlines():
        body, _, label = raw.partition("#")
        body = body.strip()
        if not body:
            continue
        symbol, _, budget = body.partition("=")
        budget = budget.strip()
        roots.append((symbol.strip(), label.strip() or symbol.strip(), int(budget) if budget else None))
    return roots


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument("--elf", type=Path, help="ELF to disassemble")
    source.add_argument("--dis", type=Path, help="pre-generated `objdump -d` output")
    parser.add_argument("--objdump", default=os.environ.get("OBJDUMP", "arm-none-eabi-objdump"))
    parser.add_argument("--target", default="", help="label for this build, printed in the report")
    parser.add_argument("--su-dir", type=Path, help="build tree holding -fstack-usage .su files; enables the extraction self-check")
    parser.add_argument("--roots", type=Path, help="roots file: `symbol = budget_bytes  # label`")
    parser.add_argument("--root", action="append", default=[], help="extra root symbol (repeatable)")
    parser.add_argument("--band", type=int, help="guaranteed stack band in bytes, flagged beside each root that exceeds it")
    parser.add_argument("--top", type=int, default=15, help="how many largest fixed frames to list")
    parser.add_argument("--depth", type=int, default=12, help="how many chain steps to print per root")
    parser.add_argument("--no-follow-literals", action="store_true", help="drop the literal-pool handler edges every fn* wrapper needs")
    parser.add_argument("--cut", action="append", default=[], help="drop every edge into this symbol, turning a re-entrant engine into a "
                                                                   "per-level cost (repeatable; each cut is printed)")
    parser.add_argument("--chain", action="append", default=[], help="comma-separated call chain to sum and edge-check (repeatable)")
    parser.add_argument("--chains", type=Path, help="chain baseline: `target label ceiling_bytes chain` rows, filtered by --target")
    parser.add_argument("--json", type=Path, help="write the full report here")
    args = parser.parse_args()

    if args.elf:
        dis_path = Path(str(args.elf) + ".dis")
        dis_path.write_text(subprocess.run([args.objdump, "-d", str(args.elf)], check=True, capture_output=True, text=True).stdout,
                            encoding="utf-8")
    else:
        dis_path = args.dis
    program = load_disassembly(dis_path, follow_literals=not args.no_follow_literals)

    label = args.target or dis_path.name
    print(f"== stack profile: {label} ==")
    print(f"functions {len(program.functions)}  call edges {sum(len(f.calls) for f in program.functions.values())}  "
          f"tail-call edges {sum(len(f.tail_calls) for f in program.functions.values())}  "
          f"literal-pool edges {sum(len(f.literals) for f in program.functions.values())}  "
          f"indirect-call sites {sum(f.indirect for f in program.functions.values())}  "
          f"dynamic-frame functions {sum(1 for f in program.functions.values() if f.dynamic)}")

    if args.cut:
        applied = program.cut(args.cut)
        missing = [name for name in args.cut if name not in applied]
        print(f"cuts applied (every edge into these dropped; numbers are per level, not per operation): {', '.join(applied) or 'none'}")
        if missing:
            print(f"CUT NOT FOUND: {', '.join(missing)} - absent or ambiguous in this build", file=sys.stderr)
            return 2

    status = 0
    if args.su_dir:
        compared, mismatches = self_check(program, args.su_dir)
        if compared == 0:
            print("SELF-CHECK: no .su files found - build with -fstack-usage or drop --su-dir", file=sys.stderr)
            status = 2
        elif mismatches:
            print(f"SELF-CHECK FAILED: {len(mismatches)} of {compared} frames disagree with gcc -fstack-usage", file=sys.stderr)
            for name, expected, got in mismatches[:20]:
                print(f"    {name}: gcc {expected} B, extracted {got} B", file=sys.stderr)
            status = 2
        else:
            print(f"self-check: {compared} frames match gcc -fstack-usage exactly")

    chains: list[tuple[str, int | None, str]] = [("call chain", None, spec) for spec in args.chain]
    if args.chains:
        rows = read_chains(args.chains, label)
        if not rows:
            print(f"CHAINS: no rows for target '{label}' in {args.chains}", file=sys.stderr)
            status = 2
        chains += rows
    for chain_label, ceiling, spec in chains:
        if not report_chain(program, spec, args.band, chain_label, ceiling)[1]:
            status = max(status, 1)

    analysis = Analysis(program)

    print("\n-- largest fixed frames --")
    for function in sorted(program.functions.values(), key=lambda f: -f.frame)[:args.top]:
        print(f"  {function.frame:8d} B  {function.name}")

    roots = read_roots(args.roots) if args.roots else []
    roots += [(name, name, None) for name in args.root]
    reports: list[dict[str, object]] = []
    if roots:
        print("\n-- worst-case static stack per root --")
    for symbol, label_text, budget in roots:
        address = program.resolve(symbol)
        if address is None:
            state = "ambiguous" if symbol in program.by_name else "absent"
            print(f"  {state:>10}  {label_text} ({symbol})")
            reports.append({"root": symbol, "label": label_text, "state": state})
            continue
        report = analysis.worst_path(address)
        report["label"] = label_text
        report["budget"] = budget
        reports.append(report)
        notes = []
        if report["unbounded"]:
            notes.append("RECURSIVE - no static bound")
        if report["indirect_sites"]:
            notes.append(f"{report['indirect_sites']} indirect-call sites unresolved")
        if report["dynamic_frames"]:
            notes.append(f"{report['dynamic_frames']} alloca/VLA frames uncounted")
        if args.band and report["bytes"] > args.band:
            notes.append(f"over the {args.band} B band")
        if budget is not None and report["bytes"] > budget:
            notes.append(f"OVER BUDGET {budget} B")
            status = max(status, 1)
        print(f"  {report['bytes']:10d} B  {label_text}" + (f"   [{'; '.join(notes)}]" if notes else ""))
        for step in report["chain"][:args.depth]:
            extra = f" (+{len(step['functions']) - 1} more in cycle)" if step["recursive"] else ""
            print(f"       {step['bytes']:8d}  {step['functions'][0]}{extra}")

    if args.json:
        args.json.write_text(json.dumps({"target": label, "roots": reports}, indent=2), encoding="utf-8")
    return status


if __name__ == "__main__":
    sys.exit(main())
