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

# triangle setup: modulo scheduling of the program into a kernel of II clocks

import collections
from setup_isa import LAT, WR, ADDER_TAKE, ACC_REUSE, MACC_READ, DIV_BUSY, V, F, Op
import setup_sched as S

NACC = 4

class ModError(Exception): pass

def lat_edge(q, o):
    if o.code in ("DONE", "END"):
        wc = WR.get(q.cls)
        d = (wc + 1) if (wc is not None and (q.dst is not None or q.ob is not None or q.cls == "MACC")) else 1
        if q.cls == "DIV": d = max(d, LAT["DIV"])
        return d
    if o.acc_src is q: return ACC_REUSE
    if (o.flag_in and o.flag_in[0].op is q) or any(f.op is q for f in o.fmask): return 2
    if q.cls == "MACC": return MACC_READ
    return LAT[q.cls]

def dot_block(ops):
    """the MACC chains in block order, and each MACC's offset in the block"""
    chains = []
    first = [o for o in ops if o.cls == "MACC" and o.acc_src is None]
    succ = collections.defaultdict(list)
    for o in ops:
        if o.cls == "MACC" and o.acc_src is not None: succ[id(o.acc_src)].append(o)
    for f in first:
        ch = [f]
        while succ[id(ch[-1])]: ch.append(succ[id(ch[-1])][0])
        chains.append(ch)
    def key(ch):
        n = ch[0].name                      # A.Y12.0 / A.X12.0 / A.S12.0
        kind = n.split(".")[1][0]; word = int(n.split(".")[1][1:])
        tex = word >= 30
        rank = {"Y": 0, "X": 1, "S": 2}[kind]
        return (2 if kind == "S" else (1 if tex else 0), rank, word)
    chains.sort(key=key)
    # four accumulators, round robin: clock t issues on accumulator t % 4
    pending = collections.deque(chains)
    cur = [None] * NACC; pos = [0] * NACC
    t = 0; offs = {}
    while pending or any(c is not None for c in cur):
        a = t % NACC
        if cur[a] is None and pending:
            cur[a] = pending.popleft(); pos[a] = 0
        if cur[a] is not None:
            o = cur[a][pos[a]]; offs[id(o)] = t; o.acc = a
            pos[a] += 1
            if pos[a] == len(cur[a]): cur[a] = None
        t += 1
    return offs, t

def schedule(p, ii_min=None, ii_max=300, t0_min=40, verbose=False):
    S.legalise(p)
    ops = [o for o in p.ops if o.code != "END"]
    for o in ops:
        if o.code == "DONE":
            o.extra_preds = [q for q in ops if q is not o and (q.ob is not None or q.code == "MARKDROP")]
    pred = {id(o): S.preds(o) for o in ops}
    succ = collections.defaultdict(list)
    for o in ops:
        for q in pred[id(o)]: succ[id(q)].append(o)
    height = {}
    for o in reversed(ops):
        height[id(o)] = max([lat_edge(o, s) + height[id(s)] for s in succ[id(o)]], default=1)
    offs, blen = dot_block(ops)
    maccs = [o for o in ops if o.cls == "MACC"]
    others = [o for o in ops if o.cls != "MACC"]
    nM = sum(1 for o in others if o.slots == "M") + len(maccs)
    nS = sum(1 for o in others if o.slots == "S"); nAny = sum(1 for o in others if o.slots not in ("M", "S"))
    res_mii = max(nM, nS, (nM + nS + nAny + 1) // 2)
    order = sorted(others, key=lambda o: -height[id(o)])
    best = None
    for II in range(max(ii_min or 0, res_mii), ii_max):
        for T0 in range(t0_min, t0_min + II):
            r = try_ii(ops, others, maccs, offs, order, pred, succ, II, T0)
            if r == "ok":
                p.II = II; p.T0 = T0; p.res_mii = res_mii; p.block_len = blen
                p.length = max(o.cycle for o in ops) + 1
                p.stages = (p.length + II - 1) // II
                return p
            continue              # a deadline missed or a resource conflict: another T0 may work
        if verbose: print("II", II, "failed")
    raise ModError("no II found")

def try_ii(ops, others, maccs, offs, order, pred, succ, II, T0):
    for o in ops: o.cycle = None; o.slot = None
    slot = {"M": set(), "S": set()}; wport = {"M": set(), "S": set()}; obw = set(); adder = set(); divb = set()
    # the MACC block
    for o in maccs:
        c = T0 + offs[id(o)]
        m = c % II
        if m in slot["M"]: return "res"
        wc = c + WR["MACC"]
        if o.dst is not None and (wc % II) in wport["M"]: return "res"
        if o.ob is not None and (wc % II) in obw: return "res"
        if ((c + ADDER_TAKE["MACC"]) % II) in adder: return "res"
        o.cycle = c; o.slot = "M"
        slot["M"].add(m)
        if o.dst is not None: wport["M"].add(wc % II)
        if o.ob is not None: obw.add(wc % II)
        adder.add((c + ADDER_TAKE["MACC"]) % II)
    # MACC chains hold on to their accumulator (checked: the block is round robin, see dot_block)
    # deadlines for the producers feeding the block
    deadline = {}
    def need(q, by):
        if q is None or q.cls == "MACC": return
        if id(q) not in deadline or by < deadline[id(q)]: deadline[id(q)] = by
    # propagate deadlines backwards (latest start so that every MACC operand is readable in time)
    lst = {}
    for o in maccs:
        for v in o.srcs:
            if v.op is not None and v.op.cls != "MACC": need(v.op, o.cycle - LAT[v.op.cls])
        if o.flag_in and o.flag_in[0].op is not None: need(o.flag_in[0].op, o.cycle - 2)
    changed = True
    while changed:
        changed = False
        for o in others:
            if id(o) in deadline:
                for q in pred[id(o)]:
                    if q.cls == "MACC": continue
                    lim = deadline[id(o)] - lat_edge(q, o)
                    if id(q) not in deadline or lim < deadline[id(q)]:
                        deadline[id(q)] = lim; changed = True
    remaining = list(order)
    while remaining:
        # most urgent first: by deadline, then by height
        cand = [x for x in remaining if all(q.cycle is not None for q in pred[id(x)])]
        cand.sort(key=lambda x: (deadline.get(id(x), 10 ** 9), -1))
        o = cand[0]
        est = max([q.cycle + lat_edge(q, o) for q in pred[id(o)]], default=0)
        placed = False
        for c in range(est, est + II):
            if id(o) in deadline and c > deadline[id(o)]: return "late"
            m = c % II
            sls = sorted(o.slots, key=lambda x: x != "S") if o.cls == "ALU" else list(o.slots)
            for sl in sls:
                if not S.fits(o, sl) or m in slot[sl]: continue
                bank = "S" if (sl == "S" or o.cls == "DIV") else "M"
                wc = (c + WR[o.cls]) if o.cls in WR else None
                if o.dst is not None and wc is not None and (wc % II) in wport[bank]: continue
                if o.ob is not None and (wc % II) in obw: continue
                if o.cls in ADDER_TAKE and ((c + ADDER_TAKE[o.cls]) % II) in adder: continue
                if o.cls == "DIV" and any(((c + k) % II) in divb for k in range(DIV_BUSY)): continue
                o.cycle = c; o.slot = sl
                slot[sl].add(m)
                if o.dst is not None and wc is not None: wport[bank].add(wc % II)
                if o.ob is not None: obw.add(wc % II)
                if o.cls in ADDER_TAKE: adder.add((c + ADDER_TAKE[o.cls]) % II)
                if o.cls == "DIV":
                    for k in range(DIV_BUSY): divb.add((c + k) % II)
                placed = True
                break
            if placed: break
        if not placed: return "res"
        remaining.remove(o)
    # the MACCs' operands: every producer readable in time
    for o in maccs:
        for v in o.srcs:
            if v.op is not None and v.op.cls != "MACC" and v.op.cycle + LAT[v.op.cls] > o.cycle: return "late"
            if v.op is not None and v.op.cls == "MACC" and v.op.cycle + MACC_READ > o.cycle: return "late"
        if o.flag_in and o.flag_in[0].op is not None and o.flag_in[0].op.cycle + 2 > o.cycle: return "late"
    return "ok"

def allocate(p):
    """registers per bank, conflicts checked modulo II; a value whose lifetime is >= II gets a rotating register
    (two physical copies, chosen by the triangle's iteration parity).  Flags likewise."""
    II = p.II
    ops = [o for o in p.ops if o.code != "END"]
    for o in ops:
        if o.dst is not None: o.dst.readers = []
    for o in ops:
        for v in o.srcs:
            if v.op is not None: v.readers.append(o)
    vals = []
    for o in ops:
        v = o.dst
        if v is None or not v.readers: continue
        v.bank = "S" if (o.slot == "S" or o.cls == "DIV") else "M"
        v.wcycle = o.cycle + WR[o.cls]
        v.lastread = max(r.cycle for r in v.readers)
        if any(r.cycle < v.wcycle + 1 for r in v.readers): raise ModError(f"{v.name} read before written")
        vals.append(v)
    for bank in "MS":
        occ = collections.defaultdict(set)
        bv = sorted([v for v in vals if v.bank == bank], key=lambda v: -(v.lastread - v.wcycle))
        rot_next = 64
        for v in bv:
            span = v.lastread - v.wcycle
            if span >= II:
                if span >= 2 * II: raise ModError(f"{v.name}: lifetime {span} >= 2 II")
                if rot_next >= 128: raise ModError(f"bank {bank}: out of rotating registers")
                v.reg = rot_next; rot_next += 1
                continue
            cyc = {(v.wcycle + k) % II for k in range(span + 1)}
            for r in range(64):
                if not (occ[r] & cyc):
                    v.reg = r; occ[r] |= cyc; break
            else: raise ModError(f"bank {bank}: out of registers at {v.name}")
        setattr(p, f"regs_{bank}", (max([v.reg for v in bv if v.reg < 64], default=-1) + 1, rot_next - 64))
    fl = []
    for o in ops:
        if o.flag_out is not None:
            f = o.flag_out
            rd = [q for q in ops if (q.flag_in and q.flag_in[0] is f) or f in q.fmask]
            fl.append((o.cycle + 1, max([q.cycle + 1 for q in rd], default=o.cycle + 2), f))
    occ = collections.defaultdict(set); rot = 8
    for (w, r, f) in sorted(fl, key=lambda t: -(t[1] - t[0])):
        if r - w >= II:
            if rot >= 14: raise ModError("out of rotating flags")
            f.fidx = rot; rot += 1; continue
        cyc = {(w + k) % II for k in range(r - w + 1)}
        for k in range(8):
            if not (occ[k] & cyc):
                f.fidx = k; occ[k] |= cyc; break
        else: raise ModError("out of flags")
    return p

def report(p):
    ops = [o for o in p.ops if o.code != "END"]
    n = collections.Counter((o.slot, o.cls) for o in ops)
    st = collections.Counter(o.cycle // p.II for o in ops)
    return (f"kernel II {p.II} (resource bound {p.res_mii}), MACC block at {p.T0} ({p.block_len} clocks), {p.stages} "
            f"stages, one triangle spans {p.length} clocks; regs M {p.regs_M} S {p.regs_S} (plain, rotating); "
            f"ops per stage {dict(st)}; " + ", ".join(f"{s}.{c} {v}" for (s, c), v in sorted(n.items(), key=str)))

if __name__ == "__main__":
    import setup_prog, setup_isa
    p = setup_isa.P("kernel"); setup_prog.triangle(p, 0, 0); p.end()
    schedule(p); allocate(p)
    print(report(p))
