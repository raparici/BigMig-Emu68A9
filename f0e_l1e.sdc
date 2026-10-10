# HDMI pointer: scaler window (clk_vid) into its clk_sys copy, quasi-static
set_false_path -to [get_registers {*u_rtg_hdmi_osd_sprite|hmin_s[*] *u_rtg_hdmi_osd_sprite|hmax_s[*] *u_rtg_hdmi_osd_sprite|vmin_s[*] *u_rtg_hdmi_osd_sprite|vmax_s[*]}]
