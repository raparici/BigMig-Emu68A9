# GPU clock (gpu_pll, 75 MHz) and its register-block crossings; empty without BIGMIG_GPU
set f1_gpu_clk [get_clocks -nowarn {gpu_pll|altera_pll_i|*[0].*|divclk}]
if { [get_collection_size $f1_gpu_clk] > 0 } {
  set_clock_groups -exclusive -group $f1_gpu_clk -group [remove_from_collection [all_clocks] $f1_gpu_clk]

  set_net_delay -max 1.5  -from [get_registers {u_gpu|regs|req_t}]   -to [get_registers {u_gpu|regs|req_s[0]}]
  set_net_delay -max 1.5  -from [get_registers {u_gpu|regs|ack_t}]   -to [get_registers {u_gpu|regs|ack_s[0]}]
  set_net_delay -max 1.5  -from [get_registers {u_gpu|regs|g_alive}] -to [get_registers {u_gpu|regs|alive_s[0]}]
  set_net_delay -max 10.0 -from [get_registers {u_gpu|regs|a_h[*] u_gpu|regs|d_h[*] u_gpu|regs|rd_h}] \
                          -to   [get_registers {u_gpu|regs|ga[*] u_gpu|regs|dg[*] u_gpu|regs|wg}]
  set_net_delay -max 10.0 -from [get_registers {u_gpu|regs|rd_g[*]}] -to [get_registers {u_gpu|regs|rdata[*]}]

  # fitter-only over-constraint on emu c0 (inert in quartus_sta)
  if { [string equal "quartus_fit" $::TimeQuestInfo(nameofexecutable)] } {
    set f1_c0 [get_clocks {emu|pll|pll_inst|altera_pll_i|cyclonev_pll|counter\[0\].output_counter|divclk}]
    set_clock_uncertainty -setup -add -from $f1_c0 -to $f1_c0 0.6
  }
}
