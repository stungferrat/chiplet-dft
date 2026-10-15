"""
gen_tests.py -- test-vector generator + reference model for the RV32I core.

The reference model (class ISS) is written from the RISC-V spec, NOT from the
RTL. It executes each test program and records the final register file and
SRAM contents. The Verilog testbench (../tb/tb_core_verify.v) runs the same
program on the DUT and compares against these expectations.

Supported subset (what the core decodes):
  R-type : ADD SUB AND OR XOR SLT SLL SRL SRA
  I-type : ADDI ANDI ORI XORI SLTI SLLI SRLI SRAI
  LW, SW, BEQ, BNE, JAL
Every other instruction word executes as a NOP (no register write, no
memory access, PC + 4), in the model and in the RTL.
Memory model: word-addressed 256 x 32 SRAM indexed by addr[9:2] (byte
address bits 1:0 ignored, addresses above 1023 alias) -- this is how the
system is built, so the model does the same.

Every program ends in "JAL x0, 0" (jump-to-self). Without it, the PC would
run through the trailing NOPs, wrap at 1024 bytes back to address 0 and
re-execute the program, corrupting the final state.

Usage:  python gen_tests.py [num_random] [seed]
Output: vectors/*.hex  and  vectors/manifest.txt
"""
import os, random, sys

MASK = 0xFFFFFFFF
NOP = 0x00000013
HALT = None  # filled in below once jal() exists


def sext(v, bits):
    v &= (1 << bits) - 1
    return v - (1 << bits) if v >> (bits - 1) else v


def s32(v):
    return sext(v, 32)


# ------------------------------------------------------------------
# Assembler
# ------------------------------------------------------------------
def r_type(f7, rs2, rs1, f3, rd):
    return (f7 << 25) | (rs2 << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | 0x33

def i_type(imm, rs1, f3, rd, op=0x13):
    return ((imm & 0xFFF) << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | op

def add(rd, a, b):  return r_type(0x00, b, a, 0, rd)
def sub(rd, a, b):  return r_type(0x20, b, a, 0, rd)
def sll(rd, a, b):  return r_type(0x00, b, a, 1, rd)
def slt(rd, a, b):  return r_type(0x00, b, a, 2, rd)
def xor(rd, a, b):  return r_type(0x00, b, a, 4, rd)
def srl(rd, a, b):  return r_type(0x00, b, a, 5, rd)
def sra(rd, a, b):  return r_type(0x20, b, a, 5, rd)
def or_(rd, a, b):  return r_type(0x00, b, a, 6, rd)
def and_(rd, a, b): return r_type(0x00, b, a, 7, rd)

def addi(rd, a, imm): return i_type(imm, a, 0, rd)
def slti(rd, a, imm): return i_type(imm, a, 2, rd)
def xori(rd, a, imm): return i_type(imm, a, 4, rd)
def ori(rd, a, imm):  return i_type(imm, a, 6, rd)
def andi(rd, a, imm): return i_type(imm, a, 7, rd)
def slli(rd, a, sh):  return i_type(sh & 31, a, 1, rd)
def srli(rd, a, sh):  return i_type(sh & 31, a, 5, rd)
def srai(rd, a, sh):  return i_type((0x20 << 5) | (sh & 31), a, 5, rd)

def lw(rd, base, imm): return i_type(imm, base, 2, rd, op=0x03)

def sw(src, base, imm):
    imm &= 0xFFF
    return ((imm >> 5) << 25) | (src << 20) | (base << 15) | (2 << 12) | ((imm & 31) << 7) | 0x23

def _b(f3, a, b, off):
    off &= 0x1FFF
    return (((off >> 12) & 1) << 31) | (((off >> 5) & 0x3F) << 25) | (b << 20) | (a << 15) | \
           (f3 << 12) | (((off >> 1) & 0xF) << 8) | (((off >> 11) & 1) << 7) | 0x63

def beq(a, b, off): return _b(0, a, b, off)   # off in BYTES
def bne(a, b, off): return _b(1, a, b, off)

def jal(rd, off):
    off &= 0x1FFFFF
    return (((off >> 20) & 1) << 31) | (((off >> 1) & 0x3FF) << 21) | (((off >> 11) & 1) << 20) | \
           (((off >> 12) & 0xFF) << 12) | (rd << 7) | 0x6F

HALT = jal(0, 0)

# Unsupported RV32I instructions (and a few non-RV32I words). The core
# must execute every one of these as a NOP.
def sltu(rd, a, b):   return r_type(0x00, b, a, 3, rd)
def mul(rd, a, b):    return r_type(0x01, b, a, 0, rd)      # RV32M, not RV32I
def sltiu(rd, a, imm): return i_type(imm, a, 3, rd)
def lb(rd, base, imm):  return i_type(imm, base, 0, rd, op=0x03)
def lh(rd, base, imm):  return i_type(imm, base, 1, rd, op=0x03)
def lbu(rd, base, imm): return i_type(imm, base, 4, rd, op=0x03)
def lhu(rd, base, imm): return i_type(imm, base, 5, rd, op=0x03)
def sb(src, base, imm): return sw(src, base, imm) & ~(7 << 12)              # funct3 000
def sh(src, base, imm): return (sw(src, base, imm) & ~(7 << 12)) | (1 << 12)  # funct3 001
def blt(a, b, off):  return _b(4, a, b, off)
def bge(a, b, off):  return _b(5, a, b, off)
def bltu(a, b, off): return _b(6, a, b, off)
def bgeu(a, b, off): return _b(7, a, b, off)
def lui(rd, imm20):   return ((imm20 & 0xFFFFF) << 12) | (rd << 7) | 0x37
def auipc(rd, imm20): return ((imm20 & 0xFFFFF) << 12) | (rd << 7) | 0x17
def jalr(rd, base, imm): return i_type(imm, base, 0, rd, op=0x67)
FENCE, ECALL, EBREAK = 0x0000000F, 0x00000073, 0x00100073

assert sltu(3, 1, 2) == 0x0020B1B3 and lui(5, 0x12345) == 0x123452B7
assert jalr(1, 2, 8) == 0x008100E7 and blt(1, 2, 8) == 0x0020C463

# Encoder self-check against the hand-assembled words used in the
# original testbench (tb_chiplet_soc.v).
assert addi(2, 0, 0)      == 0x00000113
assert addi(2, 0, -256)   == 0xF0000113
assert lw(1, 2, 0)        == 0x00012083
assert add(3, 1, 4)       == 0x004081B3
assert beq(1, 5, 8)       == 0x00508463
assert sw(9, 2, 0)        == 0x00912023
assert jal(5, 12)         == 0x00C002EF
assert srai(3, 2, 4)      == 0x40415193


# ------------------------------------------------------------------
# Reference model
# ------------------------------------------------------------------
class Unsupported(Exception):
    pass


class ISS:
    def __init__(self, prog, mem_init):
        self.prog = prog
        self.regs = [0] * 32
        self.mem = list(mem_init)
        self.pc = 0
        self.steps = 0

    def wr(self, rd, v):
        if rd != 0:
            self.regs[rd] = v & MASK

    def run(self, max_steps=20000):
        while True:
            idx = (self.pc >> 2) & 255
            w = self.prog[idx]
            if w == HALT:
                return
            self.step(w)
            self.steps += 1
            if self.steps > max_steps:
                raise RuntimeError("program did not reach HALT")

    def step(self, w):
        # Anything outside the supported subset is a NOP: no register
        # write, no memory access, PC + 4. Every "raise Unsupported" in
        # _exec happens before any state is changed, so catching it here
        # gives exactly that behaviour.
        try:
            self._exec(w)
        except Unsupported:
            self.pc = (self.pc + 4) & MASK

    def _exec(self, w):
        r = self.regs
        op = w & 0x7F
        rd = (w >> 7) & 31
        f3 = (w >> 12) & 7
        rs1 = (w >> 15) & 31
        rs2 = (w >> 20) & 31
        f7 = w >> 25
        a, b = r[rs1], r[rs2]
        imm_i = sext(w >> 20, 12)
        next_pc = (self.pc + 4) & MASK

        if op == 0x33:
            if   f3 == 0 and f7 == 0x00: v = a + b
            elif f3 == 0 and f7 == 0x20: v = a - b
            elif f3 == 1 and f7 == 0x00: v = a << (b & 31)
            elif f3 == 2 and f7 == 0x00: v = 1 if s32(a) < s32(b) else 0
            elif f3 == 4 and f7 == 0x00: v = a ^ b
            elif f3 == 5 and f7 == 0x00: v = a >> (b & 31)
            elif f3 == 5 and f7 == 0x20: v = s32(a) >> (b & 31)
            elif f3 == 6 and f7 == 0x00: v = a | b
            elif f3 == 7 and f7 == 0x00: v = a & b
            else: raise Unsupported(hex(w))
            self.wr(rd, v)
        elif op == 0x13:
            sh = (w >> 20) & 31
            if   f3 == 0: v = a + imm_i
            elif f3 == 2: v = 1 if s32(a) < imm_i else 0
            elif f3 == 4: v = a ^ (imm_i & MASK)
            elif f3 == 6: v = a | (imm_i & MASK)
            elif f3 == 7: v = a & (imm_i & MASK)
            elif f3 == 1 and f7 == 0x00: v = a << sh
            elif f3 == 5 and f7 == 0x00: v = a >> sh
            elif f3 == 5 and f7 == 0x20: v = s32(a) >> sh
            else: raise Unsupported(hex(w))
            self.wr(rd, v)
        elif op == 0x03:
            if f3 != 2: raise Unsupported(hex(w))
            addr = (a + imm_i) & MASK
            self.wr(rd, self.mem[(addr >> 2) & 255])
        elif op == 0x23:
            if f3 != 2: raise Unsupported(hex(w))
            imm_s = sext(((w >> 25) << 5) | ((w >> 7) & 31), 12)
            addr = (a + imm_s) & MASK
            self.mem[(addr >> 2) & 255] = b
        elif op == 0x63:
            imm_b = sext((((w >> 31) & 1) << 12) | (((w >> 7) & 1) << 11) |
                         (((w >> 25) & 0x3F) << 5) | (((w >> 8) & 0xF) << 1), 13)
            if   f3 == 0: taken = (a == b)
            elif f3 == 1: taken = (a != b)
            else: raise Unsupported(hex(w))
            if taken:
                next_pc = (self.pc + imm_b) & MASK
        elif op == 0x6F:
            imm_j = sext((((w >> 31) & 1) << 20) | (((w >> 12) & 0xFF) << 12) |
                         (((w >> 20) & 1) << 11) | (((w >> 21) & 0x3FF) << 1), 21)
            self.wr(rd, self.pc + 4)
            next_pc = (self.pc + imm_j) & MASK
        else:
            raise Unsupported(hex(w))
        self.pc = next_pc


# ------------------------------------------------------------------
# Test containers
# ------------------------------------------------------------------
class Test:
    def __init__(self, name, body, mem_init=None):
        assert len(body) <= 250, name
        self.name = name
        self.prog = body + [HALT] + [NOP] * (255 - len(body))
        self.mem_init = list(mem_init) if mem_init else [0] * 256
        iss = ISS(self.prog, self.mem_init)
        iss.run()
        self.iss = iss

    def reg(self, n):
        return self.iss.regs[n]


def u32(v):
    return v & MASK


# ------------------------------------------------------------------
# Directed tests. Each one also asserts a few HAND-COMPUTED values,
# which checks the reference model itself.
# ------------------------------------------------------------------
def directed():
    T = []

    # D1: every R-type op, with negative / mixed-sign operands
    t = Test("D01 R-type ALU ops", [
        addi(1, 0, -7), addi(2, 0, 3),
        add(3, 1, 2), sub(4, 1, 2), and_(5, 1, 2), or_(6, 1, 2), xor(7, 1, 2),
        slt(8, 1, 2), slt(9, 2, 1),
        sll(10, 2, 1),   # shift amount = x1[4:0] = 25
        srl(11, 1, 2), sra(12, 1, 2),
    ])
    assert t.reg(3) == u32(-4) and t.reg(4) == u32(-10) and t.reg(5) == 1
    assert t.reg(6) == 0xFFFFFFFB and t.reg(7) == 0xFFFFFFFA
    assert t.reg(8) == 1 and t.reg(9) == 0
    assert t.reg(10) == 0x06000000 and t.reg(11) == 0x1FFFFFFF and t.reg(12) == 0xFFFFFFFF
    T.append(t)

    # D2: every I-type op, including negative immediates and shift 0/31
    t = Test("D02 I-type ALU ops", [
        addi(1, 0, -1),                 # 0xFFFFFFFF
        addi(2, 0, 0x7FF),              # largest positive imm
        addi(3, 0, -2048),              # most negative imm
        andi(4, 1, 0x0F0), ori(5, 0, -16), xori(6, 2, -1),   # xori -1 = NOT
        slti(7, 1, 0), slti(8, 2, -1),
        slli(9, 2, 31), srli(10, 1, 31), srai(11, 1, 31), srai(12, 3, 0), slli(13, 2, 0),
    ])
    assert t.reg(4) == 0xF0 and t.reg(5) == 0xFFFFFFF0 and t.reg(6) == u32(~0x7FF)
    assert t.reg(7) == 1 and t.reg(8) == 0
    assert t.reg(9) == 0x80000000 and t.reg(10) == 1 and t.reg(11) == 0xFFFFFFFF
    assert t.reg(12) == u32(-2048) and t.reg(13) == 0x7FF
    T.append(t)

    # D3: overflow wraps, SLT on the extremes
    t = Test("D03 overflow and SLT extremes", [
        addi(1, 0, 1), slli(1, 1, 31),          # x1 = 0x80000000 (INT_MIN)
        addi(2, 1, -1),                          # x2 = 0x7FFFFFFF (INT_MAX)
        addi(3, 2, 1),                           # overflow -> INT_MIN
        sub(4, 1, 2),                            # INT_MIN - INT_MAX = 1 (wraps)
        slt(5, 1, 2), slt(6, 2, 1),
    ])
    assert t.reg(3) == 0x80000000 and t.reg(4) == 1 and t.reg(5) == 1 and t.reg(6) == 0
    T.append(t)

    # D4: BNE taken / not taken, BEQ not taken, branch on x0
    t = Test("D04 BEQ/BNE taken and not taken", [
        addi(1, 0, 5), addi(2, 0, 5), addi(3, 0, 6),
        bne(1, 3, 8), addi(10, 0, 99),        # BNE taken   -> skip
        addi(11, 0, 1),
        bne(1, 2, 8), addi(12, 0, 2),         # BNE not taken -> execute
        addi(13, 0, 3),
        beq(1, 3, 8), addi(14, 0, 4),         # BEQ not taken -> execute
        addi(15, 0, 5),
        beq(0, 0, 8), addi(16, 0, 6),         # BEQ x0,x0 always taken -> skip
        addi(17, 0, 7),
    ])
    assert t.reg(10) == 0 and t.reg(11) == 1 and t.reg(12) == 2 and t.reg(13) == 3
    assert t.reg(14) == 4 and t.reg(15) == 5 and t.reg(16) == 0 and t.reg(17) == 7
    T.append(t)

    # D5: writes to x0 are ignored, even when forwarded
    t = Test("D05 x0 is hardwired to zero", [
        addi(0, 0, 123), add(1, 0, 0),        # x1 must read 0, not 123 (no forwarding of x0)
        addi(0, 0, 55), addi(2, 0, 1), add(3, 0, 2),
        jal(0, 8), addi(4, 0, 9),             # JAL x0 must not write x0
        add(5, 0, 0),
    ])
    assert t.reg(1) == 0 and t.reg(3) == 1 and t.reg(4) == 0 and t.reg(5) == 0
    T.append(t)

    # D6: forwarding at distance 1, 2, 3 on both operands; MEM must beat WB
    t = Test("D06 forwarding paths", [
        addi(1, 0, 10),
        add(2, 1, 1),                # dist 1, both operands from MEM stage -> 20
        addi(3, 0, 7), addi(20, 0, 0),
        add(4, 3, 1),                # x3 dist 2 (WB), x1 dist 4 (regfile) -> 17
        addi(5, 0, 2), addi(20, 0, 0), addi(20, 0, 0),
        sub(6, 1, 5),                # x5 dist 3 (regfile write-through) -> 8
        addi(7, 0, 1), addi(7, 0, 2),
        add(8, 7, 7),                # x7 in MEM and WB: MEM (newer) must win -> 4
        addi(9, 0, 3), add(10, 0, 9),     # rs2 forwarded, rs1 = x0
        add(11, 9, 0),                    # rs1 forwarded
    ])
    assert t.reg(2) == 20 and t.reg(4) == 17 and t.reg(6) == 8 and t.reg(8) == 4
    assert t.reg(10) == 3 and t.reg(11) == 3
    T.append(t)

    # D7: loads and stores -- negative offsets, store data forwarded from
    # the previous instruction, back-to-back stores, store->load same address
    mem = [0] * 256
    mem[10] = 1111
    mem[11] = 2222
    t = Test("D07 load/store offsets and forwarding", [
        addi(1, 0, 48),               # x1 = byte addr 48 (word 12)
        lw(2, 1, -8),                 # word 10 -> 1111   (negative offset)
        lw(3, 1, -4),                 # word 11 -> 2222
        addi(4, 0, 77), sw(4, 1, 0),  # store data forwarded from MEM stage
        addi(5, 0, 88), addi(20, 0, 0), sw(5, 1, 4),   # store data from WB stage
        sw(2, 1, 8), sw(3, 1, 12),    # back-to-back stores
        lw(6, 1, 0), lw(7, 1, 4),     # reload what was just stored
        lw(8, 1, 8), add(9, 8, 6),    # load-use into ALU
        lw(10, 0, 4 * 13), sw(10, 0, 4 * 20),   # load-use into STORE DATA
        lw(11, 0, 4 * 10), lw(12, 11, 0),        # load-use into ADDRESS (x11=1111 -> word 1111>>2 & 255)
    ], mem)
    assert t.reg(2) == 1111 and t.reg(3) == 2222
    assert t.reg(6) == 77 and t.reg(7) == 88 and t.reg(8) == 1111 and t.reg(9) == 1188
    assert t.iss.mem[20] == 88
    T.append(t)

    # D8: JAL link value used immediately at the target; plain jump with x0
    t = Test("D08 JAL link and jumps", [
        jal(1, 12), addi(5, 0, 1), addi(5, 0, 2),   # skip two
        add(2, 1, 1),                 # x1 = 4 must be visible right away -> 8
        jal(0, 8), addi(6, 0, 3),     # plain jump, skip one
        addi(7, 0, 4),
        jal(3, 4),                    # jump to the very next instruction
        addi(8, 3, 0),                # x3 = 32
    ])
    assert t.reg(1) == 4 and t.reg(2) == 8 and t.reg(5) == 0 and t.reg(6) == 0
    assert t.reg(7) == 4 and t.reg(3) == 32 and t.reg(8) == 32
    T.append(t)

    # D9: branch resolved while a load is frozen in MEM waiting on the link
    mem = [0] * 256
    mem[0] = 42
    t = Test("D09 branch during memory wait", [
        addi(2, 0, 9), addi(3, 0, 9),
        lw(1, 0, 0),
        beq(2, 3, 8),                 # independent of the load, taken
        addi(4, 0, 1),                # skipped
        addi(5, 1, 0),                # uses the load -> 42
        lw(6, 0, 0),
        bne(6, 0, 8),                 # depends on the load (load-use + branch), taken
        addi(7, 0, 1),                # skipped
        addi(8, 0, 2),
    ], mem)
    assert t.reg(4) == 0 and t.reg(5) == 42 and t.reg(7) == 0 and t.reg(8) == 2
    T.append(t)

    # D10: JAL and store right after a load (freeze interacting with jump/store)
    mem = [0] * 256
    mem[3] = 5
    t = Test("D10 load followed by JAL / store / branch", [
        lw(1, 0, 12), jal(2, 8), addi(3, 0, 1),
        add(4, 1, 2),                 # 5 + 8 = 13
        lw(5, 0, 12), sw(5, 0, 16),   # load then store of the loaded value
        lw(6, 0, 16),
    ], mem)
    assert t.reg(4) == 13 and t.reg(6) == 5 and t.reg(3) == 0
    T.append(t)

    # D11: unsupported instructions must be NOPs. Each one targets a
    # register (or memory word) of its own, so ANY write shows up as a
    # mismatch. x25 counts the "must execute" instructions placed right
    # after anything that could jump, so a wrongly taken branch or
    # JALR shows up too. Operand values are chosen so that running the
    # instruction as its old misdecode (SLTU->ADD, BLT->BEQ, ...) OR as
    # the real RV32I instruction both give a visible wrong answer.
    mem = [0] * 256
    mem[64], mem[65], mem[66] = 0x11111111, 0x22222222, 0x33333333
    t = Test("D11 unsupported instructions are NOPs", [
        addi(1, 0, 5), addi(2, 0, -3), addi(9, 0, 256),   # x9 = word 64
        sltu(3, 1, 2), sltiu(4, 1, -1), mul(5, 1, 2),
        r_type(0x20, 2, 1, 1, 6),       # SLL with funct7=0100000
        r_type(0x20, 2, 1, 7, 7),       # AND with funct7=0100000
        i_type((0x20 << 5) | 3, 1, 1, 8),   # SLLI with funct7=0100000
        i_type((0x10 << 5) | 3, 1, 5, 10),  # SRLI with funct7=0010000
        blt(2, 1, 8),  addi(25, 25, 1),     # real BLT: taken; as BEQ: not taken
        bge(1, 1, 8),  addi(25, 25, 1),     # real BGE: taken; as BEQ: taken
        bltu(1, 2, 8), addi(25, 25, 1),
        bgeu(1, 1, 8), addi(25, 25, 1),
        jalr(17, 0, 8), addi(25, 25, 1),    # would jump to 8 and link x17
        lb(11, 9, 0), lh(12, 9, 0), lbu(13, 9, 0), lhu(14, 9, 0),
        sb(1, 9, 4), sh(1, 9, 8),           # would overwrite words 65, 66
        lui(15, 0x12345), auipc(16, 1),
        FENCE, ECALL, EBREAK, 0x00000000, 0xFFFFFFFF,
        lw(18, 9, 0), sltu(19, 18, 18),     # illegal right after a load whose
        add(21, 18, 0),                     #   rd matches its rs (stall check)
        addi(22, 0, 7), mul(23, 22, 22),    # illegal between producer and
        add(24, 22, 22),                    #   consumer: forwarding unaffected
    ], mem)
    for r in (3, 4, 5, 6, 7, 8, 10, 11, 12, 13, 14, 15, 16, 17, 19, 23):
        assert t.reg(r) == 0, r
    assert t.reg(25) == 5 and t.reg(21) == 0x11111111 and t.reg(24) == 14
    assert t.iss.mem[65] == 0x22222222 and t.iss.mem[66] == 0x33333333
    T.append(t)

    # D12: x0 on every path. A write to x0 must never be visible, whether
    # the reader gets its operand from the MEM stage (distance 1), the WB
    # stage (2), the register-file write-through bypass (3), or a load.
    # Also x0 as store data, as a load base address and in a branch.
    # x20 writes are spacers; they do not touch x0.
    mem = [0] * 256
    mem[0], mem[1] = 0xAAAAAAAA, 0x55
    t = Test("D12 writes to x0 on every forwarding path", [
        addi(0, 0, 11), add(1, 0, 0),                                  # MEM path
        addi(0, 0, 12), addi(20, 0, 0), add(2, 0, 0),                  # WB path
        addi(0, 0, 13), addi(20, 0, 0), addi(20, 0, 0), add(3, 0, 0),  # RF bypass
        lw(0, 0, 0), add(4, 0, 0),                                     # load, dist 1
        lw(0, 0, 0), addi(20, 0, 0), add(5, 0, 0),                     # load, dist 2
        lw(0, 0, 0), addi(20, 0, 0), addi(20, 0, 0), add(6, 0, 0),     # load, dist 3
        addi(0, 0, 5), sw(0, 0, 8),            # store data = x0 -> word 2 stays 0
        addi(0, 0, 40), lw(7, 0, 4),           # base x0 -> word 1 (0x55), not word 11
        addi(0, 0, 1), beq(0, 0, 8), addi(8, 0, 1),     # x0 == x0 still: taken
        addi(0, 0, 1), bne(0, 0, 8), addi(9, 0, 1),     # not taken: executes
        jal(0, 8), addi(10, 0, 1), add(11, 0, 0),       # JAL x0 links nothing
        addi(12, 0, 3), sub(0, 12, 0), add(13, 12, 0),  # x0 as rs2 right after
        lw(0, 0, 0), sw(0, 0, 12),             # loaded "x0" as store data
    ], mem)
    for r in (1, 2, 3, 4, 5, 6, 8, 10, 11):
        assert t.reg(r) == 0, r
    assert t.reg(7) == 0x55 and t.reg(9) == 1 and t.reg(13) == 3
    assert t.iss.mem[2] == 0 and t.iss.mem[3] == 0
    T.append(t)

    return T


# ------------------------------------------------------------------
# Random programs. Registers x1..x15 only, so dependencies are dense;
# about half of all source operands are the most recent destinations,
# which is what stresses forwarding and hazards.
# ------------------------------------------------------------------
def random_test(k, rng):
    regs = list(range(1, 16))
    body = [addi(r, 0, rng.randint(-2048, 2047)) for r in regs]   # initialise all
    recent = []
    n = rng.randint(40, 180)

    def src():
        if recent and rng.random() < 0.5:
            return rng.choice(recent[-3:])
        return rng.choice(regs + [0])

    # x0 is a destination ~8% of the time (was 3%: too rare -- a
    # planted x0-forwarding bug was caught by only 2 of 310 tests)
    def dst():
        return rng.choice(regs + ([0] if rng.random() < 0.08 else []))

    # unsupported instructions, random operands; all must act as NOPs
    illegal = [
        lambda: sltu(rng.choice(regs), src(), src()),
        lambda: mul(rng.choice(regs), src(), src()),
        lambda: sltiu(rng.choice(regs), src(), rng.randint(-2048, 2047)),
        lambda: lb(rng.choice(regs), src(), rng.randint(-2048, 2047)),
        lambda: lhu(rng.choice(regs), src(), rng.randint(-2048, 2047)),
        lambda: sb(src(), src(), rng.randint(-2048, 2047)),
        lambda: sh(src(), src(), rng.randint(-2048, 2047)),
        lambda: rng.choice([blt, bge, bltu, bgeu])(src(), src(), 8),
        lambda: jalr(rng.choice(regs), src(), rng.randint(-2048, 2047)),
        lambda: lui(rng.choice(regs), rng.getrandbits(20)),
        lambda: auipc(rng.choice(regs), rng.getrandbits(20)),
    ]

    while len(body) < 15 + n:
        remaining = (15 + n) - len(body)
        kind = rng.choices(
            ["r", "i", "sh", "lw", "sw", "br", "jal", "ill"],
            weights=[28, 18, 8, 15, 12, 13, 6, 3])[0]
        if kind == "ill":
            body.append(rng.choice(illegal)())
            continue
        if kind == "r":
            f = rng.choice([add, sub, and_, or_, xor, slt, sll, srl, sra])
            d = dst(); body.append(f(d, src(), src())); recent.append(d)
        elif kind == "i":
            f = rng.choice([addi, andi, ori, xori, slti])
            d = dst(); body.append(f(d, src(), rng.randint(-2048, 2047))); recent.append(d)
        elif kind == "sh":
            f = rng.choice([slli, srli, srai])
            d = dst(); body.append(f(d, src(), rng.choice([0, 1, 31, rng.randint(0, 31)]))); recent.append(d)
        elif kind == "lw":
            d = dst(); body.append(lw(d, src(), rng.randint(-2048, 2047))); recent.append(d)
        elif kind == "sw":
            body.append(sw(src(), src(), rng.randint(-2048, 2047)))
        elif kind in ("br", "jal"):
            # instructions skipped; the target may be the HALT itself but
            # never past it (past it = NOPs, then the PC wraps to 0)
            skip = rng.randint(0, min(4, remaining - 1))
            off = 4 * (skip + 1)                       # forward only: no loops
            if kind == "br":
                f = rng.choice([beq, bne])
                body.append(f(src(), src(), off))
            else:
                d = rng.choice(regs + [0]); body.append(jal(d, off)); recent.append(d)
    mem = [rng.getrandbits(32) for _ in range(256)]
    return Test("R%03d random (seed-derived)" % k, body, mem)


# ------------------------------------------------------------------
def main():
    num_random = int(sys.argv[1]) if len(sys.argv) > 1 else 300
    seed = int(sys.argv[2]) if len(sys.argv) > 2 else 20261013
    rng = random.Random(seed)

    tests = directed() + [random_test(k, rng) for k in range(num_random)]

    out = os.path.join(os.path.dirname(os.path.abspath(__file__)), "vectors")
    os.makedirs(out, exist_ok=True)

    def dump(name, rows):
        with open(os.path.join(out, name), "w", newline="\n") as f:
            for v in rows:
                f.write("%08x\n" % (v & MASK))

    dump("count.hex", [len(tests)])
    dump("prog_all.hex", [w for t in tests for w in t.prog])
    dump("mem_init_all.hex", [w for t in tests for w in t.mem_init])
    dump("exp_regs_all.hex", [w for t in tests for w in t.iss.regs])
    dump("exp_mem_all.hex", [w for t in tests for w in t.iss.mem])
    dump("steps_all.hex", [t.iss.steps for t in tests])
    with open(os.path.join(out, "manifest.txt"), "w", newline="\n") as f:
        f.write("# index  steps  name   (seed %d)\n" % seed)
        for i, t in enumerate(tests):
            f.write("%4d  %5d  %s\n" % (i, t.iss.steps, t.name))

    total_steps = sum(t.iss.steps for t in tests)
    print("generated %d tests (%d directed, %d random), %d instructions executed in the model"
          % (len(tests), len(tests) - num_random, num_random, total_steps))


if __name__ == "__main__":
    main()
