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

# triangle setup: list scheduling and register / flag / accumulator allocation

import collections
from setup_isa import LAT, WR, ADDER_TAKE, ACC_REUSE, MACC_READ, NACC, V, F, Op, STATE_FLAGS

NREG = 128
NFLAG = 14                     # 14, 15: the snooped state flags
COMMUTATIVE = {"MIN", "MAX", "FADD", "FMUL", "IMUL", "ADDIF"}

class SchedError(Exception): pass

PORTS = {"MA": {"rf", "rec"}, "MB": {"rf", "const"}, "SA": {"rf", "rec", "state", "const"}, "SB": {"rf", "rec", "const"}}

def vkind(v): return v.kind
def fits(o, slot):
    pa, pb = ("MA", "MB") if slot == "M" else ("SA", "SB")
    ks = [vkind(v) for v in o.srcs]
    return (len(ks) < 1 or ks[0] in PORTS[pa]) and (len(ks) < 2 or ks[1] in PORTS[pb])

def legalise(p):
    new = []
    for o in p.ops:
        if o.srcs:
            okslots = [sl for sl in o.slots if fits(o, sl)]
            if not okslots and len(o.srcs) == 2 and o.code in COMMUTATIVE:
                o.srcs = [o.srcs[1], o.srcs[0]]
                okslots = [sl for sl in o.slots if fits(o, sl)]
            if not okslots:
                # move the second operand into the RF (slot S MOV, which can read anything on port A)
                v = o.srcs[1]
                m = Op("MOV", "ALU", "S", [v], f"{'AB'[o.tri]}.mv_{v.name}"); m.dst = V(m.name, op=m)
                m.tri = o.tri; m.bias = o.bias
                new.append(m); o.srcs[1] = m.dst
                okslots = [sl for sl in o.slots if fits(o, sl)]
                if not okslots: raise SchedError(f"cannot place {o.name}")
            o.slots = "".join(okslots)
        new.append(o)
    p.ops = new

def write_cycle(o):
    if o.cycle is None: return None
    if o.cls in WR and (o.dst is not None or o.ob is not None or o.cls == "MACC"):
        return o.cycle + WR[o.cls]
    return None

def preds(o):
    ps = [v.op for v in o.srcs if v.op is not None]
    if o.flag_in and o.flag_in[0].op is not None: ps.append(o.flag_in[0].op)
    ps += [f.op for f in o.fmask if f.op is not None]
    if o.acc_src is not None: ps.append(o.acc_src)
    ps += o.extra_preds
    return ps

def earliest(o):
    if o.code in ("DONE", "END"):
        e = 0
        for q in o.extra_preds:
            wc = write_cycle(q)
            e = max(e, (wc + 1) if wc is not None else q.cycle + 1)
            if q.cls == "DIV": e = max(e, q.cycle + LAT["DIV"])
        return e
    e = 0
    for v in o.srcs:
        q = v.op
        if q is None: continue
        if q.cls == "MACC": e = max(e, q.cycle + MACC_READ)
        else: e = max(e, q.cycle + LAT[q.cls])
    if o.flag_in and o.flag_in[0].op is not None: e = max(e, o.flag_in[0].op.cycle + 2)
    for f in o.fmask:
        if f.op is not None: e = max(e, f.op.cycle + 2)
    if o.acc_src is not None: e = max(e, o.acc_src.cycle + ACC_REUSE)
    for q in o.extra_preds:
        e = max(e, q.cycle + 1)
    return e

def schedule(p, maxcyc=3000):
    legalise(p)
    ops = p.ops
    # control ordering: DONE after every op of its triangle that writes the output buffer, and MARKDROP;
    # END after every op.  Pairs: B's dot products after A's, B's divisions after A's (A's critical path first).
    for o in ops:
        if o.code == "DONE":
            o.extra_preds = [q for q in ops if q.tri == o.tri and (q.ob is not None or q.code == "MARKDROP")]
        if o.code == "END":
            o.extra_preds = [q for q in ops if q is not o]
    if any(o.tri == 1 for o in ops):
        a_macc = [q for q in ops if q.tri == 0 and q.cls == "MACC"]
        a_div = [q for q in ops if q.tri == 0 and q.cls == "DIV"]
        for o in ops:
            if o.tri == 1 and o.cls == "MACC" and o.acc_src is None: o.extra_preds = o.extra_preds + a_macc[-4:]
            if o.tri == 1 and o.cls == "DIV": o.extra_preds = o.extra_preds + a_div
    for o in ops: o.succ = []
    for o in ops:
        for q in preds(o): q.succ.append(o)
    lat = lambda o: {"ALU": 3, "LUT": 4, "MUL": 5, "FADD": 6, "DIV": LAT["DIV"], "MACC": 4, "CTL": 1}[o.cls]
    for o in reversed(ops):
        o.prio = lat(o) + max([q.prio for q in o.succ], default=0)
    for o in ops: o.prio += o.bias; o.cycle = None
    chain_last = {}
    for o in ops:
        if o.cls == "MACC" and o.acc_src is None:
            k = o; ch = [k]
            while True:
                nx = [q for q in k.succ if q.cls == "MACC" and q.acc_src is k]
                if not nx: break
                k = nx[0]; ch.append(k)
            for q in ch: chain_last[id(q)] = ch[-1]
    wres = {"M": set(), "S": set()}; obres = set(); adder = set()
    div_free = 0; acc_busy = [None] * NACC
    todo = [o for o in ops]
    c = 0
    while todo:
        if c > maxcyc: raise SchedError(f"no progress at {c}: {[o.name for o in todo[:5]]}")
        ready = [o for o in todo if all(q.cycle is not None for q in preds(o)) and earliest(o) <= c]
        ready.sort(key=lambda o: -o.prio)
        used = set()
        for o in ready:
            cand = sorted(o.slots, key=lambda x: x != "S") if o.cls == "ALU" else list(o.slots)
            for slot in cand:
                if slot in used or not fits(o, slot): continue
                o.cycle = c; o.slot = slot
                bank = "S" if (slot == "S" or o.cls == "DIV") else "M"
                wc = write_cycle(o)
                ok = True
                needs_rf = o.dst is not None
                if needs_rf and wc is not None and wc in wres[bank]: ok = False
                if o.ob is not None and wc in obres: ok = False
                if o.cls in ADDER_TAKE and (c + ADDER_TAKE[o.cls]) in adder: ok = False
                if o.cls == "DIV" and c < div_free: ok = False
                acc = None
                if ok and o.cls == "MACC":
                    if o.acc_src is None:
                        free = [k for k in range(NACC) if acc_busy[k] is None]
                        if not free: ok = False
                        else: acc = free[0]
                    else: acc = o.acc_src.acc
                if not ok:
                    o.cycle = None; o.slot = None; continue
                o.acc = acc; used.add(slot)
                if needs_rf and wc is not None: wres[bank].add(wc)
                if o.ob is not None: obres.add(wc)
                if o.cls in ADDER_TAKE: adder.add(c + ADDER_TAKE[o.cls])
                if o.cls == "DIV": div_free = c + LAT["DIV"]
                if o.cls == "MACC":
                    acc_busy[acc] = None if chain_last[id(o)] is o else o
                todo.remove(o)
                break
            if len(used) == 2: break
        c += 1
    p.length = max(o.cycle for o in ops) + 1
    return p

def allocate(p):
    for o in p.ops:
        if o.dst is not None: o.dst.readers = []
    for o in p.ops:
        for v in o.srcs: v.readers.append(o)
    vals = []
    for o in p.ops:
        v = o.dst
        if v is None or not v.readers: continue
        v.bank = "S" if (o.slot == "S" or o.cls == "DIV") else "M"
        v.wcycle = write_cycle(o)
        v.lastread = max(r.cycle for r in v.readers)
        for r in v.readers:
            if r.cycle < v.wcycle + 1: raise SchedError(f"{r.name} reads {v.name} before it is written")
        vals.append(v)
    for bank in "MS":
        bv = sorted([v for v in vals if v.bank == bank], key=lambda v: v.wcycle)
        free_at = [-1] * NREG
        for v in bv:
            for r in range(NREG):
                if free_at[r] < v.wcycle:
                    v.reg = r; free_at[r] = v.lastread; break
            else: raise SchedError(f"bank {bank}: out of registers at {v.name}")
        setattr(p, f"regs_{bank}", max([v.reg for v in bv], default=-1) + 1)
    # flags: written end of cycle+1, read during the reader's cycle+1 (ops issued at >= cycle+2)
    fl = []
    for o in p.ops:
        if o.flag_out is not None:
            f = o.flag_out
            rd = [q for q in p.ops if (q.flag_in and q.flag_in[0] is f) or f in q.fmask]
            fl.append((o.cycle + 1, max([q.cycle + 1 for q in rd], default=o.cycle + 2), f))
    fl.sort(key=lambda t: t[0])
    free_at = [-1] * NFLAG
    for (w, r, f) in fl:
        for k in range(NFLAG):
            if free_at[k] < w:
                f.fidx = k; free_at[k] = r; break
        else: raise SchedError("out of flags")
    return p

def report(p):
    n = collections.Counter((o.slot, o.cls) for o in p.ops)
    um = sum(v for (s, c), v in n.items() if s == "M"); us = sum(v for (s, c), v in n.items() if s == "S")
    done = [(o.name, o.cycle) for o in p.ops if o.code in ("DONE", "END")]
    return (f"program {p.name}: {p.length} clocks; slot M {um} ops, slot S {us} ops; regs M {p.regs_M} S {p.regs_S}; "
            f"consts {len(p.consts)}; {done}; " + ", ".join(f"{s}.{c} {v}" for (s, c), v in sorted(n.items(), key=str)))

def timeline(p, width=100):
    tl = {}
    for o in p.ops: tl.setdefault(o.cycle, {})[o.slot] = o.cls[0] if o.tri == 0 else o.cls[0].lower()
    out = []
    for r in range(0, p.length, width):
        out.append(" M " + "".join(tl.get(c, {}).get("M", ".") for c in range(r, min(r + width, p.length))))
        out.append(" S " + "".join(tl.get(c, {}).get("S", ".") for c in range(r, min(r + width, p.length))))
    return "\n".join(out)

if __name__ == "__main__":
    import setup_prog
    for pair in (False, True):
        p = setup_prog.build(pair); schedule(p); allocate(p)
        print(report(p)); print(timeline(p))
