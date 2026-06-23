# add_irq_to_pipelined.tcl
# Wires the found-nonce interrupt added to pipelined_miner_top.v (WS1 of
# docs/uio-miner-io-scope.md) to the next free f2h_irq0 line. Run AFTER
# pipelined_miner_hw.tcl has been updated with the new `irq` interface and
# the system has already been swapped to the pipelined miner
# (swap_to_pipelined.tcl) -- this script only adds the new connection to the
# existing odo_0 instance, it does not touch anything else.
#
# Existing f2h_irq0 lines (qsys_add_peripherals.tcl): 0=spi_lcd, 1=spi_touch,
# 2=pio_in. This takes line 3.
#
# Run from hdl/qsys:
#   qsys-script --script=add_irq_to_pipelined.tcl --search-path="<this dir>,$"
#   qsys-generate soc_system.qsys --synthesis=VERILOG --output-directory=soc_system

package require -exact qsys 25.1

load_system {soc_system.qsys}

add_connection hps_0.f2h_irq0 odo_0.irq
set_connection_parameter_value hps_0.f2h_irq0/odo_0.irq irqNumber {3}

save_system {soc_system.qsys}
