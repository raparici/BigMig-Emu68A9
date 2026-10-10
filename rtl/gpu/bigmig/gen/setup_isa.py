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

# triangle setup engine: instruction set, latencies and program builder

import struct

def f2u(f): return struct.unpack("<I", struct.pack("<f", f))[0]

LAT = dict(ALU=3, LUT=3, MUL=5, FADD=6, DIV=17)
WR = dict(ALU=2, LUT=2, MUL=4, FADD=5, MACC=8, DIV=16)
DIV_BUSY = 15
ADDER_TAKE = dict(FADD=1, MACC=4)
ACC_REUSE = 4
MACC_READ = 9
NACC = 4

STATE_REGS = ["YOFF", "YEND", "RESX", "RESX16", "SCX0", "SCY0", "SCX1", "SCY1"]
STATE_FLAGS = {"SCISSOR": 14, "TMU0": 15}          # flag-file indices the snooped enables appear at

ALU_FN = ["MOV", "SUB", "ADDK", "MIN", "MAX", "BBX", "SUBS4", "NEGIF", "SHL4NEGIF", "MINIF", "ADDIF", "PACK",
          "FMIN", "FMAX", "FTRLT", "FTRGT", "FLE0", "FLT", "FGE", "FGT"]
CMP_FN = {"FLE0", "FLT", "FGE", "FGT"}

class V:
    __slots__ = ("name", "op", "kind", "idx", "mode", "bank", "reg", "readers", "wcycle", "lastread")
    def __init__(s, name, op=None, kind="rf", idx=None, mode=0):
        s.name, s.op, s.kind, s.idx, s.mode = name, op, kind, idx, mode
        s.bank = None; s.reg = None; s.readers = []; s.wcycle = None; s.lastread = None
    def __repr__(s): return f"V({s.name})"

class F:
    __slots__ = ("name", "op", "fidx", "state", "readers")
    def __init__(s, name, op=None, state=None):
        s.name, s.op, s.state, s.readers = name, op, state, []
        s.fidx = STATE_FLAGS[name] if state else None

class Op:
    __slots__ = ("code", "cls", "slots", "srcs", "dst", "flag_in", "flag_out", "imm", "ob", "acc_first", "acc_keep",
                 "acc_src", "name", "cycle", "slot", "prio", "succ", "acc", "fmask", "tri", "bias", "extra_preds")
    def __init__(s, code, cls, slots, srcs, name):
        s.code, s.cls, s.slots, s.srcs, s.name = code, cls, slots, list(srcs), name
        s.dst = None; s.flag_in = None; s.flag_out = None; s.imm = 0; s.ob = None
        s.acc_first = False; s.acc_keep = False; s.acc_src = None
        s.cycle = None; s.slot = None; s.prio = 0; s.succ = []; s.acc = None; s.fmask = []
        s.tri = 0; s.bias = 0; s.extra_preds = []

class P:
    def __init__(s, name):
        s.name = name; s.ops = []; s.consts = {}; s.tri = 0; s.prio_bias = 0
    # ---- special values -------------------------------------------------------------------------------------------
    def rec(s, k): return V(f"{'AB'[s.tri]}.R{k}", kind="rec", idx=k + 32 * s.tri, mode=0)
    def rec_lo(s, k): return V(f"{'AB'[s.tri]}.R{k}lo", kind="rec", idx=k + 32 * s.tri, mode=1)
    def rec_hi(s, k): return V(f"{'AB'[s.tri]}.R{k}hi", kind="rec", idx=k + 32 * s.tri, mode=2)
    def state(s, n): return V(n, kind="state", idx=STATE_REGS.index(n))
    def state_flag(s, n): return F(n, state=True)
    def const_i(s, v): return s._const(v & 0xFFFFFFFF, f"#{v}")
    def const_f(s, v): return s._const(f2u(v), f"#{v}f")
    def _const(s, u, nm):
        if u not in s.consts: s.consts[u] = len(s.consts)
        return V(nm, kind="const", idx=s.consts[u])
    # ---- op construction --------------------------------------------------------------------------------------------
    def _op(s, code, cls, slots, srcs, name, out=True):
        name = f"{'AB'[s.tri]}.{name or code}"
        o = Op(code, cls, slots, srcs, name); s.ops.append(o); o.tri = s.tri; o.bias = s.prio_bias
        if out: o.dst = V(name, op=o)
        return o
    def _alu(s, code, srcs, name, imm=0, flag_in=None):
        o = s._op(code, "ALU", "MS", srcs, name); o.imm = imm; o.flag_in = flag_in
        return o.dst
    def mov(s, a, name=None): return s._alu("MOV", [a], name)
    def sub(s, a, b, name=None): return s._alu("SUB", [a, b], name)
    def addk(s, a, k, name=None): return s._alu("ADDK", [a], name, imm=k)
    def imin(s, a, b, name=None): return s._alu("MIN", [a, b], name)
    def imax(s, a, b, name=None): return s._alu("MAX", [a, b], name)
    def bbx(s, a, name=None): return s._alu("BBX", [a], name)                     # clamp(a >> 4, 0, 2047)
    def subs4(s, a, b, name=None): return s._alu("SUBS4", [a, b], name)           # (a << 4) - b
    def neg_if(s, a, f, name=None): return s._alu("NEGIF", [a], name, flag_in=(f, False))
    def shl4_neg_if(s, a, f, inv, name=None): return s._alu("SHL4NEGIF", [a], name, flag_in=(f, inv))
    def min_if(s, a, b, f, name=None): return s._alu("MINIF", [a, b], name, flag_in=(f, False))
    def add_if(s, a, b, f, name=None): return s._alu("ADDIF", [a, b], name, flag_in=(f, False))
    def pack16(s, a, b, name=None): return s._alu("PACK", [a, b], name)          # b << 16 | a & 0xFFFF
    def fmin(s, a, b, name=None): return s._alu("FMIN", [a, b], name)            # (b < a) ? b : a
    def fmax(s, a, b, name=None): return s._alu("FMAX", [a, b], name)            # (a < b) ? b : a
    def ftrunc_if_lt(s, a, k, name=None): return s._alu("FTRLT", [a, s.const_f(k)], name)
    def ftrunc_if_gt(s, a, k, name=None): return s._alu("FTRGT", [a, s.const_f(k)], name)
    def _flag(s, code, srcs, name, gate=None):
        o = s._op(code, "ALU", "MS", srcs, name, out=False); o.flag_out = F(o.name, o)
        if gate is not None: o.flag_in = (gate, False)
        return o.flag_out
    def flag_le0(s, a, name, gate=None): return s._flag("FLE0", [a], name, gate)
    def flag_lt(s, a, b, name, gate=None): return s._flag("FLT", [a, b], name, gate)
    def flag_ge(s, a, b, name, gate=None): return s._flag("FGE", [a, b], name, gate)
    def flag_gt(s, a, b, name, gate=None): return s._flag("FGT", [a, b], name, gate)
    # ---- multiplier, adder, divider, LUT ----------------------------------------------------------------------------
    def imul(s, a, b, name=None): return s._op("IMUL", "MUL", "M", [a, b], name).dst
    def fmul(s, a, b, name=None): return s._op("FMUL", "MUL", "M", [a, b], name).dst
    def fsqr(s, a, name=None): return s._op("FSQR", "MUL", "M", [a], name).dst
    def fadd(s, a, b, name=None): return s._op("FADD", "FADD", "S", [a, b], name).dst
    def fsub(s, a, b, name=None): return s._op("FSUB", "FADD", "S", [a, b], name).dst
    def i2f(s, a, name=None): return s._op("I2F", "FADD", "S", [a], name).dst
    def u30(s, a, name=None): return s._op("U30", "FADD", "S", [a], name).dst
    def lut(s, a, byte, name=None):
        o = s._op("LUT", "LUT", "S", [a], name); o.imm = byte; return o.dst
    def fdiv(s, a, b, name=None): return s._op("FDIV", "DIV", "S", [a, b], name).dst
    def fsqrt(s, a, name=None): return s._op("FSQRT", "DIV", "S", [a], name).dst
    # ---- dot products on the MACC path --------------------------------------------------------------------------------
    def dot3(s, a, w, ob=None, keep=False, keep_acc=False, name=None):
        import os
        if os.environ.get("SETUP_NEG") == "assoc":      # negative control: (a0 w0) + ((a1 w1) + (a2 w2)) -> other rounding
            a = [a[1], a[2], a[0]]; w = [w[1], w[2], w[0]]
        o0 = s._op("MACC", "MACC", "M", [a[0], w[0]], f"{name}.0", out=False); o0.acc_first = True
        o1 = s._op("MACC", "MACC", "M", [a[1], w[1]], f"{name}.1", out=False); o1.acc_src = o0
        o2 = s._op("MACC", "MACC", "M", [a[2], w[2]], f"{name}.2", out=False); o2.acc_src = o1
        o2.ob = ob; o2.acc_keep = keep_acc
        if keep: o2.dst = V(o2.name, op=o2)
        return o2.dst if keep else o2
    def macc_rebase(s, acc_op, yi, fd, f, ob, name=None):
        o = s._op("MACCIF", "MACC", "M", [yi, fd], name, out=False); o.acc_src = acc_op; o.flag_in = (f, False)
        o.ob = ob; return o
    # ---- outputs and control -------------------------------------------------------------------------------------------
    def ob_int(s, k, v):
        if v.op is not None and v.op.cls == "ALU" and v.op.ob is None and v.op.tri == s.tri:
            v.op.ob = k; return
        o = s._op("MOV", "ALU", "MS", [v], f"ob{k}", out=False); o.ob = k
    def mark_drop(s, flags):
        o = s._op("MARKDROP", "CTL", "S", [], "markdrop", out=False); o.fmask = list(flags)
    def done(s): s._op("DONE", "CTL", "S", [], "done", out=False)
    def end(s): s._op("END", "CTL", "S", [], "end", out=False)
