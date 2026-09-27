//============================================================================
//
//  MiSTer hardware abstraction module
//  (c)2017-2020 Alexey Melnikov
//
//  This program is free software; you can redistribute it and/or modify it
//  under the terms of the GNU General Public License as published by the Free
//  Software Foundation; either version 2 of the License, or (at your option)
//  any later version.
//
//  This program is distributed in the hope that it will be useful, but WITHOUT
//  ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
//  FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for
//  more details.
//
//  You should have received a copy of the GNU General Public License along
//  with this program; if not, write to the Free Software Foundation, Inc.,
//  51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
//
//============================================================================

module sys_top
(
	/////////// CLOCK //////////
	input         FPGA_CLK1_50,
	input         FPGA_CLK2_50,
	input         FPGA_CLK3_50,

	//////////// HDMI //////////
	output        HDMI_I2C_SCL,
	inout         HDMI_I2C_SDA,

	output        HDMI_MCLK,
	output        HDMI_SCLK,
	output        HDMI_LRCLK,
	output        HDMI_I2S,

	output        HDMI_TX_CLK,
	output        HDMI_TX_DE,
	output [23:0] HDMI_TX_D,
	output        HDMI_TX_HS,
	output        HDMI_TX_VS,
	
	input         HDMI_TX_INT,

	//////////// SDR ///////////
	output [12:0] SDRAM_A,
	inout  [15:0] SDRAM_DQ,
	output        SDRAM_DQML,
	output        SDRAM_DQMH,
	output        SDRAM_nWE,
	output        SDRAM_nCAS,
	output        SDRAM_nRAS,
	output        SDRAM_nCS,
	output  [1:0] SDRAM_BA,
	output        SDRAM_CLK,
	output        SDRAM_CKE,

`ifdef MISTER_DUAL_SDRAM
	////////// SDR #2 //////////
	output [12:0] SDRAM2_A,
	inout  [15:0] SDRAM2_DQ,
	output        SDRAM2_nWE,
	output        SDRAM2_nCAS,
	output        SDRAM2_nRAS,
	output        SDRAM2_nCS,
	output  [1:0] SDRAM2_BA,
	output        SDRAM2_CLK,

`else
	//////////// VGA ///////////
	output  [5:0] VGA_R,
	output  [5:0] VGA_G,
	output  [5:0] VGA_B,
	inout         VGA_HS,
	output		  VGA_VS,
	input         VGA_EN,  // active low

	/////////// AUDIO //////////
	output		  AUDIO_L,
	output		  AUDIO_R,
	output		  AUDIO_SPDIF,

	//////////// SDIO ///////////
	inout   [3:0] SDIO_DAT,
	inout         SDIO_CMD,
	output        SDIO_CLK,

	//////////// I/O ///////////
	output        LED_USER,
	output        LED_HDD,
	output        LED_POWER,
	input         BTN_USER,
	input         BTN_OSD,
	input         BTN_RESET,
`endif

	////////// I/O ALT /////////
	output        SD_SPI_CS,
	input         SD_SPI_MISO,
	output        SD_SPI_CLK,
	output        SD_SPI_MOSI,

	inout         SDCD_SPDIF,
	output        IO_SCL,
	inout         IO_SDA,

	////////// ADC //////////////
	output        ADC_SCK,
	input         ADC_SDO,
	output        ADC_SDI,
	output        ADC_CONVST,

	////////// MB KEY ///////////
	input   [1:0] KEY,

	////////// MB SWITCH ////////
	input   [3:0] SW,

	////////// MB LED ///////////
	output  [7:0] LED,

	///////// USER IO ///////////
	inout   [6:0] USER_IO
);

//////////////////////  Secondary SD  ///////////////////////////////////
wire SD_CS, SD_CLK, SD_MOSI, SD_MISO, SD_CD;

`ifndef MISTER_DUAL_SDRAM
	wire   sd_cd       = SDCD_SPDIF & ~SW[2]; // SW[2]=ON workaround for faulty boards without SD card detect pin.
	assign SD_CD       = mcp_en ? mcp_sdcd : sd_cd;
	assign SD_MISO     = SD_CD | (mcp_en ? SD_SPI_MISO : (VGA_EN | SDIO_DAT[0]));
	assign SD_SPI_CS   = mcp_en ?  (mcp_sdcd  ? 1'bZ : SD_CS) : (sog & ~cs1 & ~VGA_EN) ? 1'b1 : 1'bZ;
	assign SD_SPI_CLK  = (~mcp_en | mcp_sdcd) ? 1'bZ : SD_CLK;
	assign SD_SPI_MOSI = (~mcp_en | mcp_sdcd) ? 1'bZ : SD_MOSI;
	assign {SDIO_CLK,SDIO_CMD,SDIO_DAT} = av_dis ? 6'bZZZZZZ : (mcp_en | sd_cd) ? {vga_g,vga_r,vga_b} : {SD_CLK,SD_MOSI,SD_CS,3'bZZZ};
`else
	assign SD_CD       = mcp_sdcd;
	assign SD_MISO     = mcp_sdcd | SD_SPI_MISO;
	assign SD_SPI_CS   = mcp_sdcd ? 1'bZ : SD_CS;
	assign SD_SPI_CLK  = mcp_sdcd ? 1'bZ : SD_CLK;
	assign SD_SPI_MOSI = mcp_sdcd ? 1'bZ : SD_MOSI;
`endif

//////////////////////  LEDs/Buttons  ///////////////////////////////////

reg [7:0] led_overtake = 0;
reg [7:0] led_state    = 0;

wire led_p =  led_power[1] ? ~led_power[0] : 1'b0;
wire led_d =  led_disk[1]  ? ~led_disk[0]  : ~(led_disk[0] | gp_out[29]);
wire led_u = ~led_user;
wire led_locked;

//LEDs on de10-nano board
assign LED = (led_overtake & led_state) | (~led_overtake & {1'b0,led_locked,1'b0, ~led_p, 1'b0, ~led_d, 1'b0, ~led_u});

wire [2:0] mcp_btn;
wire       mcp_sdcd;
wire       mcp_en;
wire       mcp_mode;
mcp23009 mcp23009
(
	.clk(FPGA_CLK2_50),

	.btn(mcp_btn),
	.led({led_p, led_d, led_u}),
	.flg_sd_cd(mcp_sdcd),
	.flg_present(mcp_en),
	.flg_mode(mcp_mode),

	.scl(IO_SCL),
	.sda(IO_SDA)
);

wire io_dig = mcp_en ? mcp_mode : SW[3];

`ifndef MISTER_DUAL_SDRAM
	wire   av_dis    = io_dig | VGA_EN;
	assign LED_POWER = av_dis ? 1'bZ : mcp_en ? de1          : led_p ? 1'bZ : 1'b0;
	assign LED_HDD   = av_dis ? 1'bZ : mcp_en ? (sog & ~cs1) : led_d ? 1'bZ : 1'b0;
	//assign LED_USER  = av_dis ? 1'bZ : mcp_en ? ~vga_tx_clk  : led_u ? 1'bZ : 1'b0;
	assign LED_USER  = VGA_TX_CLK;
	wire   BTN_DIS   = VGA_EN;
`else
	wire   BTN_RESET = 1'b1;
	wire   BTN_OSD   = 1'b1;
	wire   BTN_USER  = 1'b1;
	wire   BTN_DIS   = 1'b1;
`endif

reg BTN_EN = 0;
reg [25:0] btn_timeout = 0;
initial btn_timeout = 0;
always @(posedge FPGA_CLK2_50) begin
	reg btn_up = 0;
	reg btn_en = 0;

	btn_up <= BTN_RESET & BTN_OSD & BTN_USER;
	if(~reset & btn_up & ~&btn_timeout) btn_timeout <= btn_timeout + 1'd1;
	btn_en <= ~BTN_DIS;
	BTN_EN <= &btn_timeout & btn_en;
end

wire btn_r = (mcp_en | SW[3]) ? mcp_btn[1] : (BTN_EN & ~BTN_RESET);
wire btn_o = (mcp_en | SW[3]) ? mcp_btn[2] : (BTN_EN & ~BTN_OSD  );
wire btn_u = (mcp_en | SW[3]) ? mcp_btn[0] : (BTN_EN & ~BTN_USER );

reg btn_user, btn_osd;
always @(posedge FPGA_CLK2_50) begin
	integer div;
	reg [7:0] deb_user;
	reg [7:0] deb_osd;

	div <= div + 1'b1;
	if(div > 100000) div <= 0;

	if(!div) begin
		deb_user <= {deb_user[6:0], btn_u | ~KEY[1]};
		if(&deb_user) btn_user <= 1;
		if(!deb_user) btn_user <= 0;

		deb_osd <= {deb_osd[6:0], btn_o | ~KEY[0]};
		if(&deb_osd) btn_osd <= 1;
		if(!deb_osd) btn_osd <= 0;
	end
end

/////////////////////////  HPS I/O  /////////////////////////////////////

// gp_in[31] = 0 - quick flag that FPGA is initialized (HPS reads 1 when FPGA is not in user mode)
//                 used to avoid lockups while JTAG loading
wire [31:0] gp_in = {1'b0, btn_user | btn[1], btn_osd | btn[0], io_dig, 7'd0, ~HDMI_TX_INT, io_ver, io_ack, io_wide, io_dout | io_dout_sys};
wire [31:0] gp_out;

wire  [1:0] io_ver = 1; // 0 - obsolete. 1 - optimized HPS I/O. 2,3 - reserved for future.
wire        io_wait;
wire        io_wide;
wire [15:0] io_dout;
wire [15:0] io_din = gp_outr[15:0];
wire        io_clk = gp_outr[17];
wire        io_ss0 = gp_outr[18];
wire        io_ss1 = gp_outr[19];
wire        io_ss2 = gp_outr[20];

`ifndef MISTER_DEBUG_NOHDMI
	wire io_osd_hdmi = io_ss1 & ~io_ss0;
`endif

wire io_fpga     = ~io_ss1 & io_ss0;
wire io_uio      = ~io_ss1 & io_ss2;

reg  io_ack;
reg  rack;
wire io_strobe = ~rack & io_clk;

always @(posedge clk_sys) begin
	if(~(io_wait | vs_wait) | io_strobe) begin
		rack <= io_clk;
		io_ack <= rack;
	end
end

reg [31:0] gp_outr;
always @(posedge clk_sys) begin
	reg [31:0] gp_outd;
	gp_outr <= gp_outd;
	gp_outd <= gp_out;
end

`ifdef MISTER_DUAL_SDRAM
	wire  [7:0] core_type  = 'hA8; // generic core, dual SDRAM.
`else
	wire  [7:0] core_type  = 'hA4; // generic core.
`endif

// HPS will not communicate to core if magic is different
wire [31:0] core_magic = {24'h5CA623, core_type};

cyclonev_hps_interface_mpu_general_purpose h2f_gp
(
	.gp_in({~gp_out[31] ? core_magic : gp_in}),
	.gp_out(gp_out)
);


reg [15:0] cfg;
reg        cfg_set      = 0;

// SPLIT THE `vga_force_scaler` FAN-OUT: the core's "a framebuffer is the picture" request must
// reach the HDMI socket but NOT the analog RGB DAC. Upstream sends VGA_SCALER to both, and the
// second effect is a CRT hazard -- a 15.6 kHz set asked to follow the HDMI mode's 45-75 kHz for
// as long as the RTG screen is up.
//
//   vga_fb      = cfg[12] | vga_force_scaler   <- HDMI socket path, keeps the force
//   vga_fb_ini  = cfg[12]                      <- the ini-only twin, for the analog side
//   vga_scaler  = cfg[2]                       <- analog path, force term removed
//
// so nothing the core does can put scaler timing on the analog pins. Users who want it there
// still have MiSTer.ini `vga_scaler=1`, which outranks the blank as before.
`ifdef MISTER_DEBUG_NOHDMI
	wire    vga_fb       = 0;
	wire    vga_fb_ini   = 0;
	wire    direct_video = 1;
`else
	wire    vga_fb       = cfg[12] | vga_force_scaler;
	wire    vga_fb_ini   = cfg[12];
	wire    direct_video = cfg[10];
`endif

wire       audio_96k    = cfg[6];
wire       csync_en     = cfg[3];
wire       io_osd_vga   = io_ss1 & ~io_ss2;
`ifndef MISTER_DUAL_SDRAM
	wire forced_scandoubler = cfg[4];
	wire ypbpr_en           = cfg[5];
	wire sog                = cfg[9];
	`ifdef MISTER_DEBUG_NOHDMI
		wire vga_scaler   = 0;
	`else
		// `| vga_force_scaler` removed here -- see the block comment at the vga_fb declaration.
		// This is purely "the user asked for the scaler on the analog output in MiSTer.ini".
		wire vga_scaler   = cfg[2];
	`endif
`endif

reg        cfg_custom_t = 0;
reg  [5:0] cfg_custom_p1;
reg [31:0] cfg_custom_p2;

reg  [4:0] vol_att;
initial vol_att = 5'b11111;
reg  [1:0] vol_boost = 0;

reg  [11:0] coef_addr;
reg  [9:0] coef_data;
reg        coef_wr = 0;

wire[12:0] ARX, ARY;
reg [11:0] VSET = 0, HSET = 0;
reg        FREESCALE = 0;
reg  [2:0] scaler_flt;
reg        lowlat = 0;
reg        cfg_done = 0;

reg        vs_wait = 0;
reg [11:0] vs_line = 0;

reg        scaler_out = 0;
reg        vrr_mode = 0;
wire       hdmi_blackout;

reg [31:0] aflt_rate = 7056000;
reg [39:0] acx  = 4258969;
reg  [7:0] acx0 = 3;
reg  [7:0] acx1 = 3;
reg  [7:0] acx2 = 1;
reg [23:0] acy0 = -24'd6216759;
reg [23:0] acy1 =  24'd6143386;
reg [23:0] acy2 = -24'd2023767;
reg        areset = 0;
reg [12:0] arc1x = 0;
reg [12:0] arc1y = 0;
reg [12:0] arc2x = 0;
reg [12:0] arc2y = 0;
reg [15:0] io_dout_sys;

always@(posedge clk_sys) begin
	reg  [7:0] cmd;
	reg        has_cmd;
	reg  [7:0] cnt = 0;
	reg        vs_d0,vs_d1,vs_d2;
	reg  [4:0] acx_att;
	reg  [7:0] fb_crc;
	reg  [1:0] sl_r;

	coef_wr <= 0;
	sl_r <= FB_EN ? 2'b00 : scanlines;

`ifndef MISTER_DEBUG_NOHDMI
	shadowmask_wr <= 0;
`endif

	if(~io_uio) begin
		has_cmd <= 0;
		cmd <= 0;
		areset <= 0;
		acx_att <= 0;
		acx <= acx >> acx_att;
		io_dout_sys <= 0;
	end
	else
	if(io_strobe) begin
		io_dout_sys <= 0;
		if(!has_cmd) begin
			has_cmd <= 1;
			cmd <= io_din[7:0];
			cnt <= 0;
			if(io_din[7:0] == 'h30) vs_wait <= 1;
			if(io_din[7:0] == 'h39) begin
				aflt_rate <= 7056000;
				acx  <= 4258969;
				acx0 <= 3;
				acx1 <= 3;
				acx2 <= 1;
				acy0 <= -24'd6216759;
				acy1 <=  24'd6143386;
				acy2 <= -24'd2023767;
				areset <= 1;
				io_dout_sys <= 'b11;
			end
			if(io_din[7:0] == 'h20) io_dout_sys <= 'b11;
`ifdef MISTER_DISABLE_ADAPTIVE
			if(io_din[7:0] == 'h2B) io_dout_sys <= {fb_en, sl_r, 4'b0110};
`else
			if(io_din[7:0] == 'h2B) io_dout_sys <= {fb_en, sl_r, 4'b0111};
`endif
			if(io_din[7:0] == 'h2F) io_dout_sys <= 1;
			if(io_din[7:0] == 'h3E) io_dout_sys <= 1;
`ifndef MISTER_DEBUG_NOHDMI
			if(io_din[7:0] == 'h40) io_dout_sys <= fb_crc;
`endif
			if(io_din[7:0] == 'h42) io_dout_sys <= {1'b1, frame_cnt};
			if(io_din[7:0] == 'h44) io_dout_sys <= 1;
		end
		else begin
			cnt <= cnt + 1'd1;
			if(cmd == 1) begin
				cfg <= io_din;
				cfg_set <= 1;
				scaler_out <= 1;
			end
			if(cmd == 'h20) begin
				cfg_set <= 0;
				if(cnt<8) begin
					case(cnt[2:0])
						0: {HDMI_PR,vrr_mode,WIDTH} <= {io_din[15:14], io_din[11:0]};
						1: HFP    <= io_din[11:0];
						2: HS     <= {io_din[15], io_din[11:0]};
						3: HBP    <= io_din[11:0];
						4: HEIGHT <= io_din[11:0];
						5: VFP    <= io_din[11:0];
						6: VS     <= {io_din[15],io_din[11:0]};
						7: VBP    <= io_din[11:0];
					endcase
`ifndef MISTER_DEBUG_NOHDMI
					if(cnt == 1) begin
						cfg_custom_p1 <= 0;
						cfg_custom_p2 <= 0;
						cfg_custom_t <= ~cfg_custom_t;
					end
				end
				else begin
					if(cnt[1:0]==0) cfg_custom_p1 <= io_din[5:0];
					if(cnt[1:0]==1) cfg_custom_p2[15:0]  <= io_din;
					if(cnt[1:0]==2) begin
						cfg_custom_p2[31:16] <= io_din;
						cfg_custom_t <= ~cfg_custom_t;
						cnt[2:0] <= 3'b100;
					end
					if(cnt == 8) {lowlat,cfg_done} <= {io_din[15],1'b1};
`endif
				end
			end
			if(cmd == 'h2F) begin
				case(cnt[3:0])
					0: {LFB_EN,LFB_FLT,LFB_FMT} <= {io_din[15], io_din[14], io_din[5:0]};
					1: LFB_BASE[15:0]  <= io_din[15:0];
					2: LFB_BASE[31:16] <= io_din[15:0];
					3: LFB_WIDTH       <= io_din[11:0];
					4: LFB_HEIGHT      <= io_din[11:0];
					5: LFB_HMIN        <= io_din[11:0];
					6: LFB_HMAX        <= io_din[11:0];
					7: LFB_VMIN        <= io_din[11:0];
					8: LFB_VMAX        <= io_din[11:0];
					9: LFB_STRIDE      <= io_din[13:0];
				endcase
			end
			if(cmd == 'h25) {led_overtake, led_state} <= io_din;
			if(cmd == 'h26) vol_att <= io_din[4:0];
			if(cmd == 'h27) VSET <= io_din[11:0];
			if(cmd == 'h2A) begin
				if(cnt[0]) {coef_wr,coef_data} <= {1'b1,io_din[9:0]};
				else coef_addr <= io_din[11:0];
			end
			if(cmd == 'h2B) scaler_flt <= io_din[2:0];
			if(cmd == 'h37) {FREESCALE,HSET} <= {io_din[15],io_din[11:0]};
			if(cmd == 'h38) vs_line <= io_din[11:0];
			if(cmd == 'h39) begin
				case(cnt[3:0])
					 0: {vol_boost,acx_att} <= io_din[6:0];
					 1: aflt_rate[15:0]  <= io_din;
					 2: aflt_rate[31:16] <= io_din;
					 3: acx[15:0]        <= io_din;
					 4: acx[31:16]       <= io_din;
					 5: acx[39:32]       <= io_din[7:0];
					 6: acx0             <= io_din[7:0];
					 7: acx1             <= io_din[7:0];
					 8: acx2             <= io_din[7:0];
					 9: acy0[15:0]       <= io_din;
					10: acy0[23:16]      <= io_din[7:0];
					11: acy1[15:0]       <= io_din;
					12: acy1[23:16]      <= io_din[7:0];
					13: acy2[15:0]       <= io_din;
					14: acy2[23:16]      <= io_din[7:0];
				endcase
			end
			if(cmd == 'h3A) begin
				case(cnt[3:0])
					 0: arc1x <= io_din[12:0];
					 1: arc1y <= io_din[12:0];
					 2: arc2x <= io_din[12:0];
					 3: arc2y <= io_din[12:0];
				endcase
			end
`ifndef MISTER_DEBUG_NOHDMI
			if(cmd == 'h3E) {shadowmask_wr,shadowmask_data} <= {1'b1, io_din};
			if(cmd == 'h40) begin
				case(cnt[3:0])
					0: io_dout_sys <= {arxy, arx};
					1: io_dout_sys <= {arxy, ary};
					2: io_dout_sys <= {LFB_EN, FB_EN, FB_FMT};
					3: io_dout_sys <= FB_WIDTH;
					4: io_dout_sys <= FB_HEIGHT;
					5: io_dout_sys <= FB_BASE[15:0];
					6: io_dout_sys <= FB_BASE[31:16];
					7: io_dout_sys <= FB_STRIDE;
				endcase
			end
`endif
			if(cmd == 'h41) begin
				case(cnt[3:0])
`ifndef MISTER_DISABLE_YC
					0: {pal_en,cvbs,yc_en}    <= io_din[2:0];
					4: ColorBurst_Range[15:0] <= io_din;
					5: ColorBurst_Range[16]   <= io_din[0];
`endif
					// Subcarrier commands (independent of YC module)
					1: PhaseInc[15:0]         <= io_din;
					2: PhaseInc[31:16]        <= io_din;
					3: PhaseInc[39:32]        <= io_din[7:0];
`ifndef MISTER_DUAL_SDRAM
					6: subcarrier             <= io_din[0];
`endif
				endcase
			end
		end
	end

`ifndef MISTER_DEBUG_NOHDMI
	fb_crc <= {LFB_EN, FB_EN, FB_FMT}
				^ FB_WIDTH[7:0]  ^ FB_WIDTH[11:8] 
				^ FB_HEIGHT[7:0] ^ FB_HEIGHT[11:8] 
				^ arx[7:0] ^ arx[11:8] ^ arxy
				^ ary[7:0] ^ ary[11:8];
`endif

	vs_d0 <= HDMI_TX_VS;
	if(vs_d0 == HDMI_TX_VS) vs_d1 <= vs_d0;

	vs_d2 <= vs_d1;
	if(~vs_d2 & vs_d1) vs_wait <= 0;
end

reg [7:0] frame_cnt;
always @(posedge clk_sys) begin
	reg vs_r, vs_old;
	
	vs_r <= vs_fix;
	if(vs_r == vs_fix) vs_old <= vs_r;
	if(~vs_old & vs_r) frame_cnt <= frame_cnt + 1'd1;
end

cyclonev_hps_interface_peripheral_uart uart
(
	.ri(0),
	.dsr(uart_dsr),
	.dcd(uart_dsr),
	.dtr(uart_dtr),

	.cts(uart_cts),
	.rts(uart_rts),
	.rxd(uart_rxd),
	.txd(uart_txd)
);

wire [63:0] f2h_irq = {video_sync,HDMI_TX_VS};
cyclonev_hps_interface_interrupts interrupts
(
	.irq(f2h_irq)
);

///////////////////////////  RESET  ///////////////////////////////////

reg reset_req = 0;
always @(posedge FPGA_CLK2_50) begin
	reg [1:0] resetd, resetd2;
	reg       old_reset;

	//latch the reset
	old_reset <= reset;
	if(~old_reset & reset) reset_req <= 1;

	//special combination to set/clear the reset
	//preventing of accidental reset control
	if(resetd==1) reset_req <= 1;
	if(resetd==2 && resetd2==0) reset_req <= 0;

	resetd  <= gp_out[31:30];
	resetd2 <= resetd;
end

////////////////////  SYSTEM MEMORY & SCALER  /////////////////////////

wire reset;
wire clk_100m;

//========================================================================//
// Emu68-A9 hybrid seam -- HPS h2f AXI master.                            //
//   sysmem.sv h2f AXI-3 master -> h2f_axi3_to_lite adapter -> AXI4-Lite  //
//   -> emu/axi_seam_slave.  All on clk_100m; aresetn = ~reset.           //
//   Hand-rolled rather than generated: the component-in-Qsys route needs //
//   Quartus 20.1 and MiSTer builds on 17.0.2.                            //
//========================================================================//

`ifdef HYBRID_EMU
//------------------------------------------------------------------------//
wire [11:0] hps_h2f_awid;
wire [29:0] hps_h2f_awaddr;
wire  [3:0] hps_h2f_awlen;
wire  [2:0] hps_h2f_awsize;
wire  [1:0] hps_h2f_awburst;
wire  [1:0] hps_h2f_awlock;
wire  [3:0] hps_h2f_awcache;
wire  [2:0] hps_h2f_awprot;
wire        hps_h2f_awvalid;
wire        hps_h2f_awready;
wire [11:0] hps_h2f_wid;
wire [31:0] hps_h2f_wdata;
wire  [3:0] hps_h2f_wstrb;
wire        hps_h2f_wlast;
wire        hps_h2f_wvalid;
wire        hps_h2f_wready;
wire [11:0] hps_h2f_bid;
wire  [1:0] hps_h2f_bresp;
wire        hps_h2f_bvalid;
wire        hps_h2f_bready;
wire [11:0] hps_h2f_arid;
wire [29:0] hps_h2f_araddr;
wire  [3:0] hps_h2f_arlen;
wire  [2:0] hps_h2f_arsize;
wire  [1:0] hps_h2f_arburst;
wire  [1:0] hps_h2f_arlock;
wire  [3:0] hps_h2f_arcache;
wire  [2:0] hps_h2f_arprot;
wire        hps_h2f_arvalid;
wire        hps_h2f_arready;
wire [11:0] hps_h2f_rid;
wire [31:0] hps_h2f_rdata;
wire  [1:0] hps_h2f_rresp;
wire        hps_h2f_rlast;
wire        hps_h2f_rvalid;
wire        hps_h2f_rready;

// AXI4-Lite bus into emu (axi_seam_slave):
wire [24:0] seam_h2f_awaddr;
wire  [2:0] seam_h2f_awprot;
wire        seam_h2f_awvalid;
wire        seam_h2f_awready;
wire [31:0] seam_h2f_wdata;
wire  [3:0] seam_h2f_wstrb;
wire        seam_h2f_wvalid;
wire        seam_h2f_wready;
wire  [1:0] seam_h2f_bresp;
wire        seam_h2f_bvalid;
wire        seam_h2f_bready;
wire [24:0] seam_h2f_araddr;
wire  [2:0] seam_h2f_arsize;
wire  [2:0] seam_h2f_arprot;
wire        seam_h2f_arvalid;
wire        seam_h2f_arready;
wire [31:0] seam_h2f_rdata;
wire  [1:0] seam_h2f_rresp;
wire        seam_h2f_rvalid;
wire        seam_h2f_rready;
`endif

sysmem_lite sysmem
(
	//Reset/Clock
	.reset_core_req(reset_req),
	.reset_out(reset),
	.clock(clk_100m),

	//DE10-nano has no reset signal on GPIO, so core has to emulate cold reset button.
	.reset_hps_cold_req(btn_r),

	//64-bit DDR3 RAM access
	.ram1_clk(ram_clk),
	.ram1_address(ram_address),
	.ram1_burstcount(ram_burstcount),
	.ram1_waitrequest(ram_waitrequest),
	.ram1_readdata(ram_readdata),
	.ram1_readdatavalid(ram_readdatavalid),
	.ram1_read(ram_read),
	.ram1_writedata(ram_writedata),
	.ram1_byteenable(ram_byteenable),
	.ram1_write(ram_write),

	//64-bit DDR3 RAM access
	.ram2_clk(clk_audio),
	.ram2_address(ram2_address),
	.ram2_burstcount(ram2_burstcount),
	.ram2_waitrequest(ram2_waitrequest),
	.ram2_readdata(ram2_readdata),
	.ram2_readdatavalid(ram2_readdatavalid),
	.ram2_read(ram2_read),
	.ram2_writedata(ram2_writedata),
	.ram2_byteenable(ram2_byteenable),
	.ram2_write(ram2_write),

	//128-bit DDR3 RAM access
	// HDMI frame buffer
	.vbuf_clk(clk_100m),
	.vbuf_address(vbuf_address),
	.vbuf_burstcount(vbuf_burstcount),
	.vbuf_waitrequest(vbuf_waitrequest),
	.vbuf_writedata(vbuf_writedata),
	.vbuf_byteenable(vbuf_byteenable),
	.vbuf_write(vbuf_write),
	.vbuf_readdata(vbuf_readdata),
	.vbuf_readdatavalid(vbuf_readdatavalid),
	.vbuf_read(vbuf_read)

	// h2f AXI-3 master brought out to sys_top; the comma is guarded so the classic sysmem_lite instance is unchanged
`ifdef HYBRID_EMU
	,
	.h2f_axi_clk (clk_100m),
	.h2f_awid    (hps_h2f_awid),
	.h2f_awaddr  (hps_h2f_awaddr),
	.h2f_awlen   (hps_h2f_awlen),
	.h2f_awsize  (hps_h2f_awsize),
	.h2f_awburst (hps_h2f_awburst),
	.h2f_awlock  (hps_h2f_awlock),
	.h2f_awcache (hps_h2f_awcache),
	.h2f_awprot  (hps_h2f_awprot),
	.h2f_awvalid (hps_h2f_awvalid),
	.h2f_awready (hps_h2f_awready),
	.h2f_wid     (hps_h2f_wid),
	.h2f_wdata   (hps_h2f_wdata),
	.h2f_wstrb   (hps_h2f_wstrb),
	.h2f_wlast   (hps_h2f_wlast),
	.h2f_wvalid  (hps_h2f_wvalid),
	.h2f_wready  (hps_h2f_wready),
	.h2f_bid     (hps_h2f_bid),
	.h2f_bresp   (hps_h2f_bresp),
	.h2f_bvalid  (hps_h2f_bvalid),
	.h2f_bready  (hps_h2f_bready),
	.h2f_arid    (hps_h2f_arid),
	.h2f_araddr  (hps_h2f_araddr),
	.h2f_arlen   (hps_h2f_arlen),
	.h2f_arsize  (hps_h2f_arsize),
	.h2f_arburst (hps_h2f_arburst),
	.h2f_arlock  (hps_h2f_arlock),
	.h2f_arcache (hps_h2f_arcache),
	.h2f_arprot  (hps_h2f_arprot),
	.h2f_arvalid (hps_h2f_arvalid),
	.h2f_arready (hps_h2f_arready),
	.h2f_rid     (hps_h2f_rid),
	.h2f_rdata   (hps_h2f_rdata),
	.h2f_rresp   (hps_h2f_rresp),
	.h2f_rlast   (hps_h2f_rlast),
	.h2f_rvalid  (hps_h2f_rvalid),
	.h2f_rready  (hps_h2f_rready)
`endif
);

`ifdef HYBRID_EMU
// AXI-3 (h2f master) -> AXI4-Lite (axi_seam_slave) adapter. Single-beat device accesses only.
// aresetn = ~reset (sysmem reset_out, clk_100m domain).
h2f_axi3_to_lite #(
	.ID_WIDTH        (12),
	.H2F_ADDR_WIDTH  (30),
	.LITE_ADDR_WIDTH (25),
	.DATA_WIDTH      (32)
) u_h2f_adapter
(
	.aclk      (clk_100m),
	.aresetn   (~reset),

	// AXI-3 slave side <- sysmem_lite h2f master
	.s_awid    (hps_h2f_awid),
	.s_awaddr  (hps_h2f_awaddr),
	.s_awlen   (hps_h2f_awlen),
	.s_awsize  (hps_h2f_awsize),
	.s_awburst (hps_h2f_awburst),
	.s_awlock  (hps_h2f_awlock),
	.s_awcache (hps_h2f_awcache),
	.s_awprot  (hps_h2f_awprot),
	.s_awvalid (hps_h2f_awvalid),
	.s_awready (hps_h2f_awready),
	.s_wid     (hps_h2f_wid),
	.s_wdata   (hps_h2f_wdata),
	.s_wstrb   (hps_h2f_wstrb),
	.s_wlast   (hps_h2f_wlast),
	.s_wvalid  (hps_h2f_wvalid),
	.s_wready  (hps_h2f_wready),
	.s_bid     (hps_h2f_bid),
	.s_bresp   (hps_h2f_bresp),
	.s_bvalid  (hps_h2f_bvalid),
	.s_bready  (hps_h2f_bready),
	.s_arid    (hps_h2f_arid),
	.s_araddr  (hps_h2f_araddr),
	.s_arlen   (hps_h2f_arlen),
	.s_arsize  (hps_h2f_arsize),
	.s_arburst (hps_h2f_arburst),
	.s_arlock  (hps_h2f_arlock),
	.s_arcache (hps_h2f_arcache),
	.s_arprot  (hps_h2f_arprot),
	.s_arvalid (hps_h2f_arvalid),
	.s_arready (hps_h2f_arready),
	.s_rid     (hps_h2f_rid),
	.s_rdata   (hps_h2f_rdata),
	.s_rresp   (hps_h2f_rresp),
	.s_rlast   (hps_h2f_rlast),
	.s_rvalid  (hps_h2f_rvalid),
	.s_rready  (hps_h2f_rready),

	// AXI4-Lite master side -> emu/axi_seam_slave
	.m_awaddr  (seam_h2f_awaddr),
	.m_awprot  (seam_h2f_awprot),
	.m_awvalid (seam_h2f_awvalid),
	.m_awready (seam_h2f_awready),
	.m_wdata   (seam_h2f_wdata),
	.m_wstrb   (seam_h2f_wstrb),
	.m_wvalid  (seam_h2f_wvalid),
	.m_wready  (seam_h2f_wready),
	.m_bresp   (seam_h2f_bresp),
	.m_bvalid  (seam_h2f_bvalid),
	.m_bready  (seam_h2f_bready),
	.m_araddr  (seam_h2f_araddr),
	.m_arsize  (seam_h2f_arsize),
	.m_arprot  (seam_h2f_arprot),
	.m_arvalid (seam_h2f_arvalid),
	.m_arready (seam_h2f_arready),
	.m_rdata   (seam_h2f_rdata),
	.m_rresp   (seam_h2f_rresp),
	.m_rvalid  (seam_h2f_rvalid),
	.m_rready  (seam_h2f_rready)
);
`endif

wire [28:0] ram2_address;
wire  [7:0] ram2_burstcount;
wire  [7:0] ram2_byteenable;
wire        ram2_waitrequest;
wire [63:0] ram2_readdata;
wire [63:0] ram2_writedata;
wire        ram2_readdatavalid;
wire        ram2_read;
wire        ram2_write;
wire  [7:0] ram2_bcnt;

ddr_svc ddr_svc
(
	.clk(clk_audio),

	.ram_waitrequest(ram2_waitrequest),
	.ram_burstcnt(ram2_burstcount),
	.ram_addr(ram2_address),
	.ram_readdata(ram2_readdata),
	.ram_read_ready(ram2_readdatavalid),
	.ram_read(ram2_read),
	.ram_writedata(ram2_writedata),
	.ram_byteenable(ram2_byteenable),
	.ram_write(ram2_write),
	.ram_bcnt(ram2_bcnt),

`ifndef MISTER_DISABLE_ALSA
	.ch0_addr(alsa_address),
	.ch0_burst(1),
	.ch0_data(alsa_readdata),
	.ch0_req(alsa_req),
	.ch0_ready(alsa_ready),
`endif

	.ch1_addr(pal_addr),
	.ch1_burst(128),
	.ch1_data(pal_data),
	.ch1_req(pal_req),
	.ch1_ready(pal_wr)
);

wire clk_pal = clk_audio;


wire  [27:0] vbuf_address;
wire   [7:0] vbuf_burstcount;
wire         vbuf_waitrequest;
wire [127:0] vbuf_readdata;
wire         vbuf_readdatavalid;
wire         vbuf_read;
wire [127:0] vbuf_writedata;
wire  [15:0] vbuf_byteenable;
wire         vbuf_write;

wire  [23:0] hdmi_data;
wire         hdmi_vs, hdmi_hs, hdmi_de, hdmi_vbl, hdmi_brd;
wire         freeze;
wire         bob_deint;

`ifndef MISTER_DEBUG_NOHDMI
	wire clk_hdmi  = hdmi_clk_out;

	ascal 
	#(
		.RAMBASE(32'h20000000),
	`ifdef MISTER_SMALL_VBUF
		.RAMSIZE(32'h00200000),
	`else
		.RAMSIZE(32'h00800000),
	`endif
	`ifndef MISTER_FB
		.PALETTE2("false"),
	`else
		`ifndef MISTER_FB_PALETTE
			.PALETTE2("false"),
		`endif
	`endif
	`ifdef MISTER_DISABLE_ADAPTIVE
		.ADAPTIVE("false"),
	`endif
	`ifdef MISTER_DOWNSCALE_NN
		.DOWNSCALE_NN("true"),
	`endif
		.FRAC(8),
`ifdef MENU_CORE
		.N_BURST(2048),
`endif
		.N_DW(128),
		.N_AW(28)
	)
	ascal
	(
		.reset_na   (~reset_req),
		.run        (1),
		.freeze     (freeze),
		.bob_deint  (bob_deint),

		.i_clk    (clk_ihdmi),
		.i_ce     (ce_hpix),
		.i_r      (hr_out),
		.i_g      (hg_out),
		.i_b      (hb_out),
		.i_hs     (hhs_fix),
		.i_vs     (hvs_fix),
		.i_fl     (f1),
		.i_de     (hde_emu),
		.iauto    (1),
		.himin    (0),
		.himax    (0),
		.vimin    (0),
		.vimax    (0),

		.o_clk    (clk_hdmi),
		.o_ce     (scaler_out),
		.o_r      (hdmi_data[23:16]),
		.o_g      (hdmi_data[15:8]),
		.o_b      (hdmi_data[7:0]),
		.o_hs     (hdmi_hs),
		.o_vs     (hdmi_vs),
		.o_de     (hdmi_de),
		.o_vbl    (hdmi_vbl),
		.o_brd    (hdmi_brd),
		.o_lltune (lltune),
		.htotal   (WIDTH + HFP + HBP + HS[11:0]),
		.hsstart  (WIDTH + HFP),
		.hsend    (WIDTH + HFP + HS[11:0]),
		.hdisp    (WIDTH),
		.hmin     (hmin),
		.hmax     (hmax),
		.vtotal   (HEIGHT + VFP + VBP + VS[11:0]),
		.vsstart  (HEIGHT + VFP),
		.vsend    (HEIGHT + VFP + VS[11:0]),
		.vdisp    (HEIGHT),
		.vmin     (vmin),
		.vmax     (vmax),
		.vrr      (vrr_mode),
		.vrrmax   (HEIGHT + VBP + VS[11:0] + 12'd1),
		.swblack  (hdmi_blackout),

		// the OSD "Video Processing" filters are a CHIPSET-video setting and must not run over a
		// framebuffer. RTG comes out at ~1:1, so the FIR has nothing to interpolate and only softens
		// what is already pixel-exact -- Nearest is the exact choice, as it is for Main's own
		// framebuffer. With both FB_EN and LFB_EN low the expression collapses to the original.
		// RTG modes of up to 480 lines are scaled up, so they keep the filters
		.mode     ({~lowlat,LFB_EN ? LFB_FLT : ((~FB_EN | (FB_HEIGHT <= 12'd480)) & |scaler_flt),2'b00}),
		.poly_clk (clk_sys),
		.poly_a   (coef_addr),
		.poly_dw  (coef_data),
		.poly_wr  (coef_wr),

		.pal1_clk (clk_pal),
		.pal1_dw  (pal_d),
		.pal1_a   (pal_a),
		.pal1_wr  (pal_wr),

	`ifdef MISTER_FB
		`ifdef MISTER_FB_PALETTE
			.pal2_clk (fb_pal_clk),
			.pal2_dw  (fb_pal_d),
			.pal2_dr  (fb_pal_q),
			.pal2_a   (fb_pal_a),
			.pal2_wr  (fb_pal_wr),
			.pal_n    (fb_en),
		`endif
	`endif

		.o_fb_ena         (FB_EN),
		.o_fb_hsize       (FB_WIDTH),
		.o_fb_vsize       (FB_HEIGHT),
		.o_fb_format      (FB_FMT),
		.o_fb_base        (FB_BASE),
		.o_fb_stride      (FB_STRIDE),

		.avl_clk          (clk_100m),
		.avl_waitrequest  (vbuf_waitrequest),
		.avl_readdata     (vbuf_readdata),
		.avl_readdatavalid(vbuf_readdatavalid),
		.avl_burstcount   (vbuf_burstcount),
		.avl_writedata    (vbuf_writedata),
		.avl_address      (vbuf_address),
		.avl_write        (vbuf_write),
		.avl_read         (vbuf_read),
		.avl_byteenable   (vbuf_byteenable)
	);
`endif

reg        LFB_EN     = 0;
reg        LFB_FLT    = 0;
reg  [5:0] LFB_FMT    = 0;
reg [11:0] LFB_WIDTH  = 0;
reg [11:0] LFB_HEIGHT = 0;
reg [11:0] LFB_HMIN   = 0;
reg [11:0] LFB_HMAX   = 0;
reg [11:0] LFB_VMIN   = 0;
reg [11:0] LFB_VMAX   = 0;
reg [31:0] LFB_BASE   = 0;
reg [13:0] LFB_STRIDE = 0;

reg        FB_EN     = 0;
reg  [5:0] FB_FMT    = 0;
reg [11:0] FB_WIDTH  = 0;
reg [11:0] FB_HEIGHT = 0;
reg [31:0] FB_BASE   = 0;
reg [13:0] FB_STRIDE = 0;

always @(posedge clk_sys) begin
	FB_EN <= LFB_EN | fb_en;
	if(LFB_EN) begin
		FB_FMT    <= LFB_FMT;
		FB_WIDTH  <= LFB_WIDTH;
		FB_HEIGHT <= LFB_HEIGHT;
		FB_BASE   <= LFB_BASE;
		FB_STRIDE <= LFB_STRIDE;
	end
	else begin
		FB_FMT    <= fb_fmt;
		FB_WIDTH  <= fb_width;
		FB_HEIGHT <= fb_height;
		FB_BASE   <= fb_base;
		FB_STRIDE <= fb_stride;
	end
end

// the core's own RTG descriptor for the native scanout: FB_* carries Main's framebuffer while LFB_EN is set
reg        RTG_EN     = 0;
reg  [5:0] RTG_FMT    = 0;
reg [11:0] RTG_WIDTH  = 0;
reg [11:0] RTG_HEIGHT = 0;
reg [31:0] RTG_BASE   = 0;
reg [13:0] RTG_STRIDE = 0;

always @(posedge clk_sys) begin
	RTG_EN     <= fb_en;
	RTG_FMT    <= fb_fmt;
	RTG_WIDTH  <= fb_width;
	RTG_HEIGHT <= fb_height;
	RTG_BASE   <= fb_base;
	RTG_STRIDE <= fb_stride;
end

`ifdef MISTER_FB
	reg fb_vbl;
	always @(posedge clk_vid) fb_vbl <= hdmi_vbl;
`endif

reg  ar_md_start;
wire ar_md_busy;
reg  [11:0] ar_md_mul1, ar_md_mul2, ar_md_div;
wire [11:0] ar_md_res;

sys_umuldiv #(12,12,12) ar_muldiv
(
	.clk(clk_vid),
	.start(ar_md_start),
	.busy(ar_md_busy),

	.mul1(ar_md_mul1),
	.mul2(ar_md_mul2),
	.div(ar_md_div),
	.result(ar_md_res)
);

reg [11:0] hmin;
reg [11:0] hmax;
reg [11:0] vmin;
reg [11:0] vmax;
reg [11:0] hdmi_height;
reg [11:0] hdmi_width;

reg [11:0] arx;
reg [11:0] ary;
reg        arxy;

always @(posedge clk_vid) begin
	reg [11:0] hmini,hmaxi,vmini,vmaxi;
	reg [11:0] wcalc,videow;
	reg [11:0] hcalc,videoh;
	reg  [2:0] state;

	hdmi_height <= (VSET && (VSET < HEIGHT)) ? VSET : HEIGHT;
	hdmi_width  <= (HSET && (HSET < WIDTH))  ? HSET << HDMI_PR : WIDTH << HDMI_PR;

	if(!ARY) begin
		if(ARX == 1) begin
			arx  <= arc1x[11:0];
			ary  <= arc1y[11:0];
			arxy <= arc1x[12] | arc1y[12];
		end
		else if(ARX == 2) begin
			arx  <= arc2x[11:0];
			ary  <= arc2y[11:0];
			arxy <= arc2x[12] | arc2y[12];
		end
		else begin
			arx  <= 0;
			ary  <= 0;
			arxy <= 0;
		end
	end
	else begin
		arx  <= ARX[11:0];
		ary  <= ARY[11:0];
		arxy <= ARX[12] | ARY[12];
	end
	
	ar_md_start <= 0;
	state <= state + 1'd1;
	case(state)
		0: if(LFB_EN) begin
				hmini <= LFB_HMIN;
				vmini <= LFB_VMIN;
				hmaxi <= LFB_HMAX;
				vmaxi <= LFB_VMAX;
				state <= 0;
			end
			else if(FREESCALE || !arx || !ary) begin
				wcalc <= hdmi_width;
				hcalc <= hdmi_height;
				state <= 6;
			end
			else if(arxy) begin
				wcalc <= arx;
				hcalc <= ary;
				state <= 6;
			end

		1: begin
				ar_md_mul1 <= hdmi_height;
				ar_md_mul2 <= arx;
				ar_md_div  <= ary;
				ar_md_start<= 1;
			end
		2: begin
				wcalc <= ar_md_res;
				if(ar_md_start | ar_md_busy) state <= 2;
			end

		3: begin
				ar_md_mul1 <= hdmi_width;
				ar_md_mul2 <= ary;
				ar_md_div  <= arx;
				ar_md_start<= 1;
			end
		4: begin
				hcalc <= ar_md_res;
				if(ar_md_start | ar_md_busy) state <= 4;
			end

		6: begin
				videow <= (wcalc > hdmi_width)  ? (hdmi_width >> HDMI_PR)  : (wcalc[11:0] >> HDMI_PR);
				videoh <= (hcalc > hdmi_height) ? hdmi_height : hcalc[11:0];
			end

		7: begin
				hmini <= ((WIDTH  - videow)>>1);
				hmaxi <= ((WIDTH  - videow)>>1) + videow - 1'd1;
				vmini <= ((HEIGHT - videoh)>>1);
				vmaxi <= ((HEIGHT - videoh)>>1) + videoh - 1'd1;
			end
	endcase
	
	hmin <= hmini;
	hmax <= hmaxi;
	vmin <= vmini;
	vmax <= vmaxi;
end

`ifndef MISTER_DEBUG_NOHDMI
	wire [15:0] lltune;
	pll_hdmi_adj pll_hdmi_adj
	(
		.clk(FPGA_CLK1_50),
		.reset_na(~reset_req),

		.llena(lowlat),
		.lltune({16{cfg_done}} & lltune),
		.locked(led_locked),
		.i_waitrequest(adj_waitrequest),
		.i_write(adj_write),
		.i_address(adj_address),
		.i_writedata(adj_data),
		.o_waitrequest(cfg_waitrequest),
		.o_write(cfg_write),
		.o_address(cfg_address),
		.o_writedata(cfg_data)
	);
`else
	assign led_locked = 0;
`endif

wire [63:0] pal_data;
wire [47:0] pal_d = {pal_data[55:32], pal_data[23:0]};
wire  [6:0] pal_a = ram2_bcnt[6:0];
wire        pal_wr;

reg  [28:0] pal_addr;
reg         pal_req = 0;
always @(posedge clk_pal) begin
	reg old_vs1, old_vs2;

	pal_addr <= LFB_BASE[31:3] - 29'd512;

	old_vs1 <= hdmi_vs;
	old_vs2 <= old_vs1;
	
	if(~old_vs2 & old_vs1 & ~FB_FMT[2] & FB_FMT[1] & FB_FMT[0] & FB_EN) pal_req <= ~pal_req;
end


/////////////////////////  HDMI output  /////////////////////////////////
`ifndef MISTER_DEBUG_NOHDMI
	wire hdmi_clk_out;
	pll_hdmi pll_hdmi
	(
		.refclk(FPGA_CLK1_50),
		.rst(reset_req),
		.reconfig_to_pll(reconfig_to_pll),
		.reconfig_from_pll(reconfig_from_pll),
		.outclk_0(hdmi_clk_out)
	);
`endif

//1920x1080@60 PCLK=148.5MHz CEA
reg  [11:0] WIDTH   = 1920;
reg  [11:0] HFP     = 88;
reg  [12:0] HS      = 48;
reg  [11:0] HBP     = 148;
reg  [11:0] HEIGHT  = 1080;
reg  [11:0] VFP     = 4;
reg  [12:0] VS      = 5;
reg  [11:0] VBP     = 36;
reg         HDMI_PR = 0;

wire [63:0] reconfig_to_pll;
wire [63:0] reconfig_from_pll;
wire        cfg_waitrequest,adj_waitrequest;
wire        cfg_write;
wire  [5:0] cfg_address;
wire [31:0] cfg_data;
reg         adj_write;
reg   [5:0] adj_address;
reg  [31:0] adj_data;

`ifndef MISTER_DEBUG_NOHDMI
	pll_cfg_hdmi pll_cfg_hdmi
	(
		.mgmt_clk(FPGA_CLK1_50),
		.mgmt_reset(reset_req),
		.mgmt_waitrequest(cfg_waitrequest),
		.mgmt_write(cfg_write),
		.mgmt_address(cfg_address),
		.mgmt_writedata(cfg_data),
		.reconfig_to_pll(reconfig_to_pll),
		.reconfig_from_pll(reconfig_from_pll)
	);

	reg cfg_got = 0;
	always @(posedge clk_sys) begin
		reg vsd, vsd2;
		if(~cfg_ready || ~cfg_set) cfg_got <= cfg_set;
		else begin
			vsd  <= HDMI_TX_VS;
			vsd2 <= vsd;
			if(~vsd2 & vsd) cfg_got <= cfg_set;
		end
	end

	reg cfg_ready = 0;
	always @(posedge FPGA_CLK1_50) begin
		reg gotd = 0, gotd2 = 0;
		reg custd = 0, custd2 = 0;
		reg old_wait = 0;

		gotd  <= cfg_got;
		gotd2 <= gotd;
		
		adj_write <= 0;
		
		custd <= cfg_custom_t;
		custd2 <= custd;
		if(custd2 != custd & ~gotd) begin
			adj_address <= cfg_custom_p1;
			adj_data <= cfg_custom_p2;
			adj_write <= 1;
		end

		if(~gotd2 & gotd) begin
			adj_address <= 2;
			adj_data <= 0;
			adj_write <= 1;
		end

		old_wait <= adj_waitrequest;
		if(old_wait & ~adj_waitrequest & gotd) cfg_ready <= 1;
	end
`else
	wire cfg_ready = 1;
`endif

assign HDMI_I2C_SCL = hdmi_scl_en ? 1'b0 : 1'bZ;
assign HDMI_I2C_SDA = hdmi_sda_en ? 1'b0 : 1'bZ;

wire hdmi_scl_en, hdmi_sda_en;
cyclonev_hps_interface_peripheral_i2c hdmi_i2c
(
	.out_clk(hdmi_scl_en),
	.scl(HDMI_I2C_SCL),
	.out_data(hdmi_sda_en),
	.sda(HDMI_I2C_SDA)
);

`ifndef MISTER_DEBUG_NOHDMI
	`ifdef MISTER_FB
	reg dis_output;
	always @(posedge clk_hdmi) begin
		reg dis;
		dis <= fb_force_blank & ~LFB_EN;
		dis_output <= dis;
	end
	`else
	wire dis_output = 0;
	`endif

	wire [23:0] hdmi_data_mask;
	wire        hdmi_de_mask, hdmi_vs_mask, hdmi_hs_mask;

	reg [15:0] shadowmask_data;
	reg        shadowmask_wr = 0;

	shadowmask HDMI_shadowmask
	(
		.clk(clk_hdmi),
		.clk_sys(clk_sys),

		.cmd_wr(shadowmask_wr),
		.cmd_in(shadowmask_data),

		.din(dis_output ? 24'd0 : hdmi_data),
		.hs_in(hdmi_hs),
		.vs_in(hdmi_vs),
		.de_in(hdmi_de),
		.brd_in(hdmi_brd),
		// second half of "no video processing over a framebuffer": the shadow mask darkens a
		// per-pixel aperture grille over the scaler's output, and at RTG's ~1:1 scale that lands on
		// the desktop's own single pixels. Upstream exempts only Main's Linux framebuffer; ~FB_EN
		// widens it to the core's, leaving chipset video untouched.
		.enable(~FB_EN),

		.dout(hdmi_data_mask),
		.hs_out(hdmi_hs_mask),
		.vs_out(hdmi_vs_mask),
		.de_out(hdmi_de_mask)
	);

	// RTG mouse pointer between shadowmask and hdmi_osd (rtg_hdmi_osd_sprite, after the emu instance)
	wire [23:0] hdmi_data_spr;
	wire        hdmi_de_spr, hdmi_vs_spr, hdmi_hs_spr;

	wire [23:0] hdmi_data_osd;
	wire        hdmi_de_osd, hdmi_vs_osd, hdmi_hs_osd;

	osd hdmi_osd
	(
		.clk_sys(clk_sys),

		.io_osd(io_osd_hdmi),
		.io_strobe(io_strobe),
		.io_din(io_din),

		.clk_video(clk_hdmi),
		.din(hdmi_data_spr),
		.hs_in(hdmi_hs_spr),
		.vs_in(hdmi_vs_spr),
		.de_in(hdmi_de_spr),

		.dout(hdmi_data_osd),
		.hs_out(hdmi_hs_osd),
		.vs_out(hdmi_vs_osd),
		.de_out(hdmi_de_osd)
	);

	wire hdmi_cs_osd;
	csync csync_hdmi(clk_hdmi, hdmi_hs_osd, hdmi_vs_osd, hdmi_cs_osd);
`endif

reg [23:0] dv_data;
reg        dv_hs, dv_vs, dv_de;
wire [23:0] dv_data_osd;
wire dv_hs_osd, dv_vs_osd, dv_cs_osd;

always @(posedge clk_vid) begin
	reg [23:0] dv_d1, dv_d2;
	reg        dv_de1, dv_de2, dv_hs1, dv_hs2, dv_vs1, dv_vs2;
	reg [12:0] vsz, vcnt, vcnt_l, vcnt_ll;
	reg        old_hs, old_vs;
	reg        vde;
	reg  [3:0] hss;

	if(ce_pix) begin
		hss <= (hss << 1) | dv_hs_osd;

		old_hs <= dv_hs_osd;
		if(~old_hs && dv_hs_osd) begin
			old_vs <= dv_vs_osd;
			if(~&vcnt) vcnt <= vcnt + 1'd1;
			if(~old_vs & dv_vs_osd) begin
				if (vcnt != vcnt_ll || vcnt < vcnt_l) vsz <= vcnt;
				vcnt_l <= vcnt;
				vcnt_ll <= vcnt_l;
			end
			if(old_vs & ~dv_vs_osd) vcnt <= 0;
			
			if(vcnt == 1) vde <= 1;
			if(vcnt == vsz - 3) vde <= 0;
		end

		dv_de1 <= !{hss,dv_hs_osd} && vde;
	end

	dv_d1  <= dv_data_osd;
	dv_hs1 <= csync_en ? dv_cs_osd : dv_hs_osd;
	dv_vs1 <= dv_vs_osd;

	dv_d2  <= dv_d1;
	dv_de2 <= dv_de1;
	dv_hs2 <= dv_hs1;
	dv_vs2 <= dv_vs1;

	dv_data<= dv_d2;
	dv_de  <= dv_de2;
	dv_hs  <= dv_hs2;
	dv_vs  <= dv_vs2;
end

`ifndef MISTER_DISABLE_YC
	assign {dv_data_osd, dv_hs_osd, dv_vs_osd, dv_cs_osd } = ~yc_en ? {vga_data_osd, vga_hs_osd, vga_vs_osd, vga_cs_osd } : {yc_o, yc_hs, yc_vs, yc_cs };
`else
	assign {dv_data_osd, dv_hs_osd, dv_vs_osd, dv_cs_osd } = {vga_data_osd, vga_hs_osd, vga_vs_osd, vga_cs_osd };
`endif

wire hdmi_tx_clk;
`ifndef MISTER_DEBUG_NOHDMI
	cyclonev_clkselect hdmi_clk_sw
	( 
		.clkselect({1'b1, ~vga_fb & direct_video}),
		.inclk({clk_vid, hdmi_clk_out, 2'b00}),
		.outclk(hdmi_tx_clk)
	);
`else
	assign hdmi_tx_clk = clk_vid;
`endif

altddio_out
#(
	.extend_oe_disable("OFF"),
	.intended_device_family("Cyclone V"),
	.invert_output("OFF"),
	.lpm_hint("UNUSED"),
	.lpm_type("altddio_out"),
	.oe_reg("UNREGISTERED"),
	.power_up_high("OFF"),
	.width(1)
)
hdmiclk_ddr
(
	.datain_h(1'b0),
	.datain_l(1'b1),
	.outclock(hdmi_tx_clk),
	.dataout(HDMI_TX_CLK),
	.aclr(1'b0),
	.aset(1'b0),
	.oe(1'b1),
	.outclocken(1'b1),
	.sclr(1'b0),
	.sset(1'b0)
);

reg hdmi_out_hs;
reg hdmi_out_vs;
reg hdmi_out_de;
reg [23:0] hdmi_out_d;

always @(posedge hdmi_tx_clk) begin
	reg [23:0] hdmi_dv_data;
	reg        hdmi_dv_hs, hdmi_dv_vs, hdmi_dv_de;

	reg hs,vs,de;
	reg [23:0] d;
	
	hdmi_dv_data <= dv_data;
	hdmi_dv_hs   <= dv_hs;
	hdmi_dv_vs   <= dv_vs;
	hdmi_dv_de   <= dv_de;
	
`ifndef MISTER_DEBUG_NOHDMI
	hs <= (~vga_fb & direct_video) ? hdmi_dv_hs   : (direct_video & csync_en) ? hdmi_cs_osd : hdmi_hs_osd;
	vs <= (~vga_fb & direct_video) ? hdmi_dv_vs   : hdmi_vs_osd;
	de <= (~vga_fb & direct_video) ? hdmi_dv_de   : hdmi_de_osd;
	d  <= (~vga_fb & direct_video) ? hdmi_dv_data : hdmi_data_osd;
`else
	hs <= hdmi_dv_hs;
	vs <= hdmi_dv_vs;
	de <= hdmi_dv_de;
	d  <= hdmi_dv_data;
`endif

	hdmi_out_hs <= hs;
	hdmi_out_vs <= vs;
	hdmi_out_de <= de;
	hdmi_out_d  <= d;
end

assign HDMI_TX_HS = hdmi_out_hs;
assign HDMI_TX_VS = hdmi_out_vs;
assign HDMI_TX_DE = hdmi_out_de;
assign HDMI_TX_D  = hdmi_out_d;

// native-rate RTG analog scanout (instantiated at the end of the module), for RTG modes up to 640x480
wire        rtg_native_en = 1'b1;

wire        rtg_scanout_active = RTG_EN & rtg_native_en &
                                 (RTG_HEIGHT != 12'd0) & (RTG_HEIGHT <= 12'd480) &
                                 (RTG_WIDTH  != 12'd0) & (RTG_WIDTH  <= 12'd640) &
                                 rtg_fmt_ok;
wire [23:0] rtgs_o;
wire        rtgs_hs, rtgs_vs, rtgs_cs, rtgs_de;

/////////////////////////  VGA output  //////////////////////////////////

`ifndef MISTER_DUAL_SDRAM
	wire vga_tx_clk;
	`ifndef MISTER_DEBUG_NOHDMI
		// the analog DAC clock follows what is actually ON the analog pins, i.e. vgas_en --
		// so it is built from `vga_fb_ini | vga_scaler`, not `vga_fb | vga_scaler`
		cyclonev_clkselect vga_clk_sw
		(
			.clkselect({1'b1, ~vga_fb_ini & ~vga_scaler}),
			.inclk({clk_vid, hdmi_clk_out, 2'b00}),
			.outclk(vga_tx_clk)
		);
	`else
		assign vga_tx_clk = clk_vid;
	`endif

	wire VGA_TX_CLK;
	altddio_out
	#(
		.extend_oe_disable("OFF"),
		.intended_device_family("Cyclone V"),
		.invert_output("OFF"),
		.lpm_hint("UNUSED"),
		.lpm_type("altddio_out"),
		.oe_reg("UNREGISTERED"),
		.power_up_high("OFF"),
		.width(1)
	)
	vgaclk_ddr
	(
		.datain_h(1'b0),
		.datain_l(1'b1),
		.outclock(vga_tx_clk),
		.dataout(VGA_TX_CLK),
		.aclr(~mcp_en & ~av_dis),
		.aset(1'b0),
		.oe(~av_dis & (mcp_en | ~led_u)),
		.outclocken(1'b1),
		.sclr(1'b0),
		.sset(1'b0)
	);
`endif

wire [23:0] vga_data_sl;
wire        vga_de_sl, vga_ce_sl, vga_vs_sl, vga_hs_sl;
scanlines #(0) VGA_scanlines
(
	.clk(clk_vid),

	.scanlines(scanlines),
	.din(de_emu ? {r_out, g_out, b_out} : 24'd0),
	.hs_in(hs_fix),
	.vs_in(vs_fix),
	.de_in(de_emu),
	.ce_in(ce_pix),

	.dout(vga_data_sl),
	.hs_out(vga_hs_sl),
	.vs_out(vga_vs_sl),
	.de_out(vga_de_sl),
	.ce_out(vga_ce_sl)
);

wire [23:0] vga_data_osd;
wire        vga_vs_osd, vga_hs_osd, vga_de_osd;
osd vga_osd
(
	.clk_sys(clk_sys),

	.io_osd(io_osd_vga),
	.io_strobe(io_strobe),
	.io_din(io_din),
	.osd_status(osd_status),

	.clk_video(clk_vid),
	.din(vga_data_sl),
	.hs_in(vga_hs_sl),
	.vs_in(vga_vs_sl),
	.de_in(vga_de_sl),

	.dout(vga_data_osd),
	.hs_out(vga_hs_osd),
	.vs_out(vga_vs_osd),
	.de_out(vga_de_osd)
);

wire vga_cs_osd;
csync csync_vga(clk_vid, vga_hs_osd, vga_vs_osd, vga_cs_osd);

`ifndef MISTER_DISABLE_YC
	reg         pal_en;
	reg         yc_en;
	reg         cvbs;
	reg  [16:0] ColorBurst_Range;
	wire [23:0] yc_o;
	wire        yc_hs, yc_vs, yc_cs, yc_de;

	yc_out yc_out
	(
		.clk(clk_vid),
		.PAL_EN(pal_en),
		.CVBS(cvbs),
		.PHASE_INC(PhaseInc),
		.COLORBURST_RANGE(ColorBurst_Range),
		.hsync(vga_hs_osd),
		.vsync(vga_vs_osd),
		.csync(vga_cs_osd),
		.de(vga_de_osd),
		.dout(yc_o),
		.din(vga_data_osd),
		.hsync_o(yc_hs),
		.vsync_o(yc_vs),
		.csync_o(yc_cs),
		.de_o(yc_de)
	);
`endif

reg  [39:0] PhaseInc;

`ifndef MISTER_DUAL_SDRAM
	// Subcarrier generation for external encoders (independent of YC module)
	reg         subcarrier;

	reg  [39:0] sub_accum;
	always @(posedge clk_vid) sub_accum <= sub_accum + PhaseInc;

	// 1-bit output for positive/negative of wave, no LUT required. Output 1 if disabled for further logic
	reg subcarrier_out;
	always @(posedge clk_vid) subcarrier_out <= ~(subcarrier & csync_en & ~ypbpr_en & ~forced_scandoubler & ~vgas_en) | sub_accum[39];


	wire VGA_DISABLE;
	wire [23:0] vgas_o;
	wire vgas_hs, vgas_vs, vgas_cs, vgas_de;
	`ifndef MISTER_DEBUG_NOHDMI
		vga_out vga_scaler_out
		(
			.clk(clk_hdmi),
			.ypbpr_en(ypbpr_en),
			.hsync(hdmi_hs_osd),
			.vsync(hdmi_vs_osd),
			.csync(hdmi_cs_osd),
			.de(hdmi_de_osd),
			.dout(vgas_o),
			.din({24{hdmi_de_osd}} & hdmi_data_osd),
			.hsync_o(vgas_hs),
			.vsync_o(vgas_vs),
			.csync_o(vgas_cs),
			.de_o(vgas_de)
		);
	`else
		assign {vgas_o, vgas_hs, vgas_vs, vgas_cs, vgas_de} = 0;
	`endif

	wire [23:0] vga_o, vga_o_t;
	wire vga_hs, vga_vs, vga_cs, vga_de, vga_hs_t, vga_vs_t, vga_cs_t, vga_de_t;
	vga_out vga_out
	(
		.clk(clk_vid),
		.ypbpr_en(ypbpr_en),
		.hsync(vga_hs_osd),
		.vsync(vga_vs_osd),
		.csync(vga_cs_osd),
		.de(vga_de_osd),
		.dout(vga_o_t),
		.din(vga_data_osd),
		.hsync_o(vga_hs_t),
		.vsync_o(vga_vs_t),
		.csync_o(vga_cs_t),
		.de_o(vga_de_t)
	);

	`ifndef MISTER_DISABLE_YC
		assign {vga_o, vga_hs, vga_vs, vga_cs, vga_de } = ~yc_en ? {vga_o_t, vga_hs_t, vga_vs_t, vga_cs_t, vga_de_t } : {yc_o, yc_hs, yc_vs, yc_cs, yc_de };
	`else
		assign {vga_o, vga_hs, vga_vs, vga_cs, vga_de } =  {vga_o_t, vga_hs_t, vga_vs_t, vga_cs_t, vga_de_t } ;
	`endif

	// the analog-scaler enable is INI-ONLY (vga_fb_ini = cfg[12], vga_scaler = cfg[2]); the core's
	// VGA_SCALER request does not appear here, which is what makes VGA_DISABLE reachable during RTG
	wire vgas_en = vga_fb_ini | vga_scaler;

	// VGA_DISABLE must not leave a half-driven analog output: cs1 (sync-on-green injection) and
	// de1 (the DAC blanking gate) leave the FPGA too on I/O boards, so a sog box would keep
	// receiving a sync train on green while everything else is DC. Both arms are inert unless the
	// ini enables sog or an MCP I/O board is present.
	// the native RTG scanout ranks between the ini scaler and VGA_DISABLE
	wire cs1 = vgas_en ? vgas_cs : rtg_scanout_active ? rtgs_cs : VGA_DISABLE ? 1'b0 : vga_cs;
	wire de1 = vgas_en ? vgas_de : rtg_scanout_active ? rtgs_de : VGA_DISABLE ? 1'b0 : vga_de;

	assign VGA_VS = av_dis ? 1'bZ      :(((vgas_en ? (~vgas_vs ^ VS[12])                         : rtg_scanout_active ? ~rtgs_vs                        : VGA_DISABLE ? 1'd1 : ~vga_vs) | csync_en) & subcarrier_out);
	assign VGA_HS = av_dis ? 1'bZ      :  (vgas_en ? ((csync_en ? ~vgas_cs : ~vgas_hs) ^ HS[12]) : rtg_scanout_active ? (csync_en ? ~rtgs_cs : ~rtgs_hs) : VGA_DISABLE ? 1'd1 : (csync_en ? ~vga_cs : ~vga_hs));
	assign VGA_R  = av_dis ? 6'bZZZZZZ :   vgas_en ? vgas_o[23:18]                               : rtg_scanout_active ? rtgs_o[23:18]                   : VGA_DISABLE ? 6'd0 : vga_o[23:18];
	assign VGA_G  = av_dis ? 6'bZZZZZZ :   vgas_en ? vgas_o[15:10]                               : rtg_scanout_active ? rtgs_o[15:10]                   : VGA_DISABLE ? 6'd0 : vga_o[15:10];
	assign VGA_B  = av_dis ? 6'bZZZZZZ :   vgas_en ? vgas_o[7:2]                                 : rtg_scanout_active ? rtgs_o[7:2]                     : VGA_DISABLE ? 6'd0 : vga_o[7:2]  ;

	wire [1:0] vga_r  = vgas_en ? vgas_o[17:16] : rtg_scanout_active ? rtgs_o[17:16] : VGA_DISABLE ? 2'd0 : vga_o[17:16];
	wire [1:0] vga_g  = vgas_en ? vgas_o[9:8]   : rtg_scanout_active ? rtgs_o[9:8]   : VGA_DISABLE ? 2'd0 : vga_o[9:8];
	wire [1:0] vga_b  = vgas_en ? vgas_o[1:0]   : rtg_scanout_active ? rtgs_o[1:0]   : VGA_DISABLE ? 2'd0 : vga_o[1:0];
`endif

reg video_sync = 0;
always @(posedge clk_vid) begin
	reg [11:0] line_cnt  = 0;
	reg [11:0] sync_line = 0;
	reg  [1:0] hs_cnt = 0;
	reg        old_hs;

	old_hs <= hs_fix;
	if(~old_hs & hs_fix) begin

		video_sync <= (sync_line == line_cnt);

		line_cnt <= line_cnt + 1'd1;
		if(~hs_cnt[1]) begin	
			hs_cnt <= hs_cnt + 1'd1;
			if(hs_cnt[0]) begin
				sync_line <= (line_cnt - vs_line);
				line_cnt <= 0;
			end
		end
	end

	if(de_emu) hs_cnt <= 0;
end

/////////////////////////  Audio output  ////////////////////////////////

assign SDCD_SPDIF = (mcp_en & ~spdif) ? 1'b0 : 1'bZ;

`ifndef MISTER_DUAL_SDRAM
	wire analog_l, analog_r;

	assign AUDIO_SPDIF = av_dis ? 1'bZ : (SW[0] | mcp_en) ? HDMI_LRCLK : spdif;
	assign AUDIO_R     = av_dis ? 1'bZ : (SW[0] | mcp_en) ? HDMI_I2S   : analog_r;
	assign AUDIO_L     = av_dis ? 1'bZ : (SW[0] | mcp_en) ? HDMI_SCLK  : analog_l;
`endif

assign HDMI_MCLK = clk_audio;
wire clk_audio;

pll_audio pll_audio
(
	.refclk(FPGA_CLK3_50),
	.rst(0),
	.outclk_0(clk_audio)
);

wire spdif;
audio_out audio_out
(
	.reset(reset | areset),
	.clk(clk_audio),

	.att(vol_att),
	.boost(vol_boost),
	.mix(audio_mix),
	.sample_rate(audio_96k),

	.flt_rate(aflt_rate),
	.cx(acx),
	.cx0(acx0),
	.cx1(acx1),
	.cx2(acx2),
	.cy0(acy0),
	.cy1(acy1),
	.cy2(acy2),

	.is_signed(audio_s),
	.core_l(audio_l),
	.core_r(audio_r),

`ifndef MISTER_DISABLE_ALSA
	.alsa_l(alsa_l),
	.alsa_r(alsa_r),
`endif

	.i2s_bclk(HDMI_SCLK),
	.i2s_lrclk(HDMI_LRCLK),
	.i2s_data(HDMI_I2S),
`ifndef MISTER_DUAL_SDRAM
	.dac_l(analog_l),
	.dac_r(analog_r),
`endif
	.spdif(spdif)
);


`ifndef MISTER_DISABLE_ALSA
	wire aspi_sck,aspi_mosi,aspi_ss,aspi_miso;
	cyclonev_hps_interface_peripheral_spi_master spi
	(
		.sclk_out(aspi_sck),
		.txd(aspi_mosi), // mosi
		.rxd(aspi_miso), // miso

		.ss_0_n(aspi_ss),
		.ss_in_n(1)
	);

	wire [28:0] alsa_address;
	wire [63:0] alsa_readdata;
	wire        alsa_ready;
	wire        alsa_req;
	wire        alsa_late;

	wire [15:0] alsa_l, alsa_r;

	alsa alsa
	(
		.reset(reset),
		.clk(clk_audio),

		.ram_address(alsa_address),
		.ram_data(alsa_readdata),
		.ram_req(alsa_req),
		.ram_ready(alsa_ready),

		.spi_ss(aspi_ss),
		.spi_sck(aspi_sck),
		.spi_mosi(aspi_mosi),
		.spi_miso(aspi_miso),

		.pcm_l(alsa_l),
		.pcm_r(alsa_r)
	);
`endif

////////////////  User I/O (USB 3.0 connector) /////////////////////////

assign USER_IO[0] =                       !user_out[0]  ? 1'b0 : 1'bZ;
assign USER_IO[1] =                       !user_out[1]  ? 1'b0 : 1'bZ;
assign USER_IO[2] = !(SW[1] ? HDMI_I2S   : user_out[2]) ? 1'b0 : 1'bZ;
assign USER_IO[3] =                       !user_out[3]  ? 1'b0 : 1'bZ;
assign USER_IO[4] = !(SW[1] ? HDMI_SCLK  : user_out[4]) ? 1'b0 : 1'bZ;
assign USER_IO[5] = !(SW[1] ? HDMI_LRCLK : user_out[5]) ? 1'b0 : 1'bZ;
assign USER_IO[6] =                       !user_out[6]  ? 1'b0 : 1'bZ;

assign user_in[0] =         USER_IO[0];
assign user_in[1] =         USER_IO[1];
assign user_in[2] = SW[1] | USER_IO[2];
assign user_in[3] =         USER_IO[3];
assign user_in[4] = SW[1] | USER_IO[4];
assign user_in[5] = SW[1] | USER_IO[5];
assign user_in[6] =         USER_IO[6];


///////////////////  User module connection ////////////////////////////

wire        clk_sys;
wire [15:0] audio_l, audio_r;
wire        audio_s;
wire  [1:0] audio_mix;
wire  [1:0] scanlines;
wire  [7:0] r_out, g_out, b_out, hr_out, hg_out, hb_out;
wire        vs_fix, hs_fix, de_emu, vs_emu, hs_emu, f1;
wire        hvs_fix, hhs_fix, hde_emu;
wire        clk_vid, ce_pix, clk_ihdmi, ce_hpix;
wire        vga_force_scaler;

wire        ram_clk;
wire [28:0] ram_address;
wire [7:0]  ram_burstcount;
wire        ram_waitrequest;
wire [63:0] ram_readdata;
wire        ram_readdatavalid;
wire        ram_read;
wire [63:0] ram_writedata;
wire [7:0]  ram_byteenable;
wire        ram_write;

wire        led_user;
wire  [1:0] led_power;
wire  [1:0] led_disk;
wire  [1:0] btn;

sync_fix sync_v(clk_vid, vs_emu, vs_fix);
sync_fix sync_h(clk_vid, hs_emu, hs_fix);

wire  [6:0] user_out, user_in;

assign clk_ihdmi= clk_vid;
assign ce_hpix  = vga_ce_sl;
assign hr_out   = vga_data_sl[23:16];
assign hg_out   = vga_data_sl[15:8];
assign hb_out   = vga_data_sl[7:0];
assign hhs_fix  = vga_hs_sl;
assign hvs_fix  = vga_vs_sl;
assign hde_emu  = vga_de_sl;

wire uart_dtr;
wire uart_dsr;
wire uart_cts;
wire uart_rts;
wire uart_rxd;
wire uart_txd;

wire osd_status;

wire        fb_en;
wire  [5:0] fb_fmt;
wire [11:0] fb_width;
wire [11:0] fb_height;
wire [31:0] fb_base;
wire [13:0] fb_stride;


`ifdef MISTER_FB
	`ifdef MISTER_FB_PALETTE
		wire        fb_pal_clk;
		wire  [7:0] fb_pal_a;
		wire [23:0] fb_pal_d;
		wire [23:0] fb_pal_q;
		wire        fb_pal_wr;
		// RTG pointer sprite write bus (fb_pal_clk domain)
		wire        fb_spr_wr;
		wire  [8:0] fb_spr_a;
		wire [15:0] fb_spr_d;
	`endif
	wire   fb_force_blank;
`else
	assign fb_en = 0;
	assign fb_fmt = 0;
	assign fb_width = 0;
	assign fb_height = 0;
	assign fb_base = 0;
	assign fb_stride = 0;
`endif

emu emu
(
	.CLK_50M(FPGA_CLK2_50),
	.RESET(reset),
	.HPS_BUS({f1, HDMI_TX_VS, 
				 clk_100m, clk_ihdmi,
				 ce_hpix, hde_emu, hhs_fix, hvs_fix, 
				 io_wait, clk_sys, io_fpga, io_uio, io_strobe, io_wide, io_din, io_dout}),

	.VGA_R(r_out),
	.VGA_G(g_out),
	.VGA_B(b_out),
	.VGA_HS(hs_emu),
	.VGA_VS(vs_emu),
	.VGA_DE(de_emu),
	.VGA_F1(f1),
	.VGA_SCALER(vga_force_scaler),

`ifndef MISTER_DUAL_SDRAM
	.VGA_DISABLE(VGA_DISABLE),
`endif

	.HDMI_WIDTH(direct_video ? 12'd0 : hdmi_width),
	.HDMI_HEIGHT(direct_video ? 12'd0 : hdmi_height),
	.HDMI_FREEZE(freeze),
	.HDMI_BLACKOUT(hdmi_blackout),
	.HDMI_BOB_DEINT(bob_deint),

	.CLK_VIDEO(clk_vid),
	.CE_PIXEL(ce_pix),
	.VGA_SL(scanlines),
	.VIDEO_ARX(ARX),
	.VIDEO_ARY(ARY),

`ifdef MISTER_FB
	.FB_EN(fb_en),
	.FB_FORMAT(fb_fmt),
	.FB_WIDTH(fb_width),
	.FB_HEIGHT(fb_height),
	.FB_BASE(fb_base),
	.FB_STRIDE(fb_stride),
	.FB_VBL(fb_vbl),
	.FB_LL(lowlat),
	.FB_FORCE_BLANK(fb_force_blank),

`ifdef MISTER_FB_PALETTE
	.FB_PAL_CLK (fb_pal_clk),
	.FB_PAL_ADDR(fb_pal_a),
	.FB_PAL_DOUT(fb_pal_d),
	.FB_PAL_DIN (fb_pal_q),
	.FB_PAL_WR  (fb_pal_wr),
	.FB_SPRITE_WR  (fb_spr_wr),
	.FB_SPRITE_ADDR(fb_spr_a),
	.FB_SPRITE_DOUT(fb_spr_d),
`endif

`endif

	.LED_USER(led_user),
	.LED_POWER(led_power),
	.LED_DISK(led_disk),

	.CLK_AUDIO(clk_audio),
	.AUDIO_L(audio_l),
	.AUDIO_R(audio_r),
	.AUDIO_S(audio_s),
	.AUDIO_MIX(audio_mix),

	.ADC_BUS({ADC_SCK,ADC_SDO,ADC_SDI,ADC_CONVST}),

	// unused by the core: ram_* belongs to the RTG scanout reader
	.DDRAM_CLK(),
	.DDRAM_ADDR(),
	.DDRAM_BURSTCNT(),
	.DDRAM_BUSY(1'b0),
	.DDRAM_DOUT(64'd0),
	.DDRAM_DOUT_READY(1'b0),
	.DDRAM_RD(),
	.DDRAM_DIN(),
	.DDRAM_BE(),
	.DDRAM_WE(),

	.SDRAM_DQ(SDRAM_DQ),
	.SDRAM_A(SDRAM_A),
	.SDRAM_DQML(SDRAM_DQML),
	.SDRAM_DQMH(SDRAM_DQMH),
	.SDRAM_BA(SDRAM_BA),
	.SDRAM_nCS(SDRAM_nCS),
	.SDRAM_nWE(SDRAM_nWE),
	.SDRAM_nRAS(SDRAM_nRAS),
	.SDRAM_nCAS(SDRAM_nCAS),
	.SDRAM_CLK(SDRAM_CLK),
	.SDRAM_CKE(SDRAM_CKE),

`ifdef MISTER_DUAL_SDRAM
	.SDRAM2_DQ(SDRAM2_DQ),
	.SDRAM2_A(SDRAM2_A),
	.SDRAM2_BA(SDRAM2_BA),
	.SDRAM2_nCS(SDRAM2_nCS),
	.SDRAM2_nWE(SDRAM2_nWE),
	.SDRAM2_nRAS(SDRAM2_nRAS),
	.SDRAM2_nCAS(SDRAM2_nCAS),
	.SDRAM2_CLK(SDRAM2_CLK),
	.SDRAM2_EN(io_dig),
`endif

	.BUTTONS(btn),
	.OSD_STATUS(osd_status),

	.SD_SCK(SD_CLK),
	.SD_MOSI(SD_MOSI),
	.SD_MISO(SD_MISO),
	.SD_CS(SD_CS),
	.SD_CD(SD_CD),

	.UART_CTS(uart_rts),
	.UART_RTS(uart_cts),
	.UART_RXD(uart_txd),
	.UART_TXD(uart_rxd),
	.UART_DTR(uart_dsr),
	.UART_DSR(uart_dtr),

	.USER_OUT(user_out),
	.USER_IN(user_in)

	// h2f AXI4-Lite slave bus into emu; the comma is guarded so the classic emu instance is
	// unchanged. aclk = clk_100m, arstn = ~reset.
`ifdef HYBRID_EMU
	,
	.h2f_aclk   (clk_100m),
	.h2f_arstn  (~reset),
	.h2f_awaddr (seam_h2f_awaddr),
	.h2f_awprot (seam_h2f_awprot),
	.h2f_awvalid(seam_h2f_awvalid),
	.h2f_awready(seam_h2f_awready),
	.h2f_wdata  (seam_h2f_wdata),
	.h2f_wstrb  (seam_h2f_wstrb),
	.h2f_wvalid (seam_h2f_wvalid),
	.h2f_wready (seam_h2f_wready),
	.h2f_bresp  (seam_h2f_bresp),
	.h2f_bvalid (seam_h2f_bvalid),
	.h2f_bready (seam_h2f_bready),
	.h2f_araddr (seam_h2f_araddr),
	.h2f_arsize (seam_h2f_arsize),
	.h2f_arprot (seam_h2f_arprot),
	.h2f_arvalid(seam_h2f_arvalid),
	.h2f_arready(seam_h2f_arready),
	.h2f_rdata  (seam_h2f_rdata),
	.h2f_rresp  (seam_h2f_rresp),
	.h2f_rvalid (seam_h2f_rvalid),
	.h2f_rready (seam_h2f_rready)
`endif
);

// RTG mouse pointer on the HDMI output, under the OSD (same $B80C00 feed as the analog overlay)
`ifndef MISTER_DEBUG_NOHDMI
`ifdef MISTER_FB_PALETTE
rtg_hdmi_osd_sprite u_rtg_hdmi_osd_sprite
(
	.wr_clk    (fb_pal_clk),
	.wr        (fb_spr_wr),
	.waddr     (fb_spr_a),
	.wdata     (fb_spr_d),
	.clk_sys   (clk_sys),     // position mapping runs in the slow domain
	.clk_video (clk_hdmi),
	.ce        (scaler_out),
	.rst       (reset),
	.din       (hdmi_data_mask),
	.de_in     (hdmi_de_mask),
	.hs_in     (hdmi_hs_mask),
	.vs_in     (hdmi_vs_mask),
	.dout      (hdmi_data_spr),
	.de_out    (hdmi_de_spr),
	.hs_out    (hdmi_hs_spr),
	.vs_out    (hdmi_vs_spr),
	.hmin      (hmin),
	.hmax      (hmax),
	.vmin      (vmin),
	.vmax      (vmax),
	.fb_width  (FB_WIDTH),
	.fb_height (FB_HEIGHT),
	.rtg_en    (RTG_EN)      // only while RTG is the displayed source
);
`else
// no sprite feed: pass the scaled video through
assign {hdmi_data_spr, hdmi_de_spr, hdmi_hs_spr, hdmi_vs_spr} =
       {hdmi_data_mask, hdmi_de_mask, hdmi_hs_mask, hdmi_vs_mask};
`endif
`endif

// native-rate RTG analog scanout: a ram1 (f2h_sdram1) reader on clk_100m, the raster on clk_vid + clock-enable
assign ram_clk = clk_100m;

wire [1:0] rtg_cmode  = (RTG_FMT[2:0]==3'b011) ? 2'd0 :   // 8bpp CLUT
                        (RTG_FMT[2:0]==3'b100) ? 2'd1 :   // 16bpp
                        2'd2;                             // 24/32bpp
wire [1:0] rtg_bpp_l2 = (RTG_FMT[2:0]==3'b011) ? 2'd0 :   // log2 bytes/pixel
                        (RTG_FMT[2:0]==3'b100) ? 2'd1 : 2'd2;
wire       rtg_1555   = RTG_FMT[3];
wire       rtg_swap   = RTG_FMT[5];                  // byte swap, 16bpp only
wire       rtg_fmt_ok = (RTG_FMT[2:0] != 3'b101);      // packed 24bpp is not supported

// rasters: 15.625 kHz / 50 Hz up to 360x288, VGA 640x480@60 otherwise
localparam [11:0] RTG_LO_HTOTAL = 12'd459, RTG_LO_HSW = 12'd34,  RTG_LO_HBP = 12'd41;
localparam [11:0] RTG_LO_VTOTAL = 12'd312, RTG_LO_VSW = 12'd3;
localparam [11:0] RTG_LO_HMAX   = 12'd360, RTG_LO_VMAX = 12'd288;
localparam [11:0] RTG_HI_HTOTAL = 12'd912, RTG_HI_HSW = 12'd110, RTG_HI_HBP = 12'd55;
localparam [11:0] RTG_HI_VTOTAL = 12'd525, RTG_HI_VSW = 12'd2;
localparam [11:0] RTG_HI_HMAX   = 12'd640, RTG_HI_VMAX = 12'd480;

wire rtg_lores = (RTG_WIDTH <= RTG_LO_HMAX) && (RTG_HEIGHT <= RTG_LO_VMAX);

reg  [11:0] rtg_w_v  = 12'd0;
reg  [11:0] rtg_h_v  = 12'd0;
reg         rtg_lo_v = 1'b0;
always @(posedge clk_vid) begin
	rtg_w_v  <= RTG_WIDTH;
	rtg_h_v  <= RTG_HEIGHT;
	rtg_lo_v <= rtg_lores;
end

wire [11:0] rtg_htotal_c = rtg_lo_v ? RTG_LO_HTOTAL : RTG_HI_HTOTAL;
wire [11:0] rtg_hsw      = rtg_lo_v ? RTG_LO_HSW    : RTG_HI_HSW;
wire [11:0] rtg_hbp      = rtg_lo_v ? RTG_LO_HBP    : RTG_HI_HBP;
wire [11:0] rtg_vtotal_c = rtg_lo_v ? RTG_LO_VTOTAL : RTG_HI_VTOTAL;
wire [11:0] rtg_vsw      = rtg_lo_v ? RTG_LO_VSW    : RTG_HI_VSW;
wire [11:0] rtg_hmax     = rtg_lo_v ? RTG_LO_HMAX   : RTG_HI_HMAX;
wire [11:0] rtg_vmax     = rtg_lo_v ? RTG_LO_VMAX   : RTG_HI_VMAX;

wire [11:0] rtg_hact_c = ((rtg_w_v == 12'd0) || (rtg_w_v > rtg_hmax)) ? rtg_hmax : rtg_w_v;
wire [11:0] rtg_vact_c = ((rtg_h_v == 12'd0) || (rtg_h_v > rtg_vmax)) ? rtg_vmax : rtg_h_v;

wire [11:0] rtg_vfp_c  = (rtg_vtotal_c - rtg_vact_c - rtg_vsw) >> 1;  // centred vertically

reg [11:0] rtg_htotal   = RTG_HI_HTOTAL;
reg [11:0] rtg_vtotal   = RTG_HI_VTOTAL;
reg [11:0] rtg_hact     = 12'd0;
reg [11:0] rtg_vact     = 12'd0;
reg [11:0] rtg_hs_start = RTG_HI_HTOTAL;
reg [11:0] rtg_hs_end   = RTG_HI_HTOTAL;
reg [11:0] rtg_vs_start = RTG_HI_VTOTAL;
reg [11:0] rtg_vs_end   = RTG_HI_VTOTAL;
always @(posedge clk_vid) begin
	rtg_htotal   <= rtg_htotal_c;
	rtg_vtotal   <= rtg_vtotal_c;
	rtg_hact     <= rtg_hact_c;
	rtg_vact     <= rtg_vact_c;
	rtg_hs_end   <= rtg_htotal_c - rtg_hbp;            // fixed standard back porch
	rtg_hs_start <= rtg_htotal_c - rtg_hbp - rtg_hsw;
	rtg_vs_start <= rtg_vact_c + rtg_vfp_c;
	rtg_vs_end   <= rtg_vact_c + rtg_vfp_c + rtg_vsw;
end

// pixel clock-enable: clk_vid/16 or clk_vid/4
wire [4:0] rtg_ce_div = rtg_lo_v ? 5'd16 : 5'd4;
reg  [4:0] rtg_ce_cnt = 5'd0;
reg        rtg_ce     = 1'b0;
always @(posedge clk_vid) begin
	if (rtg_ce_cnt >= (rtg_ce_div - 5'd1)) begin rtg_ce_cnt <= 5'd0;              rtg_ce <= 1'b1; end
	else                                   begin rtg_ce_cnt <= rtg_ce_cnt + 5'd1; rtg_ce <= 1'b0; end
end

reg rtg_rst1 = 1'b1, rtg_rst2 = 1'b1;
always @(posedge clk_vid) begin
	rtg_rst1 <= reset;
	rtg_rst2 <= rtg_rst1;
end
wire rst_rtgpix = rtg_rst2;

wire         rtg_lb_we;
wire   [9:0] rtg_lb_waddr;    // {bank, word[8:0]} (LB_AW=9)
wire  [63:0] rtg_lb_wdata;
wire         rtg_frame_tgl, rtg_line_tgl;

wire [23:0] sc_rgb;
wire        sc_hs, sc_vs, sc_de, sc_cs;

rtg_ddr_reader #(.LB_AW(9), .MAX_BURST(8'd16)) u_rtg_reader
(
	.clk              (clk_100m),
	.rst              (reset),
	.enable           (rtg_scanout_active),
	.fb_base          (RTG_BASE),
	.fb_stride        (RTG_STRIDE),
	.fb_width         (RTG_WIDTH),
	.fb_height        (RTG_HEIGHT),
	.fb_bpp_l2        (rtg_bpp_l2),
	.px_frame_tgl     (rtg_frame_tgl),
	.px_line_tgl      (rtg_line_tgl),
	.avl_address      (ram_address),
	.avl_burstcount   (ram_burstcount),
	.avl_read         (ram_read),
	.avl_waitrequest  (ram_waitrequest),
	.avl_readdata     (ram_readdata),
	.avl_readdatavalid(ram_readdatavalid),
	.avl_writedata    (ram_writedata),
	.avl_byteenable   (ram_byteenable),
	.avl_write        (ram_write),
	.lb_we            (rtg_lb_we),
	.lb_waddr         (rtg_lb_waddr),
	.lb_wdata         (rtg_lb_wdata)
);

rtg_scanout #(.LB_AW(9), .HTOTAL0(RTG_HI_HTOTAL), .VTOTAL0(RTG_HI_VTOTAL)) u_rtg_scanout
(
	.clk       (clk_vid),
	.rst       (rst_rtgpix),
	.ce        (rtg_ce),
	.htotal    (rtg_htotal), .hact(rtg_hact), .hs_start(rtg_hs_start), .hs_end(rtg_hs_end),
	.vtotal    (rtg_vtotal), .vact(rtg_vact), .vs_start(rtg_vs_start), .vs_end(rtg_vs_end),
	.hs_pol    (1'b0),  .vs_pol(1'b0),     // neg H/V sync (inverted at pin, like native)
	.cmode     (rtg_cmode),
	.fmt_1555  (rtg_1555),
	.fmt_swap  (rtg_swap),
	.lb_wclk   (clk_100m),
	.lb_we     (rtg_lb_we),
	.lb_waddr  (rtg_lb_waddr),
	.lb_wdata  (rtg_lb_wdata),
	.pal_clk   (fb_pal_clk),
	.pal_wr    (fb_pal_wr),
	.pal_a     (fb_pal_a),
	.pal_d     (fb_pal_d),
	.spr_wclk  (fb_pal_clk),
	.spr_wr    (fb_spr_wr),
	.spr_waddr (fb_spr_a),
	.spr_wdata (fb_spr_d),
	.rgb       (sc_rgb),
	.hs        (sc_hs),
	.vs        (sc_vs),
	.de        (sc_de),
	.frame_tgl (rtg_frame_tgl),
	.line_tgl  (rtg_line_tgl)
);

// OSD over the RTG analog output; osd_status is driven by vga_osd
wire [23:0] rtgo_rgb;
wire        rtgo_hs, rtgo_vs, rtgo_de;
osd rtg_osd
(
	.clk_sys   (clk_sys),
	.io_osd    (io_osd_vga),
	.io_strobe (io_strobe),
	.io_din    (io_din),
	.osd_status(),
	.clk_video (clk_vid),
	.din       (sc_rgb),
	.hs_in     (sc_hs),
	.vs_in     (sc_vs),
	.de_in     (sc_de),
	.dout      (rtgo_rgb),
	.hs_out    (rtgo_hs),
	.vs_out    (rtgo_vs),
	.de_out    (rtgo_de)
);

// sync and DAC output stage, as on the native path
csync csync_rtg(clk_vid, rtgo_hs, rtgo_vs, sc_cs);
vga_out u_rtgs_vgaout
(
	.clk      (clk_vid),
	.ypbpr_en (ypbpr_en),
	.hsync    (rtgo_hs),
	.vsync    (rtgo_vs),
	.csync    (sc_cs),
	.de       (rtgo_de),
	.din      (rtgo_rgb),
	.dout     (rtgs_o),
	.hsync_o  (rtgs_hs),
	.vsync_o  (rtgs_vs),
	.csync_o  (rtgs_cs),
	.de_o     (rtgs_de)
);


endmodule

/////////////////////////////////////////////////////////////////////

module sync_fix
(
	input clk,
	
	input sync_in,
	output sync_out
);

assign sync_out = sync_in ^ pol;

reg pol;
always @(posedge clk) begin
	reg [31:0] cnt;
	reg s1,s2;

	s1 <= sync_in;
	s2 <= s1;
	cnt <= s2 ? (cnt - 1) : (cnt + 1);

	if(~s2 & s1) begin
		cnt <= 0;
		pol <= cnt[31];
	end
end

endmodule

/////////////////////////////////////////////////////////////////////

// CSync generation
// Shifts HSync left by 1 HSync period during VSync

module csync
(
	input  clk,
	input  hsync,
	input  vsync,

	output csync
);

assign csync = (csync_vs ^ csync_hs);

reg csync_hs, csync_vs;
always @(posedge clk) begin
	reg prev_hs;
	reg [15:0] h_cnt, line_len, hs_len;

	// Count line/Hsync length
	h_cnt <= h_cnt + 1'd1;

	prev_hs <= hsync;
	if (prev_hs ^ hsync) begin
		h_cnt <= 0;
		if (hsync) begin
			line_len <= h_cnt - hs_len;
			csync_hs <= 0;
		end
		else hs_len <= h_cnt;
	end
	
	if (~vsync) csync_hs <= hsync;
	else if(h_cnt == line_len) csync_hs <= 1;
	
	csync_vs <= vsync;
end

endmodule
