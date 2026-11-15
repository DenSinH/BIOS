#!/usr/bin/env python3
"""Compare two swi-trace.lua logs: same SWI + same inputs -> same outputs?

usage: swi-compare.py REFERENCE.log OURS.log [--swi 0x0A,0x09] [--all-regs] [--limit N]

Calls are matched on (SWI number, r0-r3 before the call), not on their position
in the log, so the two runs may diverge in order or length without producing noise.

Only "pure" SWIs (inputs are plain values, not pointers) are compared by default,
because for pointer-based SWIs (CpuSet, LZ77, BgAffineSet, ...) the same r0-r3 can
legitimately mean different memory contents.  Override with --swi.

By default only the registers a SWI is documented to return are compared; the real
BIOS leaves other registers with unspecified values.  --all-regs compares r0-r12.
"""
import argparse
import re
import sys
from collections import defaultdict

# SWI -> registers that carry the documented result
OUTPUTS = {
    0x06: (0, 1, 3),  # Div:     quotient, remainder, abs(quotient)
    0x07: (0, 1, 3),  # DivArm
    0x08: (0,),       # Sqrt
    0x09: (0,),       # ArcTan
    0x0A: (0,),       # ArcTan2
}
DEFAULT_SWIS = set(OUTPUTS)

HEADER = re.compile(r"^#(\d+) SWI 0x([0-9A-Fa-f]+) (\S+) \[(\w+),")
REGS = re.compile(r"^\s+(before|after)\s+((?:r\d+=[0-9A-Fa-f]{8}\s*)+)")


def parse(path):
    calls, cur = [], None
    with open(path) as f:
        for line in f:
            m = HEADER.match(line)
            if m:
                cur = {"num": int(m.group(2), 16), "name": m.group(3),
                       "before": {}, "after": {}}
                calls.append(cur)
                continue
            m = REGS.match(line)
            if m and cur is not None:
                for r, v in re.findall(r"r(\d+)=([0-9A-Fa-f]{8})", m.group(2)):
                    cur[m.group(1)][int(r)] = int(v, 16)
    return [c for c in calls if len(c["before"]) >= 4 and len(c["after"]) >= 4]


def signed(v):
    return v - (1 << 32) if v & 0x80000000 else v


def fmt(vals):
    return " ".join(f"r{r}={v:08X}({signed(v)})" for r, v in vals)


def index(calls, swis, all_regs):
    """(swi, inputs) -> set of output tuples."""
    table = defaultdict(set)
    for c in calls:
        if c["num"] not in swis:
            continue
        regs = tuple(range(13)) if all_regs else OUTPUTS.get(c["num"], (0,))
        key = (c["num"], c["name"], tuple(c["before"][r] for r in range(4)))
        table[key].add(tuple((r, c["after"][r]) for r in regs))
    return table


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("reference")
    ap.add_argument("ours")
    ap.add_argument("--swi", help="comma separated SWI numbers (default: pure SWIs)")
    ap.add_argument("--all-regs", action="store_true", help="compare r0-r12, not only documented outputs")
    ap.add_argument("--limit", type=int, default=20, help="mismatches to print per SWI (default 20)")
    args = ap.parse_args()

    swis = {int(s, 0) for s in args.swi.split(",")} if args.swi else DEFAULT_SWIS
    ref = index(parse(args.reference), swis, args.all_regs)
    ours = index(parse(args.ours), swis, args.all_regs)

    shared = sorted(set(ref) & set(ours))
    stats = defaultdict(lambda: [0, 0])  # name -> [compared, mismatched]
    shown = defaultdict(int)
    bad = 0
    for key in shared:
        num, name, inputs = key
        stats[name][0] += 1
        if ref[key] == ours[key]:
            continue
        stats[name][1] += 1
        bad += 1
        if shown[name] >= args.limit:
            continue
        shown[name] += 1
        print(f"MISMATCH SWI 0x{num:02X} {name}")
        print("  in    :", fmt(enumerate(inputs)))
        for out in sorted(ref[key]):
            print("  ref   :", fmt(out))
        for out in sorted(ours[key]):
            print("  ours  :", fmt(out))

    print()
    for name, (n, m) in sorted(stats.items()):
        print(f"{name:16} compared {n:6} distinct inputs, {m} mismatching")
    only_ref, only_ours = len(set(ref) - set(ours)), len(set(ours) - set(ref))
    print(f"inputs only seen in reference: {only_ref}, only in ours: {only_ours}")
    if not shared:
        print("no shared inputs: did both runs use the same savestate and --swi filter?")
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
