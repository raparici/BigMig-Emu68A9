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

// MiSTer's f2sdram_safe_terminator (bellwood420) with an exact beat count: drop-in for the GPU's port

module bigmig_f2sdram_terminator #(
	parameter     DATA_WIDTH = 64,
	parameter     BURSTCOUNT_WIDTH = 8
) (
	input         clk,
	input         rst_req_sync,

	// Master port: connecting to Avalon-MM slave (f2sdram)
	input                         waitrequest_master,
	output [BURSTCOUNT_WIDTH-1:0] burstcount_master,
	output    [ADDRESS_WITDH-1:0] address_master,
	input        [DATA_WIDTH-1:0] readdata_master,
	input                         readdatavalid_master,
	output                        read_master,
	output       [DATA_WIDTH-1:0] writedata_master,
	output [BYTEENABLE_WIDTH-1:0] byteenable_master,
	output                        write_master,

	// Slave port: connecting to Avalon-MM master (user logic)
	output                        waitrequest_slave,
	input  [BURSTCOUNT_WIDTH-1:0] burstcount_slave,
	input     [ADDRESS_WITDH-1:0] address_slave,
	output       [DATA_WIDTH-1:0] readdata_slave,
	output                        readdatavalid_slave,
	input                         read_slave,
	input        [DATA_WIDTH-1:0] writedata_slave,
	input  [BYTEENABLE_WIDTH-1:0] byteenable_slave,
	input                         write_slave
);

localparam BYTEENABLE_WIDTH = DATA_WIDTH/8;
localparam ADDRESS_WITDH    = 32-$clog2(BYTEENABLE_WIDTH);
localparam [BURSTCOUNT_WIDTH-1:0] ONE = 1;

// the first reset after power-up is not one to act on (nothing was started): as the stock module
reg init_reset_deasserted = 1'b0;
always @(posedge clk) if (!rst_req_sync) init_reset_deasserted <= 1'b1;

// the reset's first clock (after that, lock_stage holds until the reset goes)
reg  lock_stage = 1'b0;
wire take = rst_req_sync && init_reset_deasserted && !lock_stage;
always @(posedge clk) lock_stage <= rst_req_sync && init_reset_deasserted;

// the exact write tracker: beats the port accepts while the user logic owns the bus
reg                         terminating = 1'b0;     // the bus is the terminator's
reg                         read_terminating = 1'b0, write_terminating = 1'b0;
reg                         w_open = 1'b0;          // a write burst is open: its first beat taken, more owed
reg  [BURSTCOUNT_WIDTH-1:0] w_left = 0;             // beats the open burst still owes
reg  [BURSTCOUNT_WIDTH-1:0] w_bc = 0;
reg    [ADDRESS_WITDH-1:0]  w_addr = 0;
wire                        w_beat = !terminating && write_slave && !waitrequest_master;
wire [BURSTCOUNT_WIDTH-1:0] w_left_next = w_open ? (w_beat ? w_left - ONE : w_left)
                                                 : (w_beat ? burstcount_slave - ONE : {BURSTCOUNT_WIDTH{1'b0}});

reg  [BURSTCOUNT_WIDTH-1:0] term_left = 0;          // beats the terminator still owes the port
reg  [BURSTCOUNT_WIDTH-1:0] burstcount_latch = 0;
reg    [ADDRESS_WITDH-1:0]  address_latch = 0;

always @(posedge clk) begin
	// track the user logic's write bursts (only while it owns the bus)
	if (w_beat) begin
		if (!w_open) begin
			w_bc   <= burstcount_slave;
			w_addr <= address_slave;
		end
		w_open <= w_left_next != 0;
		w_left <= w_left_next;
	end

	// the terminator's own beats: each counted when the port takes it
	if (write_terminating && !waitrequest_master) begin
		term_left <= term_left - ONE;
		if (term_left == ONE) write_terminating <= 1'b0;
	end
	if (read_terminating && !waitrequest_master) read_terminating <= 1'b0;

	if (take && !terminating) begin
		// take the bus from the next clock on, owing exactly what the user logic left unfinished
		terminating      <= 1'b1;
		burstcount_latch <= w_open ? w_bc   : burstcount_slave;
		address_latch    <= w_open ? w_addr : address_slave;
		if (w_left_next != 0) begin
			// a burst in its middle, or one whose first beat the port takes in this very clock
			write_terminating <= 1'b1;
			term_left         <= w_left_next;
		end
		else if (!w_open && write_slave && waitrequest_master) begin
			// a burst presented, its first beat not taken yet: present it until taken, then complete it whole
			write_terminating <= 1'b1;
			term_left         <= burstcount_slave;
		end
		else if (read_slave && waitrequest_master) begin
			// a read command presented, not taken yet: hold it until taken (its data comes back by itself)
			read_terminating  <= 1'b1;
		end
		w_open <= 1'b0;
		w_left <= {BURSTCOUNT_WIDTH{1'b0}};
	end
	else if (terminating && !rst_req_sync && !write_terminating && !read_terminating)
		terminating <= 1'b0;            // the reset has gone and nothing is owed: the bus goes back
end

assign burstcount_master = terminating ? burstcount_latch : burstcount_slave;
assign address_master    = terminating ? address_latch    : address_slave;
assign read_master       = terminating ? read_terminating  : read_slave;
assign write_master      = terminating ? write_terminating : write_slave;
assign byteenable_master = terminating ? {BYTEENABLE_WIDTH{1'b0}} : byteenable_slave;

// just passing master <-> slave
assign writedata_master    = writedata_slave;
assign readdata_slave      = readdata_master;
assign readdatavalid_slave = readdatavalid_master;
assign waitrequest_slave   = waitrequest_master;

endmodule
