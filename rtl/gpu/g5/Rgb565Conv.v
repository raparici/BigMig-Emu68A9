// Copyright 2026 Ruben Aparicio
//
// This file is part of BigMig
//
// BigMig is free software; you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation; either version 3 of the License, or
// (at your option) any later version.
//
// BigMig is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.

// RGB565 <-> RGB888 for the colour buffer

`timescale 1ns / 1ps
module Rgb565Pack (
    input  wire [23 : 0]    rgb888,     // R [23:16], G [15:8], B [7:0]
    output wire [15 : 0]    rgb565      // R [15:11], G [10:5], B [4:0]
);
    assign rgb565 = { rgb888[23 : 19], rgb888[15 : 10], rgb888[7 : 3] };
endmodule

module Rgb565Unpack (
    input  wire [15 : 0]    rgb565,
    output wire [23 : 0]    rgb888
);
    assign rgb888 = { rgb565[15 : 11], rgb565[15 : 13], rgb565[10 : 5], rgb565[10 : 9], rgb565[4 : 0], rgb565[4 : 2] };
endmodule
