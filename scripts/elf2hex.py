#!/usr/bin/env python3
"""elf2hex.py <elf> <out.hex> - flatten an ELF linked at 0x8000_0000 into a
$readmemh word image (little-endian 32-bit words, one per line).
Prints the tohost address (or 0) on stdout."""
import subprocess, sys, tempfile, os

PREFIX = os.environ.get("RISCV_PREFIX", "riscv64-elf-")
BASE = 0x80000000

def main():
    elf, out = sys.argv[1], sys.argv[2]
    with tempfile.TemporaryDirectory() as td:
        binf = os.path.join(td, "img.bin")
        subprocess.check_call([PREFIX + "objcopy", "-O", "binary", elf, binf])
        data = open(binf, "rb").read()
    # objcopy -O binary starts at the lowest loadable address; make sure it's BASE
    syms = subprocess.check_output([PREFIX + "nm", elf], text=True)
    lo = None; tohost = 0
    for line in syms.splitlines():
        parts = line.split()
        if len(parts) == 3:
            if parts[2] == "tohost":
                tohost = int(parts[0], 16)
            if parts[2] == "_start":
                lo = int(parts[0], 16)
    if lo is not None and lo != BASE:
        sys.exit(f"elf2hex: _start at {lo:#x}, expected {BASE:#x}")
    data += b"\0" * (-len(data) % 4)
    with open(out, "w") as f:
        for i in range(0, len(data), 4):
            f.write("%08x\n" % int.from_bytes(data[i:i+4], "little"))
    print("%08x" % tohost)

if __name__ == "__main__":
    main()
