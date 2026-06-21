# add_pwm_fan.tcl
# Incrementally adds pwm_fan (custom Avalon-MM PWM generator, pwm_fan_hw.tcl)
# to the existing soc_system, and shrinks pio_thermal from 4-bit to 3-bit
# (drops the on/off fan bit — fan speed is now driven by pwm_fan instead).
# See hdl/src/pwm_fan.v and docs/FAN_SENSOR_WIRING.md.
#
# Run from hdl/qsys:
#   qsys-script --script=add_pwm_fan.tcl --search-path="<this dir>,$"
#   qsys-generate soc_system.qsys --synthesis=VERILOG --output-directory=soc_system
#
# Revert with: git checkout hdl/qsys/soc_system.qsys
#
# qsys_add_peripherals.tcl has also been updated to describe pwm_fan for
# documentation purposes, but is NOT re-run here (it would try to re-add
# odo_0/spi_lcd/pio_lcd/etc., which already exist in soc_system.qsys).

package require -exact qsys 25.1

load_system {soc_system.qsys}

# pio_thermal no longer owns the fan bit — pwm_fan drives that pin instead.
set_instance_parameter_value pio_thermal {width} {3}

add_instance pwm_fan pwm_fan 1.0

add_connection clk_0.clk       pwm_fan.clk
add_connection clk_0.clk_reset pwm_fan.reset

add_connection hps_0.h2f_lw_axi_master pwm_fan.s0
set_connection_parameter_value hps_0.h2f_lw_axi_master/pwm_fan.s0 baseAddress {0x1600}

add_interface          pwm_fan conduit end
set_interface_property pwm_fan EXPORT_OF pwm_fan.pwm

save_system {soc_system.qsys}
