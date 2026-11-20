#!/usr/bin/env python3
"""cmp_commit.py <spike.log> <rtl.trace> [tohost_hex] - lock-step compare of retired
instructions. Compares PC, instruction word, GPR write (x1..x31) and memory
access (address, and store data). Spike boot-ROM lines (pc < 0x8000_0000) and
CSR-write annotations are ignored. Prints the first mismatch with context and
exits 1, or prints the number of instructions matched and exits 0."""
import re, sys

LINE = re.compile(r"core\s+\d+:\s+(\d)\s+0x([0-9a-f]+)\s+\(0x([0-9a-f]+)\)(.*)")

def parse(path, skip_boot):
    out = []
    with open(path, errors="replace") as f:
        for raw in f:
            m = LINE.match(raw)
            if not m:
                continue
            pc = int(m.group(2), 16)
            if skip_boot and pc < 0x80000000:
                continue
            toks = m.group(4).split()
            rd = None; mem = None
            i = 0
            while i < len(toks):
                t = toks[i]
                if re.fullmatch(r"x\d+", t):
                    n = int(t[1:]); v = int(toks[i + 1], 16); i += 2
                    if n != 0:
                        rd = (n, v)
                elif t == "mem":
                    addr = int(toks[i + 1], 16); i += 2
                    data = None
                    if i < len(toks) and toks[i].startswith("0x"):
                        data = int(toks[i], 16); i += 1
                    mem = (addr, data)
                else:
                    i += 2 if i + 1 < len(toks) and toks[i + 1].startswith("0x") else 1
            out.append((pc, int(m.group(3), 16), rd, mem, raw.rstrip()))
    return out

def cut_at_tohost(tr, tohost):
    """Keep everything up to and including the first store to tohost."""
    for i, t in enumerate(tr):
        if t[3] is not None and t[3][1] is not None and t[3][0] == tohost:
            return tr[:i + 1]
    return tr

def main():
    spike = parse(sys.argv[1], True)
    rtl = parse(sys.argv[2], False)
    if len(sys.argv) > 3:
        th = int(sys.argv[3], 16)
        spike, rtl = cut_at_tohost(spike, th), cut_at_tohost(rtl, th)
    n = min(len(spike), len(rtl))
    for i in range(n):
        if spike[i][:4] != rtl[i][:4]:
            print(f"MISMATCH at retired instruction #{i}")
            for j in range(max(0, i - 5), i):
                print("   ok   " + rtl[j][4])
            print("  spike  " + spike[i][4])
            print("  rtl    " + rtl[i][4])
            sys.exit(1)
    if len(spike) != len(rtl):
        print(f"LENGTH MISMATCH: spike={len(spike)} rtl={len(rtl)} (first {n} match)")
        sys.exit(1)
    print(f"MATCH {n}")

if __name__ == "__main__":
    main()
