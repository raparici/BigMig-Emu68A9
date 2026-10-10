# clk_sys (c1) -> clk_vid (c0) crossings: same VCO, 4:1, phase-aligned
set f0e_c1 [get_clocks {emu|pll|pll_inst|altera_pll_i|cyclonev_pll|counter\[1\].output_counter|divclk}]

# Denise RGB -> gamma_corr input: captured on ce_pix, never at the c1 edge that launches the pixel
set_multicycle_path -hold -end 1 -from $f0e_c1 \
    -to [get_registers {emu|video_mixer|gamma|R_in[*] emu|video_mixer|gamma|G_in[*] emu|video_mixer|gamma|B_in[*] emu|video_mixer|gamma|gamma_index[*]}]

# analog RTG pointer: first stages of the 2-FF syncs
set_false_path -from [get_registers {*u_rtg_scanout|u_sprite|w_*}] \
               -to   [get_registers {*u_rtg_scanout|u_sprite|x_m[*] *u_rtg_scanout|u_sprite|y_m[*] *u_rtg_scanout|u_sprite|ena_m *u_rtg_scanout|u_sprite|c1_m[*] *u_rtg_scanout|u_sprite|c2_m[*] *u_rtg_scanout|u_sprite|c3_m[*]}]

# OSD info-window height: quasi-static, reloaded every line
set_false_path -from [get_registers {*_osd|infoh[*]}] -to [get_registers {*_osd|osd_hcnt2[*]}]
