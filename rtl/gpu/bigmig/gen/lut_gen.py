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

# triangle setup colour table: byte * (1.0f / 255.0f), IEEE single, round-to-nearest-even

from fractions import Fraction
import struct, sys, os

def rne_single(q: Fraction) -> int:
    """the binary32 bit pattern of q rounded to nearest even (normal range only, q >= 0)"""
    if q == 0: return 0
    e = 0
    while q >= 2: q /= 2; e += 1
    while q < 1: q *= 2; e -= 1
    m = q * (1 << 23)                     # in [2^23, 2^24)
    fl = m.numerator // m.denominator
    rem = m - fl
    if rem > Fraction(1, 2) or (rem == Fraction(1, 2) and (fl & 1)): fl += 1
    if fl == (1 << 24): fl >>= 1; e += 1
    return ((e + 127) << 23) | (fl - (1 << 23))

def val(bits):
    s = (bits >> 31) & 1; e = (bits >> 23) & 0xFF; f = bits & 0x7FFFFF
    if e == 0: return Fraction(0)
    v = Fraction((1 << 23) | f, 1 << 23) * (Fraction(2) ** (e - 127))
    return -v if s else v

k = rne_single(Fraction(1, 255))
kv = val(k)
out = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "bm_setup_lut.hex")
with open(out, "w") as f:
    for b in range(256):
        f.write("%08x\n" % rne_single(b * kv))
print("1.0f/255.0f = %08x" % k, "255 -> %08x" % rne_single(255 * kv), "(the C float check is in the testbench)")
