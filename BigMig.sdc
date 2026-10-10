derive_pll_clocks
derive_clock_uncertainty


set_multicycle_path -from {emu|amiga_clk|cck*} -to {emu|ram1|*} -setup 2
set_multicycle_path -from {emu|amiga_clk|cck*} -to {emu|ram1|*} -hold 1
set_multicycle_path -from {emu|minimig|*} -to {emu|ram1|*} -setup 2
set_multicycle_path -from {emu|minimig|*} -to {emu|ram1|*} -hold 1

# chip_write_retry samples the SAME chip-data bus as ram1 (stable for a full 7M period), so it
# needs the SAME multicycle 2: without it the capture registers miss clk_114 setup by ~3 ns.
# Only when the buffer exists (BIGMIG_NO_CHIP_WRITE_RETRY removes it).
if {[get_collection_size [get_registers -nowarn {emu|u_chip_write_retry|*}]] > 0} {
set_multicycle_path -from {emu|amiga_clk|cck*} -to {emu|u_chip_write_retry|*} -setup 2
set_multicycle_path -from {emu|amiga_clk|cck*} -to {emu|u_chip_write_retry|*} -hold 1
set_multicycle_path -from {emu|minimig|*}      -to {emu|u_chip_write_retry|*} -setup 2
set_multicycle_path -from {emu|minimig|*}      -to {emu|u_chip_write_retry|*} -hold 1
}

# ram1 (clk_114) <-> hybrid bridge (negedge clk_sys). The PLL makes clk_sys edges COINCIDE with
# clk_114 posedges (same VCO, 4:1), so TimeQuest analyses a single-cycle relationship here.
# ram1 -> bridge carries held-LEVEL handshakes polled by the bridge FSM, and the 16-bit read bus
# is re-captured one negedge after ramready. Multicycle setup 2 = one full clk_sys window --
# deliberately NOT a false path, so the router stays honest; hold stays at the coincident edge.
set_multicycle_path -from {emu|ram1|*} -to {emu|u_hybrid_bridge|*} -setup 2
set_multicycle_path -from {emu|ram1|*} -to {emu|u_hybrid_bridge|*} -hold 1
# bridge cp_* -> ram1: the payload registers latch one negedge BEFORE cp_cs arms, so every
# ram1-side sample sees a payload stable for >= 4 clk_114 cycles, and cp_cs is a held level whose
# sampling skew only shifts the poll. Ordering is by CONSTRUCTION, hence a full false path.
# cp_wdata is a dedicated register precisely so this pattern cannot catch the chip-bus datapath.
set_false_path -from {emu|u_hybrid_bridge|cp_*} -to {emu|ram1|*}


set_false_path -from {emu|minimig|USERIO1|cpu_config*}
set_false_path -from {emu|minimig|USERIO1|ide_config*}
set_false_path -from {emu|minimig|USERIO1|bootrom}
set_false_path -from {emu|minimig|CPU1|halt}

#these constraints aren't really correct, but help fitting.
#28MHz pixel clock might be affected when scandoubler fx is used.
# Only with BIGMIG_SCANDOUBLER (no scandoubler otherwise).
if {[get_collection_size [get_registers -nowarn {*Hq2x*}]] > 0} {
set_multicycle_path -to {*Hq2x*} -setup 2
set_multicycle_path -to {*Hq2x*} -hold 1
}
set_multicycle_path -from [get_clocks { *|pll|pll_inst|altera_pll_i|*[0].*|divclk}] -to {ascal|*} -setup 2
set_multicycle_path -from [get_clocks { *|pll|pll_inst|altera_pll_i|*[0].*|divclk}] -to {ascal|*} -hold 1
