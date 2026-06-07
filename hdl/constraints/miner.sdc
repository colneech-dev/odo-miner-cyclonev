# miner.sdc — Timing constraints for odo-miner Cyclone V SoC
#
# BASELINE: HPS + lightweight H2F bridge (no mining core yet)
# This file will be expanded as the OdoCrypt core is integrated.

# 50 MHz base clock from board oscillator
create_clock -name clk_50 -period 20.000 [get_ports {CLOCK_50}]

# HPS clocks are derived internally; constrain the external clock only
set_input_delay  -clock clk_50 2.0 [get_ports RESET_n]
set_output_delay -clock clk_50 2.0 [all_outputs]

# Lightweight H2F bridge is synchronous to the 50 MHz clock
# (No cross-domain paths until the mining core adds additional clock domains)
