# RTG native scanout and HDMI pointer overlay: clock-domain crossings (the clock groups are already cut in sys_top.sdc)

# line/frame boundary toggles, clk_vid -> reader 2-FF sync
set_false_path -from [get_registers {*u_rtg_scanout|frame_tgl}] \
               -to   [get_registers {*u_rtg_reader|frame_m1}]
set_false_path -from [get_registers {*u_rtg_scanout|line_tgl}] \
               -to   [get_registers {*u_rtg_reader|line_m1}]

# quasi-static RTG descriptor, latched per frame by its consumers
set_false_path -from {RTG_BASE[*]}
set_false_path -from {RTG_STRIDE[*]}
set_false_path -from {RTG_WIDTH[*]}
set_false_path -from {RTG_HEIGHT[*]}
set_false_path -from {RTG_FMT[*]}
set_false_path -from {RTG_EN}

# HDMI pointer: first stages of the 2-FF syncs (fb_pal_clk -> clk_sys *_a, clk_sys -> clk_hdmi *_m)
set_false_path -to [get_registers {*u_rtg_hdmi_osd_sprite|*_a}]
set_false_path -to [get_registers {*u_rtg_hdmi_osd_sprite|*_a[*]}]
set_false_path -to [get_registers {*u_rtg_hdmi_osd_sprite|*_m}]
set_false_path -to [get_registers {*u_rtg_hdmi_osd_sprite|*_m[*]}]
# quasi-static geometry into the load-enabled snapshot of the position FSM
set_multicycle_path -setup -to [get_registers {*u_rtg_hdmi_osd_sprite|p_*}] 2
set_multicycle_path -hold  -to [get_registers {*u_rtg_hdmi_osd_sprite|p_*}] 1
set_multicycle_path -setup -to [get_registers {*u_rtg_hdmi_osd_sprite|map_*}] 2
set_multicycle_path -hold  -to [get_registers {*u_rtg_hdmi_osd_sprite|map_*}] 1
set_multicycle_path -setup -to [get_registers {*u_rtg_hdmi_osd_sprite|vw_r*}] 2
set_multicycle_path -hold  -to [get_registers {*u_rtg_hdmi_osd_sprite|vw_r*}] 1
set_multicycle_path -setup -to [get_registers {*u_rtg_hdmi_osd_sprite|vh_r*}] 2
set_multicycle_path -hold  -to [get_registers {*u_rtg_hdmi_osd_sprite|vh_r*}] 1
