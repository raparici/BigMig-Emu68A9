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

# triangle setup program: RasterIX's rasterize() + increment(), bit-identical

import os
from setup_isa import P
NEG = os.environ.get("SETUP_NEG", "")      # negative controls (tb only): "assoc", "norebase"

def triangle(p, tri, bias):
    p.tri = tri; p.prio_bias = bias
    X = lambda v: p.rec_lo(6 * v)         # x, sign-extended from the record word's low half
    Y = lambda v: p.rec_hi(6 * v)
    W = lambda v, k: p.rec(6 * v + k)
    # ---- area = edgeFunctionX(v0, v1, v2) = (x2-x0)*(y1-y0) - (y2-y0)*(x1-x0); sign; culling of area 0
    dx20 = p.sub(X(2), X(0), "dx20"); dy10 = p.sub(Y(1), Y(0), "dy10")
    dy20 = p.sub(Y(2), Y(0), "dy20"); dx10 = p.sub(X(1), X(0), "dx10")
    area = p.sub(p.imul(dx20, dy10, "a1"), p.imul(dy20, dx10, "a2"), "area")
    fneg = p.flag_le0(area, "F_NEG")                       # sign = (area <= 0) ? -1 : 1
    aabs = p.neg_if(area, fneg, "aabs")                     # area *= sign
    fzero = p.flag_le0(aabs, "F_ZERO")                      # if (area <= 0) return false
    # ---- bounding box: Sn.4 + 0.5 / + 1.5, then >> 4 (clamped to [0, 2047]: a no-op inside the library's domain)
    minx = p.imin(p.imin(X(0), X(1)), X(2), "minx"); maxx = p.imax(p.imax(X(0), X(1)), X(2), "maxx")
    miny = p.imin(p.imin(Y(0), Y(1)), Y(2), "miny"); maxy = p.imax(p.imax(Y(0), Y(1)), Y(2), "maxy")
    sbsx = p.addk(minx, 8, "sbsx"); sbsy = p.addk(miny, 8, "sbsy")
    sbex = p.addk(maxx, 24, "sbex"); sbey = p.addk(maxy, 24, "sbey")
    bsx = p.bbx(sbsx, "bsx"); bsy = p.bbx(sbsy, "bsy"); bex = p.bbx(sbex, "bex"); bey = p.bbx(sbey, "bey")
    # BigMig guard band: a box ending right of the target ends at RESX (outside the library's domain only)
    bex = p.min_if(bex, p.state("RESX"), p.flag_gt(maxx, p.state("RESX16"), "F_GX"), "bexc")
    # ---- scissor (culls only), the band (isInBounds), area 0 -> the triangle is dropped from this band
    sc = p.state_flag("SCISSOR")
    fsx = p.flag_ge(p.imax(sbsx, p.state("SCX0")), p.imin(sbex, p.state("SCX1")), "F_SCX", gate=sc)
    fsy = p.flag_ge(p.imax(sbsy, p.state("SCY0")), p.imin(sbey, p.state("SCY1")), "F_SCY", gate=sc)
    fab = p.flag_lt(bey, p.state("YOFF"), "F_ABOVE")
    fbe = p.flag_ge(bsy, p.state("YEND"), "F_BELOW")
    p.mark_drop([fzero, fsx, fsy, fab, fbe])
    p.ob_int(1, p.pack16(bsx, bsy, "bb0")); p.ob_int(2, p.pack16(bexc_ := bex, bey, "bb1"))
    # ---- edge functions at p = (bsx, bsy) << 4; increments
    dy21 = p.sub(Y(2), Y(1), "dy21"); dx21 = p.sub(X(2), X(1), "dx21")
    dy02 = p.sub(Y(0), Y(2), "dy02"); dx02 = p.sub(X(0), X(2), "dx02")
    e1x = p.subs4(bsx, X(1), "ex1"); e1y = p.subs4(bsy, Y(1), "ey1")
    e2x = p.subs4(bsx, X(2), "ex2"); e2y = p.subs4(bsy, Y(2), "ey2")
    e0x = p.subs4(bsx, X(0), "ex0"); e0y = p.subs4(bsy, Y(0), "ey0")
    w0 = p.sub(p.imul(e1x, dy21, "w0a"), p.imul(e1y, dx21, "w0b"), "w0")
    w1 = p.sub(p.imul(e2x, dy02, "w1a"), p.imul(e2y, dx02, "w1b"), "w1")
    w2 = p.sub(p.imul(e0x, dy10, "w2a"), p.imul(e0y, dx10, "w2b"), "w2")
    wi = [p.neg_if(w, fneg, f"wi{k}") for k, w in enumerate((w0, w1, w2))]
    # wIncX = (y2-y1, y0-y2, y1-y0) * 16 * sign; wIncY = (x1-x2, x2-x0, x0-x1) * 16 * sign
    wx = [p.shl4_neg_if(d, fneg, False, f"wx{k}") for k, d in enumerate((dy21, dy02, dy10))]
    wy = [p.shl4_neg_if(dx21, fneg, True, "wy0"), p.shl4_neg_if(dx20, fneg, False, "wy1"),
          p.shl4_neg_if(dx10, fneg, True, "wy2")]
    for k in range(3):
        p.ob_int(6 + k, wx[k]); p.ob_int(9 + k, wy[k])
    # ---- the barycentric weights: (float)wi * areaInv, areaInv = 1.0f / area
    ainv = p.fdiv(p.const_f(1.0), p.i2f(aabs, "fa"), "areaInv")
    wn = [p.fmul(p.i2f(wi[k], f"fw{k}"), ainv, f"n{k}") for k in range(3)]
    xn = [p.fmul(p.i2f(wx[k], f"fx{k}"), ainv, f"xn{k}") for k in range(3)]
    yn = [p.fmul(p.i2f(wy[k], f"fy{k}"), ainv, f"yn{k}") for k in range(3)]
    # ---- RasterIX's attribute scaling: w = normalize(w): tmp = 0 + w0*w0 + w1*w1 + w2*w2 (0 + x == x exactly),
    #      max(sqrtf(tmp), 1e-30f), 1.0f / that, w * it
    q = [p.fsqr(W(v, 2), f"q{v}") for v in range(3)]
    ln = p.fmax(p.fsqrt(p.fadd(p.fadd(q[0], q[1], "l01"), q[2], "len2"), "len"), p.const_f(1e-30), "lenc")
    kk = p.fdiv(p.const_f(1.0), ln, "k")
    wnv = [p.fmul(W(v, 2), kk, f"wn{v}") for v in range(3)]
    # ---- texture coordinates: the integer offset when outside [-4, 4], then s * wn, t * wn, q * wn (q = 1)
    s = [W(v, 3) for v in range(3)]; t = [W(v, 4) for v in range(3)]
    mins = p.fmin(s[0], p.fmin(s[1], s[2]), "minS"); mint = p.fmin(t[0], p.fmin(t[1], t[2]), "minT")
    maxs = p.fmax(s[0], p.fmax(s[1], s[2]), "maxS"); maxt = p.fmax(t[0], p.fmax(t[1], t[2]), "maxT")
    k1 = p.ftrunc_if_lt(mins, -4.0, "K1"); k2 = p.ftrunc_if_lt(mint, -4.0, "K2")
    k3 = p.ftrunc_if_gt(maxs, 4.0, "K3"); k4 = p.ftrunc_if_gt(maxt, 4.0, "K4")
    S = [p.fmul(p.fsub(p.fsub(s[v], k1), k3, f"s'{v}"), wnv[v], f"S{v}") for v in range(3)]
    T = [p.fmul(p.fsub(p.fsub(t[v], k2), k4, f"t'{v}"), wnv[v], f"T{v}") for v in range(3)]
    Q = wnv
    # ---- colours (RGBA8888 -> byte * (1.0f / 255.0f), the library's own mapping) and depth (u2.30)
    col = [[p.lut(W(v, 5), 3 - c, f"c{v}{'rgba'[c]}") for c in range(4)] for v in range(3)]
    z = [p.u30(W(v, 1), f"z{v}") for v in range(3)]
    iw = [W(v, 2) for v in range(3)]
    # ---- the 27 dot products ((a0 * w0) + (a1 * w1)) + (a2 * w2), and increment()'s re-base for this band
    attrs = [(12, 16, 20, [col[v][0] for v in range(3)]), (13, 17, 21, [col[v][1] for v in range(3)]),
             (14, 18, 22, [col[v][2] for v in range(3)]), (15, 19, 23, [col[v][3] for v in range(3)]),
             (24, 26, 28, z), (25, 27, 29, iw),
             (30, 33, 36, S), (31, 34, 37, T), (32, 35, 38, Q)]
    frb = p.flag_lt(bsy, p.state("YOFF"), "F_REBASE")       # bbStartY < lineStart (line 0 never re-bases: bsy >= 0)
    if NEG == "norebase": frb = p.flag_lt(p.state("YOFF"), p.const_i(0), "F_REBASE")   # never
    bbd = p.sub(p.state("YOFF"), bsy, "bbDiff")
    fd = p.i2f(bbd, "fd")
    for (ws, wxw, wyw, a) in attrs:
        p.dot3(a, xn, ob=wxw, name=f"X{ws}")
        yi = p.dot3(a, yn, ob=wyw, keep=True, name=f"Y{ws}")
        st = p.dot3(a, wn, keep_acc=True, name=f"S{ws}")
        p.macc_rebase(st, yi, fd, frb, ob=ws, name=f"R{ws}")    # start (+ yInc * bbDiff when re-based)
    for k in range(3):                                          # wInit (+ wYInc * bbDiff when re-based)
        p.ob_int(3 + k, p.add_if(wi[k], p.imul(wy[k], bbd, f"wr{k}"), frb, f"wiR{k}"))
    p.ob_int(0, p.const_i(0))
    p.done()

def build(pair=False):
    p = P("pair" if pair else "single")
    triangle(p, 0, 1000 if pair else 0)
    if pair:
        triangle(p, 1, 0)
    p.end()
    return p
