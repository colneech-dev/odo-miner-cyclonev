# swap_to_pipelined.tcl
# Replace the sequential-FSM miner (odocrypt_top) with the pipelined wrapper
# (pipelined_miner_top) in the existing soc_system, preserving the tuned
# HPS/DDR3 config and all peripherals. The wrapper's s0 is identical to
# odocrypt_top's, so it reuses the LWH2F bridge map at 0x0000. The new 150 MHz
# `miner_clk` clock sink is exported to soc_top (driven by a fabric PLL there).
#
# Run from hdl/qsys:
#   qsys-script --script=swap_to_pipelined.tcl --search-path="<this dir>,$"
#   qsys-generate soc_system.qsys --synthesis=VERILOG --output-directory=soc_system
#
# Revert with: git checkout hdl/qsys/soc_system.qsys

package require -exact qsys 25.1

load_system {soc_system.qsys}

# Swap the miner instance (keeps name odo_0 so the bridge map stays at 0x0).
remove_instance odo_0
add_instance odo_0 pipelined_miner_top 1.0

# Clock + reset (same fabric clock as before).
add_connection clk_0.clk        odo_0.clk
add_connection clk_0.clk_reset  odo_0.reset

# LWH2F bridge -> s0 at byte offset 0x0 (hps_regs_pipe.h assumes base 0).
add_connection hps_0.h2f_lw_axi_master odo_0.s0
set_connection_parameter_value hps_0.h2f_lw_axi_master/odo_0.s0 baseAddress {0x0000}

# Export the 150 MHz miner clock to soc_top (fabric PLL drives it).
add_interface          miner_clk clock end
set_interface_property miner_clk EXPORT_OF odo_0.miner_clk

save_system {soc_system.qsys}
