#==========================================================================#
#  seam.sdc  --  Emu68-A9 Hybrid chip-seam clock-domain-crossing constraints #
#                The one remaining                                            #
#                 non-optional maintainability debt").                       #
#--------------------------------------------------------------------------#
#  The seam has TWO genuine clock-domain crossings:                          #
#                                                                            #
#    AXI / h2f clock  (S_AXI_ACLK)  ==  *|h2f_user0_clk   (100 MHz)          #
#         <-- the HPS->FPGA AXI master clock; see sys/sys_top.sdc:5          #
#           create_clock -period "100.0 MHz" [get_pins ... *|h2f_user0_clk]  #
#                                                                            #
#    Amiga chip clock (sync_clk = clk_sys, 28.6 MHz)                         #
#         ==  *|pll|pll_inst|altera_pll_i|*[*].*|divclk                      #
#         <-- the Minimig PLL output; the exact node string used by          #
#             sys/sys_top.sdc:14 + BigMig.sdc for the Amiga domain.         #
#                                                                            #
#  NOTE on the existing clock groups: sys/sys_top.sdc already declares       #
#  *|h2f_user0_clk and the Amiga *divclk in SEPARATE -exclusive groups, so   #
#  TimeQuest does not analyse setup/hold BETWEEN them (correct for an async   #
#  CDC).  What the blanket clock-group cut does NOT provide, and what THIS    #
#  file adds, is (a) explicit CDC intent on the single-bit handshake toggles  #
#  and 2-FF resync inputs, and (b) a per-bus TRANSPORT/skew bound on the      #
#  multi-bit payload so the toggle-qualified data cannot be latched torn.     #
#                                                                            #
#  All node paths are rooted at the MiSTer core instance `emu` (sys_top.v:   #
#  1795 `emu emu`), the same prefix BigMig.sdc uses (`emu|cpu_wrapper|...`). #
#  The seam nodes exist only when the core is built with HYBRID_EMU; without  #
#  it these collections are empty and Quartus emits a benign "no such node"   #
#  warning.  If a node name does not match after synthesis, check it against  #
#  the fitted netlist (VHDL vector signals appear as `sig[0]`, enum state as  #
#  `sstate.<name>`) -- a normal one-time SDC bring-up step.                   #
#                                                                            #
#  Node patterns are BRACED (Quartus/Tcl idiom, as in BigMig.sdc) so the     #
#  `[*]`/`[0]` bit-selects are literal and not Tcl command substitution.      #
#==========================================================================#

# One launch-clock PERIOD ("set_max_delay = one
# launch-clock period on the payload buses qualified by the toggle").
set AXI_PERIOD  10.0    ;# h2f 100 MHz      -> AXI-domain launch (AXI->SYNC payload)
set SYNC_PERIOD 35.0    ;# clk_sys 28.6 MHz -> chip-domain launch (SYNC->AXI readback)

#--------------------------------------------------------------------------#
# 1. seam_engine REQ/ACK toggle handshake  (the primary seam CDC)           #
#--------------------------------------------------------------------------#
# req_tgl / done_tgl are 1-bit Gray toggles resynchronised by a 2-FF chain
# (req_sync / done_sync).  A toggle is metastability-safe by construction, so
# the launch->first-FF path carries no setup/hold requirement: false-path it.
set_false_path -from [get_registers {emu|u_axi_seam_slave|u_seam_engine|req_tgl}] \
               -to   [get_registers {emu|u_axi_seam_slave|u_seam_engine|req_sync[0]}]
set_false_path -from [get_registers {emu|u_axi_seam_slave|u_seam_engine|done_tgl_sync}] \
               -to   [get_registers {emu|u_axi_seam_slave|u_seam_engine|done_sync[0]}]

#--------------------------------------------------------------------------#
# 2. seam_engine PAYLOAD buses (qualified by the toggles above)             #
#--------------------------------------------------------------------------#
# xa_addr / xa_wdata / xa_ctrl are written in the AXI domain BEFORE the trigger
# and are quasi-static across the whole transaction; the SYNC side reads them
# only after req_sync survives 2 FFs.  They are NOT setup/hold-critical, but the
# per-bit routing skew MUST be bounded so every bit lands within one destination
# cycle (else a torn value could be captured).  Bound = one AXI launch period.
# -to the SYNC clock covers every consumer (the bridge FSM + the seam_engine SYNC
# FSM) while -from the AXI payload regs keeps intra-AXI-domain paths untouched.
set_max_delay -from [get_registers {emu|u_axi_seam_slave|u_seam_engine|live_addr[*] \
                                    emu|u_axi_seam_slave|u_seam_engine|live_wdata[*] \
                                    emu|u_axi_seam_slave|u_seam_engine|live_ctrl[*]}] \
              -to   [get_clocks {*|pll|pll_inst|altera_pll_i|*[*].*|divclk}] $AXI_PERIOD

# Read data returns SYNC->AXI, qualified by done_tgl.  readdata_s is the low/only
# word; readdata_hi_s is the longword high word (constant 0 unless LONGWORD_EN=1).
#
# D9 (IMPLEMENTATION-REVIEW-2026-07.md 2.3): the bound here must be ONE *AXI*
# PERIOD, NOT one SYNC period.  The capture (`rdata_axi <= readdata_s` on
# done_edge, seam_engine.v) happens only 2-3 AXI clocks (20-30 ns) after
# done_tgl toggles, and the done_tgl->done_sync[0] edge is false-pathed above
# (it may route arbitrarily fast).  Under the old $SYNC_PERIOD (35 ns) bound a
# 25-35 ns data route was LEGAL and could arrive AFTER the capture edge ->
# stale/torn rdata_axi on silicon, invisible to the delay-free sim.  Bounding
# at $AXI_PERIOD guarantees the data lands >=1 AXI clock before the earliest
# possible done_edge capture (2 clocks after the toggle crosses).
set_max_delay -from [get_registers {emu|u_axi_seam_slave|u_seam_engine|readdata_sync[*] \
                                    emu|u_axi_seam_slave|u_seam_engine|readdata_hi_s[*]}] \
              -to   [get_clocks {*|h2f_user0_clk}] $AXI_PERIOD

#--------------------------------------------------------------------------#
# 3. axi_seam_slave cerr resync  (bridge sticky DTACK-timeout -> AXI)      #
#--------------------------------------------------------------------------#
# hyb_cerr is a slowly-changing sticky 1-bit flag 2-FF synchronised into the AXI
# clock (cerr_sync) and surfaced in REG_STATUS/REG_RESULT bit30.  False-path the
# launch->first-FF edge.
set_false_path -from [get_registers {emu|u_hybrid_bridge|cerr}] \
               -to   [get_registers {emu|u_axi_seam_slave|cerr_sync[0]}]

#--------------------------------------------------------------------------#
# 4. seam soft-reset resync  (stretched REG_OVL[1], AXI -> chip clk)       #
#--------------------------------------------------------------------------#
# S-S3/D15/D12: the reset source is now `srst_lvl` (the registered, self-
# clearing stretcher output in axi_seam_slave -- a clean 1-bit level, NOT the
# raw ovl[1] register).  It is 2-FF synchronised into clk_sys at THREE sinks:
#   * the bridge FSM hammer            (u_hybrid_bridge|srst_sync[0])
#   * seam_engine's whole-engine flush  (u_seam_engine|srst_sync[0])
#   * the chipset-reset request        (u_axi_seam_slave|crst_sync[0])
# 1-bit level held ~10 us: false-path all three first-FF edges.
set_false_path -from [get_registers {emu|u_axi_seam_slave|srst_lvl}] \
               -to   [get_registers {emu|u_hybrid_bridge|srst_sync[0] \
                                     emu|u_axi_seam_slave|u_seam_engine|srst_sync[0] \
                                     emu|u_axi_seam_slave|crst_sync[0]}]

#--------------------------------------------------------------------------#
# 5. seam_ipl IPL / reset_n resync  (Paula, chip clk -> AXI)         #
#--------------------------------------------------------------------------#
# D11: irq_s[2:0] is a MULTI-BIT word (Paula moves several IPL bits per edge),
# NOT a set of independent levels -- the old blanket false-path allowed
# unbounded per-bit skew, so a torn level could persist for >1 AXI sample and
# defeat any filter.  The RTL now publishes IPL only after it is stable for
# TWO consecutive AXI samples (irq_hold, seam_ipl.v); that filter is
# sound iff the per-bit skew of irq_s -> irq_m1 is bounded to ONE AXI period,
# which this constraint provides (same skew-bound idiom as sections 2/6).
set_max_delay -from [get_registers {emu|u_axi_seam_slave|u_seam_ipl|ipl_src[*]}] \
              -to   [get_clocks {*|h2f_user0_clk}] $AXI_PERIOD

# rst_s is a genuine single-bit level (cannot tear): false-path as before.
set_false_path -from [get_registers {emu|u_axi_seam_slave|u_seam_ipl|rst_src}] \
               -to   [get_registers {emu|u_axi_seam_slave|u_seam_ipl|rst_m1}]

#--------------------------------------------------------------------------#
# 6. seam_cpuregs VBR / CACR resample  (AXI -> chip clk)               #
#--------------------------------------------------------------------------#
# vbr_reg[31:0] / cacr_reg[3:0] are written in the AXI domain and resampled into
# clk_sys (vbr_sreg / cacr_sreg).  These ARE multi-bit buses read as a unit by the
# fabric, so bound the skew (one AXI launch period) rather than false-path them.
#
# POST-FIT NOTE (2026-07-05, verified on the f559fc7 fit): the fitter SWEEPS this
# whole chain — BigMig.sv connects seam_vbr/seam_cacr to NOTHING (the fabric no
# longer consumes the m68k VBR/CACR mirrors; Hybrid-era leftover) — so this
# set_max_delay and the matching set_net_delay fallback below report "could not
# be matched with a register / empty collection" at compile.  BENIGN: dead
# feature, zero registers to constrain.  If a consumer is ever added back, the
# constraints (kept) arm themselves again.  All LOAD-BEARING seam bounds
# (sections 2/5 + their net-delay fallbacks) matched and applied on this fit.
# (FL-11 hardening cleanup 2026-07-06: the vbr/cacr set_max_delay REMOVED — the
# feature is fitter-swept dead RTL and the constraint only produced recurring
# could-not-be-matched warnings at every compile. Restore from git if the
# seam_vbr/seam_cacr consumers ever return.)

#==========================================================================#
#  POST-FIT VERIFICATION -- REQUIRED, NOT OPTIONAL (D9 companion check)      #
#--------------------------------------------------------------------------#
#  sys/sys_top.sdc declares *|h2f_user0_clk and the Amiga *divclk in          #
#  SEPARATE `set_clock_groups -EXCLUSIVE` groups.  In TimeQuest an exclusive  #
#  group cut has HIGHER precedence than set_max_delay: every section-2/5/6    #
#  bound in this file can be silently NULLED, leaving the readdata / xa_* /   #
#  irq_s skew completely unconstrained -- the exact stale-RDATA failure D9    #
#  fixes would then still be possible on silicon while this file LOOKS        #
#  correct.  After EVERY fit, in the TimeQuest Tcl console run:               #
#                                                                            #
#    report_sdc                       ;# section-2/5/6 set_max_delay listed?  #
#    report_path -from [get_registers {emu|u_axi_seam_slave|u_seam_engine|readdata_sync[*]}] \
#                -to   [get_registers {emu|u_axi_seam_slave|u_seam_engine|rdata_axi[*]}] -npaths 10
#    report_timing -setup -from [get_registers {emu|u_axi_seam_slave|u_seam_engine|readdata_sync[*]}] \
#                  -to [get_clocks {*|h2f_user0_clk}] -npaths 10              #
#                                                                            #
#  * If report_timing shows the paths analysed against the $AXI_PERIOD        #
#    max-delay -> the bounds are LIVE, done.                                  #
#  * If the paths report as "cut" / not analysed (clock-group dominance)      #
#    -> the set_max_delay is INERT: uncomment the FALLBACK block below        #
#    (set_net_delay is a pure routing-delay constraint that clock-group cuts  #
#    do NOT override) and re-fit.  Alternatively change that one pairing in   #
#    sys_top.sdc from -exclusive to -asynchronous (keeps the setup/hold cut   #
#    but HONOURS set_max_delay) -- sys_top.sdc is shared with every core, so  #
#    prefer the local set_net_delay fallback.                                 #
#--------------------------------------------------------------------------#
#  FALLBACK — ENABLED pre-fit (review 2026-07 #4): the -exclusive clock groups #
#  in sys_top.sdc CUT the set_max_delay bounds above (a group cut outranks     #
#  max_delay), so the net-delay bounds below are the ones that actually hold.  #
#                                                                            #
set_net_delay -max $AXI_PERIOD  -from [get_registers {emu|u_axi_seam_slave|u_seam_engine|live_addr[*] emu|u_axi_seam_slave|u_seam_engine|live_wdata[*] emu|u_axi_seam_slave|u_seam_engine|live_ctrl[*]}] -to [get_registers {emu|u_hybrid_bridge|*}]
# FL-11 audit fix (finding 4b): xa_ctrl[4] (the longword bit) ALSO feeds
# seam_engine's OWN sync-domain FSM (sstate/word_sel/hi-word capture) — a crossing
# that previously had NO effective constraint (the max_delay section is cut by the
# exclusive clock groups). Bound it like the other payload nets.
set_net_delay -max $AXI_PERIOD  -from [get_registers {emu|u_axi_seam_slave|u_seam_engine|live_ctrl[*]}] -to [get_registers {emu|u_axi_seam_slave|u_seam_engine|sstate* emu|u_axi_seam_slave|u_seam_engine|word_sel* emu|u_axi_seam_slave|u_seam_engine|readdata_hi_s[*] emu|u_axi_seam_slave|u_seam_engine|hreq*}]
set_net_delay -max $AXI_PERIOD  -from [get_registers {emu|u_axi_seam_slave|u_seam_engine|readdata_sync[*] emu|u_axi_seam_slave|u_seam_engine|readdata_hi_s[*]}] -to [get_registers {emu|u_axi_seam_slave|u_seam_engine|rdata_axi[*] emu|u_axi_seam_slave|u_seam_engine|rdata_hi_axi[*]}]
set_net_delay -max $AXI_PERIOD  -from [get_registers {emu|u_axi_seam_slave|u_seam_ipl|ipl_src[*]}] -to [get_registers {emu|u_axi_seam_slave|u_seam_ipl|ipl_m1[*]}]
# (vbr/cacr net-delay fallback removed with its max_delay — dead feature, see above.)
#                                                                            #
#  (The old fallback bounded readdata at $SYNC_PERIOD -- that reproduced the  #
#   D9 hole; it is $AXI_PERIOD everywhere now, matching section 2/5.)         #
#==========================================================================#
