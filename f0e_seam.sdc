# seam handshake toggles: false paths for timing, but keep their routing short
set_net_delay -max 1.5 -from [get_registers {emu|u_axi_seam_slave|u_seam_engine|req_tgl}] \
                       -to   [get_registers {emu|u_axi_seam_slave|u_seam_engine|req_sync[0]}]
set_net_delay -max 1.5 -from [get_registers {emu|u_axi_seam_slave|u_seam_engine|done_tgl_sync}] \
                       -to   [get_registers {emu|u_axi_seam_slave|u_seam_engine|done_sync[0]}]
