# fitter-only over-constraint on the HDMI pixel clock (inert in quartus_sta)
if { [string equal "quartus_fit" $::TimeQuestInfo(nameofexecutable)] } {
  set f0e_hdmi [get_clocks {pll_hdmi|pll_hdmi_inst|altera_pll_i|cyclonev_pll|counter\[0\].output_counter|divclk}]
  set_clock_uncertainty -setup -add -from $f0e_hdmi -to $f0e_hdmi 0.8
}
