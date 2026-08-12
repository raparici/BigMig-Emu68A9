derive_pll_clocks
derive_clock_uncertainty


set_multicycle_path -from {emu|amiga_clk|cck*} -to {emu|ram1|*} -setup 2
set_multicycle_path -from {emu|amiga_clk|cck*} -to {emu|ram1|*} -hold 1
set_multicycle_path -from {emu|minimig|*} -to {emu|ram1|*} -setup 2
set_multicycle_path -from {emu|minimig|*} -to {emu|ram1|*} -hold 1

# DR-1 fix: chip_write_retry samples the SAME chip-data bus as ram1 (stable for a
# full 7M period), so it needs the SAME multicycle 2 -- without this its buf_*
# capture registers miss clk_114 setup by ~3 ns (found via quartus_sta on the
# eureka10 build; that -2.941 ns violation is why the fix didn't work on silicon).
set_multicycle_path -from {emu|amiga_clk|cck*} -to {emu|u_chip_write_retry|*} -setup 2
set_multicycle_path -from {emu|amiga_clk|cck*} -to {emu|u_chip_write_retry|*} -hold 1
set_multicycle_path -from {emu|minimig|*}      -to {emu|u_chip_write_retry|*} -setup 2
set_multicycle_path -from {emu|minimig|*}      -to {emu|u_chip_write_retry|*} -hold 1

# VIA-B (#14, 2026-07-11): ram1 (clk_114) <-> hybrid bridge (negedge clk_sys).
# The PLL makes clk_sys edges COINCIDE with clk_114 posedges (same VCO, 4:1), so
# TimeQuest analyses a 0.001ns single-cycle relationship across this interface
# (first eureka14 fit: -4.6ns setup on write_ena/write_req/cpu_ack -> bridge
# stage FSM; second fit: -0.18ns HOLD on cp_addr -> cache, the short-route race).
#
# ram1 -> bridge: held-LEVEL handshakes polled by the bridge FSM (one-poll-late
# is protocol-absorbed) and the 16-bit cpuRD bus is re-captured one negedge
# AFTER ramready (bridge VB_CAP stage). Multicycle setup 2 = one full clk_sys
# window (35ns bound keeps the router honest -- deliberately NOT a false path);
# hold stays at the coincident edge (passes: +0.28 on the take-2 fit).
set_multicycle_path -from {emu|ram1|*} -to {emu|u_hybrid_bridge|*} -setup 2
set_multicycle_path -from {emu|ram1|*} -to {emu|u_hybrid_bridge|*} -hold 1
# bridge cp_* -> ram1: the payload registers (cp_addr/cp_wdata/cp_state/cp_u/
# cp_l) latch one negedge BEFORE cp_cs arms (bridge VB_REQ arm pass), so every
# ram1-side sample sees a payload that has been stable >= 4 clk_114 cycles, and
# cp_cs itself is a held level whose one-cycle sampling skew only shifts the
# poll. Ordering is by CONSTRUCTION, hence a full false path (setup AND the
# failing coincident-edge hold). cp_wdata is a dedicated register precisely so
# this pattern cannot catch the wd_r/chip_din chip-bus datapath.
set_false_path -from {emu|u_hybrid_bridge|cp_*} -to {emu|ram1|*}

# (z2ram/z3ram false-paths removed 2026-07-07: the soft-CPU Zorro RAM is gone with
#  NO_SOFT_CPUS — these referenced the swept cpu_wrapper and only warned at compile.)

set_false_path -from {emu|minimig|USERIO1|cpu_config*}
set_false_path -from {emu|minimig|USERIO1|ide_config*}
set_false_path -from {emu|minimig|USERIO1|bootrom}
set_false_path -from {emu|minimig|CPU1|halt}

#these constraints aren't really correct, but help fitting.
#28MHz pixel clock might be affected when scandoubler fx is used.
set_multicycle_path -to {*Hq2x*} -setup 2
set_multicycle_path -to {*Hq2x*} -hold 1
set_multicycle_path -from [get_clocks { *|pll|pll_inst|altera_pll_i|*[0].*|divclk}] -to {ascal|*} -setup 2
set_multicycle_path -from [get_clocks { *|pll|pll_inst|altera_pll_i|*[0].*|divclk}] -to {ascal|*} -hold 1
