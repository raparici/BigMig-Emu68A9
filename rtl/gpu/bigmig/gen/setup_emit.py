# Copyright 2026 Ruben Aparicio
#
# This file is part of BigMig
#
# BigMig is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 3 of the License, or
# (at your option) any later version.
#
# BigMig is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <https://www.gnu.org/licenses/>.

# triangle setup microcode: encodes the scheduled kernel into bm_setup_ucode.hex / .vh

import os, struct, sys
import setup_prog, setup_isa, setup_modsched as MS
from setup_isa import ALU_FN, STATE_REGS

# ---- the microword: (name, width) from bit 0 up ----------------------------------------------------------------
M_FIELDS = [("m_op", 3), ("m_fn", 5), ("m_a", 9), ("m_amode", 2), ("m_b", 9), ("m_dst", 8), ("m_ob", 7),
            ("m_fin", 6), ("m_fout", 5), ("m_imm", 8), ("m_stage", 1), ("m_acc", 2), ("m_macc", 2), ("m_last", 1)]
S_FIELDS = [("s_op", 4), ("s_fn", 5), ("s_a", 9), ("s_amode", 2), ("s_b", 9), ("s_bmode", 2), ("s_dst", 8),
            ("s_ob", 7), ("s_fin", 6), ("s_fout", 5), ("s_imm", 16), ("s_stage", 1)]
M_OP = {"NOP": 0, "ALU": 1, "FMUL": 2, "FSQR": 3, "IMUL": 4, "MACC": 5, "MACCIF": 5}
S_OP = {"NOP": 0, "ALU": 1, "FADD": 2, "FSUB": 3, "I2F": 4, "U30": 5, "LUT": 6, "FDIV": 7, "FSQRT": 8,
        "MARKDROP": 9, "DONE": 10}
SRC_BANK_M, SRC_BANK_S, SRC_REC, SRC_SPECIAL = 0, 1, 2, 3       # bits 8:7 of a source field
CONST_BASE = 64                                                   # special index 64.. = constants, 0..7 = state

def layout(fields, base=0):
    pos = {}; b = base
    for n, w in fields: pos[n] = (b, w); b += w
    return pos, b

MPOS, MW = layout(M_FIELDS)
SPOS, SW = layout(S_FIELDS, MW)
WIDTH = SW

def src(v, p):
    if v.kind == "rec": return (SRC_REC << 7) | (v.idx & 31), v.mode
    if v.kind == "state": return (SRC_SPECIAL << 7) | v.idx, 0
    if v.kind == "const": return (SRC_SPECIAL << 7) | (CONST_BASE + v.idx), 0
    bank = SRC_BANK_M if v.bank == "M" else SRC_BANK_S
    return (bank << 7) | v.reg, 0

def flag_in(o):
    if not o.flag_in: return 0
    f, inv = o.flag_in
    return (1 << 5) | ((1 if inv else 0) << 4) | f.fidx

def emit(p):
    II = p.II
    words = [0] * II
    lst = [[] for _ in range(II)]
    ops = [o for o in p.ops if o.code != "END"]
    def put(word, pos, name, val):
        b, w = pos[name]
        if val < 0 or val >= (1 << w): raise ValueError(f"{name}={val} does not fit {w} bits")
        return word | (val << b)
    for o in ops:
        k = o.cycle % II; st = o.cycle // II
        w = words[k]
        a, am = src(o.srcs[0], p) if len(o.srcs) > 0 else (0, 0)
        b, bm = src(o.srcs[1], p) if len(o.srcs) > 1 else (0, 0)
        if o.code == "FSQR": b, bm = 0, 0          # the engine squares port M.A
        dst = (0x80 | o.dst.reg) if (o.dst is not None and o.dst.reg is not None) else 0
        ob = (0x40 | o.ob) if o.ob is not None else 0
        fout = (0x10 | o.flag_out.fidx) if o.flag_out is not None else 0
        imm = o.imm & 0xFF if o.code not in ("MARKDROP",) else 0
        if o.slot == "M":
            P = MPOS
            if (w >> MPOS["m_op"][0]) & 7: raise ValueError(f"slot M clash at {k}")
            op = M_OP["ALU"] if o.cls == "ALU" else M_OP[o.code]
            w = put(w, P, "m_op", op)
            if o.cls == "ALU": w = put(w, P, "m_fn", ALU_FN.index(o.code))
            w = put(w, P, "m_a", a); w = put(w, P, "m_amode", am); w = put(w, P, "m_b", b)
            w = put(w, P, "m_dst", dst); w = put(w, P, "m_ob", ob); w = put(w, P, "m_fin", flag_in(o))
            w = put(w, P, "m_fout", fout); w = put(w, P, "m_imm", imm); w = put(w, P, "m_stage", st)
            if o.cls == "MACC":
                w = put(w, P, "m_acc", o.acc)
                mode = 2 if o.code == "MACCIF" else (0 if o.acc_first else 1)
                w = put(w, P, "m_macc", mode)
                w = put(w, P, "m_last", 1 if (o.ob is not None or o.dst is not None) else 0)
        else:
            P = SPOS
            if (w >> SPOS["s_op"][0]) & 15: raise ValueError(f"slot S clash at {k}")
            op = S_OP["ALU"] if o.cls == "ALU" else S_OP[o.code]
            w = put(w, P, "s_op", op)
            if o.cls == "ALU": w = put(w, P, "s_fn", ALU_FN.index(o.code))
            w = put(w, P, "s_a", a); w = put(w, P, "s_amode", am); w = put(w, P, "s_b", b); w = put(w, P, "s_bmode", bm)
            w = put(w, P, "s_dst", dst); w = put(w, P, "s_ob", ob); w = put(w, P, "s_fin", flag_in(o))
            w = put(w, P, "s_fout", fout); w = put(w, P, "s_stage", st)
            if o.code == "MARKDROP":
                mask = 0
                for f in o.fmask: mask |= 1 << f.fidx
                w = put(w, P, "s_imm", mask)
            else:
                w = put(w, P, "s_imm", o.imm & 0xFFFF)
        words[k] = w
        lst[k].append(f"{o.slot}{st} {o.code:9s} {o.name}")
    return words, lst

def consts(p):
    t = sorted(p.consts.items(), key=lambda kv: kv[1])
    return [u for u, i in t]

def main(outdir):
    p = setup_isa.P("kernel"); setup_prog.triangle(p, 0, 0); p.end()
    MS.schedule(p); MS.allocate(p)
    words, lst = emit(p)
    hexw = (WIDTH + 3) // 4
    with open(os.path.join(outdir, "bm_setup_ucode.hex"), "w") as f:
        for w in words: f.write(f"{w:0{hexw}x}\n")
    cs = consts(p)
    with open(os.path.join(outdir, "bm_setup_ucode.vh"), "w") as f:
        f.write("// triangle setup microcode parameters (generated; do not edit)\n\n")
        f.write(f"localparam UC_II = {p.II};\nlocalparam UC_WIDTH = {WIDTH};\nlocalparam UC_STAGES = {p.stages};\n")
        f.write(f"localparam UC_NCONST = {len(cs)};\n")
        for i, u in enumerate(cs): f.write(f"localparam [31:0] UC_CONST{i} = 32'h{u:08x};\n")
        for n, (b, w) in list(MPOS.items()) + list(SPOS.items()):
            f.write(f"localparam {n.upper()}_LO = {b}, {n.upper()}_W = {w};\n")
    with open(os.path.join(outdir, "gen", "bm_setup_ucode.lst"), "w") as f:
        f.write(MS.report(p) + "\n")
        for k in range(p.II):
            f.write(f"{k:4d}: " + " | ".join(lst[k]) + "\n")
    print(MS.report(p)); print(f"microword {WIDTH} bits, {p.II} words, {len(cs)} constants")
    return p

if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
