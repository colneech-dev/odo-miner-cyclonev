# add_pio_thermal.tcl
# Incrementally adds pio_thermal (4-bit bidirectional PIO for the J10
# fan/thermal header) to the existing soc_system, preserving everything
# already in it (HPS/DDR3, miner, display SPI, pio_lcd/pio_in/pio_led).
# Replaces the abandoned J12/HPS-pin approach — see
# docs/FAN_SENSOR_WIRING.md and reference_board_connector_identity in
# project memory for why.
#
# Run from hdl/qsys:
#   qsys-script --script=add_pio_thermal.tcl --search-path="<this dir>,$"
#   qsys-generate soc_system.qsys --synthesis=VERILOG --output-directory=soc_system
#
# Revert with: git checkout hdl/qsys/soc_system.qsys
#
# qsys_add_peripherals.tcl has also been updated to describe pio_thermal
# for documentation purposes, but is NOT re-run here (it would try to
# re-add odo_0/spi_lcd/pio_lcd/etc., which already exist in soc_system.qsys
# from when it was originally applied).

package require -exact qsys 25.1

load_system {soc_system.qsys}

add_instance pio_thermal altera_avalon_pio 25.1
set_instance_parameter_value pio_thermal {direction}  {Bidir}
set_instance_parameter_value pio_thermal {width}      {4}
set_instance_parameter_value pio_thermal {resetValue} {0x0}

add_connection clk_0.clk       pio_thermal.clk
add_connection clk_0.clk_reset pio_thermal.reset

add_connection hps_0.h2f_lw_axi_master pio_thermal.s1
set_connection_parameter_value hps_0.h2f_lw_axi_master/pio_thermal.s1 baseAddress {0x1500}

add_interface          pio_thermal conduit end
set_interface_property pio_thermal EXPORT_OF pio_thermal.external_connection

save_system {soc_system.qsys}
