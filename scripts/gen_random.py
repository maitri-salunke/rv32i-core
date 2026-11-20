#!/usr/bin/env python3
"""gen_random.py <seed> <out.S> [--body N] [--outer K]

Constrained-random RV32I_Zicsr program generator aimed at pipeline hazards.
Each program is self-checking only through the Spike commit-log comparison:
it never needs to know the expected result.

Hazard-oriented features:
  * a small "hot" register set per program, so most instructions depend on
    the previous one or two (EX->EX and MEM->EX forwarding, WB->ID bypass)
  * loads immediately consumed (load-use interlock), load->store data,
    store->load to the same address, back-to-back loads into the same rd
  * address arithmetic fed by forwarded values (andi/add/lw chains)
  * forward branches and JAL/JALR (auipc/addi/jalr dependency chains),
    bounded backward loops
  * CSR read-modify-write on mscratch with immediate and register forms,
    and minstret/minstreth reads (cleared at start so Spike and RTL agree)
  * code pointers through memory (store -> load -> jalr)
  * synchronous traps (ECALL, EBREAK, illegal opcode, misaligned load/store/
    jump target); the handler reads mcause/mepc/mtval, skips the faulting
    instruction (mepc += 4) and MRETs
With --mix branch the menu is weighted toward control flow aimed at the ID
predecode (JAL / backward-taken, forward-not-taken) and its EX correction:
  * bounded data-dependent backward branches (all six conditions), also
    right after a load (load-use stall while ID holds a predicted branch)
  * backward branches that are never taken (predicted taken, corrected in EX)
  * backward JALs and back-to-back JAL chains (a jump at a jump target)
  * JAL / backward-branch encodings with a 2-byte-misaligned target (ID
    redirects to the misaligned PC; EX must trap or correct it)
  * a jump directly behind a trapping instruction (EX trap vs ID prediction)
The whole random body is wrapped in an outer loop so register values evolve
and branch outcomes vary from iteration to iteration.

Reserved registers: x28 trap scratch, x29 inner-loop counter,
x30 outer-loop counter, x31 data-buffer base.
"""
import argparse, random

POOL = list(range(1, 28))
BUF_BYTES = 4096

ALU_RR = ["add", "sub", "sll", "slt", "sltu", "xor", "srl", "sra", "or", "and"]
ALU_RI = ["addi", "slti", "sltiu", "xori", "ori", "andi"]
SHIFT_I = ["slli", "srli", "srai"]
BR = ["beq", "bne", "blt", "bge", "bltu", "bgeu"]
LOADS = [("lb", 1), ("lbu", 1), ("lh", 2), ("lhu", 2), ("lw", 4)]
STORES = [("sb", 1), ("sh", 2), ("sw", 4)]


class Gen:
    def __init__(self, seed, body, outer, mix="default"):
        self.r = random.Random(seed)
        self.body, self.outer, self.mix = body, outer, mix
        self.lbl = 0
        self.out = []
        hot_n = self.r.randint(3, 7)
        self.hot = self.r.sample(POOL, hot_n)

    def reg(self, allow_x0=False):
        r = self.r
        if allow_x0 and r.random() < 0.03:
            return 0
        return r.choice(self.hot) if r.random() < 0.8 else r.choice(POOL)

    def label(self):
        self.lbl += 1
        return f"L{self.lbl}"

    def emit(self, s):
        self.out.append("    " + s)

    def imm12(self):
        r = self.r.random()
        if r < 0.3:
            return self.r.randint(-16, 16)
        if r < 0.4:
            return self.r.choice([-2048, 2047, -1, 0, 1])
        return self.r.randint(-2048, 2047)

    # ---------------------------------------------------------------- pieces
    def alu(self):
        r = self.r.random()
        if r < 0.45:
            self.emit(f"{self.r.choice(ALU_RR)} x{self.reg(True)}, x{self.reg()}, x{self.reg()}")
        elif r < 0.8:
            self.emit(f"{self.r.choice(ALU_RI)} x{self.reg(True)}, x{self.reg()}, {self.imm12()}")
        elif r < 0.92:
            self.emit(f"{self.r.choice(SHIFT_I)} x{self.reg(True)}, x{self.reg()}, {self.r.randint(0, 31)}")
        elif r < 0.96:
            self.emit(f"lui x{self.reg(True)}, {self.r.randint(0, 0xfffff)}")
        else:
            self.emit(f"auipc x{self.reg(True)}, {self.r.randint(0, 0xfffff)}")

    def mem_off(self, size):
        return self.r.randrange(0, 2048 - 8, size)

    def load(self, rd=None):
        op, size = self.r.choice(LOADS)
        rd = self.reg(True) if rd is None else rd
        self.emit(f"{op} x{rd}, {self.mem_off(size)}(x31)")
        return rd

    def store(self):
        op, size = self.r.choice(STORES)
        self.emit(f"{op} x{self.reg()}, {self.mem_off(size)}(x31)")

    def load_use(self):
        rd = self.load(self.reg())
        r = self.r.random()
        if r < 0.5:
            self.emit(f"{self.r.choice(ALU_RR)} x{self.reg(True)}, x{rd}, x{self.reg()}")
        elif r < 0.7:
            op, size = self.r.choice(STORES)
            self.emit(f"{op} x{rd}, {self.mem_off(size)}(x31)")       # load -> store data
        elif r < 0.85:
            self.emit(f"{self.r.choice(BR)} x{rd}, x{self.reg()}, 1f")  # load -> branch
            self.emit(f"{self.r.choice(ALU_RI)} x{self.reg(True)}, x{rd}, {self.imm12()}")
            self.out.append("1:")
        else:
            self.load(rd)                                               # back-to-back loads, same rd
            self.emit(f"add x{self.reg(True)}, x{rd}, x{rd}")

    def st_ld_same(self):
        op, size = self.r.choice(STORES)
        off = self.mem_off(4)
        self.emit(f"{op} x{self.reg()}, {off}(x31)")
        lop = self.r.choice([l for l, s in LOADS if s <= size])
        self.emit(f"{lop} x{self.reg(True)}, {off}(x31)")

    def addr_chain(self):
        # address computed from a forwarded value, then used immediately
        op, size = self.r.choice(LOADS + STORES)
        t = self.reg()
        mask = 0x7fc if size == 4 else (0x7fe if size == 2 else 0x7ff)
        self.emit(f"andi x{t}, x{self.reg()}, {mask}")
        self.emit(f"add x{t}, x{t}, x31")
        if op.startswith("s"):
            self.emit(f"{op} x{self.reg()}, 0(x{t})")
        else:
            self.emit(f"{op} x{self.reg(True)}, 0(x{t})")

    def branch_fwd(self):
        l = self.label()
        self.emit(f"{self.r.choice(BR)} x{self.reg()}, x{self.reg()}, {l}")
        for _ in range(self.r.randint(0, 3)):
            self.alu()
        self.out.append(f"{l}:")

    def jal_fwd(self):
        l = self.label()
        self.emit(f"jal x{self.reg(True)}, {l}")
        for _ in range(self.r.randint(0, 2)):
            self.alu()
        self.out.append(f"{l}:")

    def jalr_fwd(self):
        l = self.label()
        t = self.reg()
        self.emit(f"la x{t}, {l}")                 # auipc + addi -> jalr chain
        self.emit(f"jalr x{self.reg(True)}, 0(x{t})")
        for _ in range(self.r.randint(0, 2)):
            self.alu()
        self.out.append(f"{l}:")

    def rd_instret(self):
        self.emit(f"csrr x{self.reg()}, {self.r.choice(['minstret', 'minstret', 'minstreth'])}")

    def load_jalr(self):
        # code pointer through memory: store -> load -> jalr (load-use into jalr)
        l = self.label()
        t, u = self.reg(), self.reg()
        off = self.mem_off(4)
        self.emit(f"la x{t}, {l}")
        self.emit(f"sw x{t}, {off}(x31)")
        self.emit(f"lw x{u}, {off}(x31)")
        self.emit(f"jalr x{self.reg(True)}, 0(x{u})")
        for _ in range(self.r.randint(0, 2)):
            self.alu()
        self.out.append(f"{l}:")

    def trap_then_use(self):
        # misaligned load traps in EX while its consumer sits in ID (load-use
        # interlock must yield to the redirect)
        rd = self.reg()
        self.emit(f"lw x{rd}, {self.mem_off(4) + 2}(x31)   # misaligned, traps")
        self.emit(f"add x{self.reg(True)}, x{rd}, x{rd}")

    def loop(self):
        l = self.label()
        self.emit(f"li x29, {self.r.randint(1, 6)}")
        self.out.append(f"{l}:")
        for _ in range(self.r.randint(1, 5)):
            self.r.choice([self.alu, self.alu, self.load_use, self.store])()
        self.emit("addi x29, x29, -1")
        self.emit(f"bnez x29, {l}")

    def csr(self):
        r = self.r.random()
        if r < 0.5:
            op = self.r.choice(["csrrw", "csrrs", "csrrc"])
            self.emit(f"{op} x{self.reg(True)}, mscratch, x{self.reg(True)}")
        elif r < 0.8:
            op = self.r.choice(["csrrwi", "csrrsi", "csrrci"])
            self.emit(f"{op} x{self.reg(True)}, mscratch, {self.r.randint(0, 31)}")
        elif r < 0.9:
            self.emit(f"csrr x{self.reg()}, {self.r.choice(['mepc', 'mcause', 'mtval', 'mscratch'])}")
        else:
            # instret read in EX must equal the number of older retired instructions
            self.emit(f"csrr x{self.reg()}, {self.r.choice(['minstret', 'minstreth'])}")

    def trap(self):
        r = self.r.random()
        if r < 0.25:
            self.emit("ecall")
        elif r < 0.4:
            self.emit("ebreak")
        elif r < 0.55:
            self.emit(".word 0x00000000            # illegal")
        elif r < 0.65:
            self.emit("csrr x5, 0x7c0              # unimplemented CSR -> illegal")
        elif r < 0.8:
            op, size = self.r.choice([("lw", 4), ("lh", 2), ("lhu", 2), ("sw", 4), ("sh", 2)])
            off = self.mem_off(4) + self.r.choice([1, 3] if size == 4 else [1])
            if op.startswith("s"):
                self.emit(f"{op} x{self.reg()}, {off}(x31)   # misaligned store")
            else:
                self.emit(f"{op} x{self.reg()}, {off}(x31)   # misaligned load")
        else:
            # taken jump to a 2-byte-aligned target -> instruction-address-misaligned
            t = self.reg()
            l = self.label()
            self.emit(f"la x{t}, {l}")
            self.emit(f"addi x{t}, x{t}, 2")
            self.emit(f"jalr x{self.reg(True)}, 0(x{t})   # misaligned target")
            self.out.append(f"{l}:")
            self.emit("nop")

    # ------------------------------------------------- branch-heavy pieces
    @staticmethod
    def enc_b(funct3, rs1, rs2, imm):
        i = imm & 0x1FFF
        return (((i >> 12) & 1) << 31 | ((i >> 5) & 0x3F) << 25 | rs2 << 20 | rs1 << 15 |
                funct3 << 12 | ((i >> 1) & 0xF) << 8 | ((i >> 11) & 1) << 7 | 0x63)

    @staticmethod
    def enc_j(rd, imm):
        i = imm & 0x1FFFFF
        return (((i >> 20) & 1) << 31 | ((i >> 1) & 0x3FF) << 21 | ((i >> 11) & 1) << 20 |
                ((i >> 12) & 0xFF) << 12 | rd << 7 | 0x6F)

    def back_branch(self):
        # bounded data-dependent backward branch: at most k iterations
        l, lx = self.label(), self.label()
        self.emit(f"li x29, {self.r.randint(1, 5)}")
        self.out.append(f"{l}:")
        for _ in range(self.r.randint(0, 3)):
            self.r.choice([self.alu, self.alu, self.load_use])()
        self.emit("addi x29, x29, -1")
        self.emit(f"beqz x29, {lx}")
        if self.r.random() < 0.3:
            rd = self.load(self.reg())                # load -> backward branch (load-use)
            self.emit(f"{self.r.choice(BR)} x{rd}, x{self.reg()}, {l}")
        else:
            self.emit(f"{self.r.choice(BR)} x{self.reg(True)}, x{self.reg(True)}, {l}")
        self.out.append(f"{lx}:")

    def back_never(self):
        # backward branch that is never taken: predicted taken, EX corrects
        l = self.label()
        self.out.append(f"{l}:")
        for _ in range(self.r.randint(0, 2)):
            self.alu()
        r = self.reg()
        op = self.r.choice([f"bne x0, x0", f"blt x{r}, x{r}", f"bltu x{r}, x{r}", f"bne x{r}, x{r}"])
        self.emit(f"{op}, {l}")

    def jal_chain(self):
        # j over -> back: (jal) -> jal -> cont ; back-to-back predicted jumps
        lo, lb, lc = self.label(), self.label(), self.label()
        self.emit(f"jal x{self.reg(True)}, {lo}")
        self.out.append(f"{lb}:")
        for _ in range(self.r.randint(0, 2)):
            self.alu()
        self.emit(f"jal x{self.reg(True)}, {lc}")
        self.out.append(f"{lo}:")
        if self.r.random() < 0.5:
            self.emit(f"jal x{self.reg(True)}, {lb}")   # jump at a jump target, backward
        else:
            self.emit(f"j {lb}")
        self.out.append(f"{lc}:")

    def misaligned_ctl(self):
        # control transfer to pc-2 / pc+6: taken -> insn-address-misaligned trap
        r = self.r.random()
        a, b = self.reg(), self.reg()
        if r < 0.3:
            w = self.enc_j(self.reg(True), -2)
            self.emit(f".word 0x{w:08x}            # jal rd, -2 (misaligned, traps)")
        elif r < 0.65:
            f3 = self.r.choice([0, 1, 4, 5, 6, 7])
            w = self.enc_b(f3, a, b, -2)
            self.emit(f".word 0x{w:08x}            # backward branch to pc-2")
        else:
            f3 = self.r.choice([0, 1, 4, 5, 6, 7])
            w = self.enc_b(f3, a, b, 6)
            self.emit(f".word 0x{w:08x}            # forward branch to pc+6")
            self.emit("nop")
            self.emit("nop")

    def trap_then_jump(self):
        # trapping instruction in EX while ID predicts a jump behind it
        self.r.choice([lambda: self.emit("ecall"), lambda: self.emit("ebreak"),
                       lambda: self.emit(".word 0x00000000            # illegal")])()
        if self.r.random() < 0.5:
            self.jal_fwd()
        else:
            self.back_never()

    # ---------------------------------------------------------------- program
    def program(self):
        o = self.out
        o += [".section .text.init", ".globl _start", "_start:",
              "    la x28, trap_handler", "    csrw mtvec, x28",
              "    la x31, buf"]
        for rr in POOL:
            self.emit(f"li x{rr}, 0x{self.r.getrandbits(32):08x}")
        self.emit("csrw minstret, zero")
        self.emit("csrw minstreth, zero")
        self.emit(f"li x30, {self.outer}")
        o.append("outer:")
        if self.mix == "branch":
            menu = ([self.alu] * 20 + [self.load_use] * 6 + [self.load] * 2 + [self.store] * 3 +
                    [self.addr_chain] * 2 + [self.branch_fwd] * 10 + [self.jal_fwd] * 4 +
                    [self.jalr_fwd] * 2 + [self.loop] * 3 + [self.csr] * 1 + [self.trap] * 1 +
                    [self.load_jalr] * 1 + [self.back_branch] * 8 + [self.back_never] * 4 +
                    [self.jal_chain] * 4 + [self.misaligned_ctl] * 2 + [self.trap_then_jump] * 2)
        else:
            menu = ([self.alu] * 30 + [self.load_use] * 10 + [self.load] * 4 + [self.store] * 6 +
                    [self.st_ld_same] * 4 + [self.addr_chain] * 5 + [self.branch_fwd] * 8 +
                    [self.jal_fwd] * 2 + [self.jalr_fwd] * 2 + [self.loop] * 2 + [self.csr] * 3 +
                    [self.trap] * 2 + [self.load_jalr] * 1 + [self.trap_then_use] * 1 +
                    [self.rd_instret] * 1)
        n0 = len(o)
        while len(o) - n0 < self.body:
            self.r.choice(menu)()
        self.emit("addi x30, x30, -1")
        self.emit("beqz x30, done")
        self.emit("j outer")
        o += ["done:",
              "    li x28, 1",
              "    la x29, tohost",
              "    sw x28, 0(x29)",
              "1:  j 1b",
              "",
              ".align 2",
              "trap_handler:",
              "    csrr x28, mcause",
              "    csrr x28, mtval",
              "    csrr x28, mepc",
              "    addi x28, x28, 4",
              "    csrw mepc, x28",
              "    mret",
              "",
              ".section .tohost, \"aw\", @progbits",
              ".align 6",
              ".globl tohost",
              "tohost: .dword 0",
              ".align 6",
              ".globl fromhost",
              "fromhost: .dword 0",
              ".section .data",
              ".align 6",
              f"buf: .fill {BUF_BYTES // 4}, 4, 0x5a5aa5a5"]
        return "\n".join(o) + "\n"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("seed", type=int)
    ap.add_argument("out")
    ap.add_argument("--body", type=int, default=1200)
    ap.add_argument("--outer", type=int, default=40)
    ap.add_argument("--mix", choices=["default", "branch"], default="default")
    a = ap.parse_args()
    with open(a.out, "w") as f:
        f.write(Gen(a.seed, a.body, a.outer, a.mix).program())


if __name__ == "__main__":
    main()
