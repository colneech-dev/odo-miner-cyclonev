# pwm_fan_hw.tcl
# Platform Designer component for the fan-speed PWM generator
# (hdl/src/pwm_fan.v). Single 8-bit duty register on a standard Avalon-MM
# slave (mirrors odocrypt_top_hw.tcl's s0), plus a 1-bit conduit output
# carrying the PWM waveform out to soc_top. Register map: address 0x00 =
# DUTY[7:0].

package require -exact qsys 16.1

set_module_property DESCRIPTION "Fan-speed PWM generator (Avalon wrapper)"
set_module_property NAME pwm_fan
set_module_property VERSION 1.0
set_module_property INTERNAL false
set_module_property OPAQUE_ADDRESS_MAP true
set_module_property AUTHOR ""
set_module_property DISPLAY_NAME pwm_fan
set_module_property INSTANTIATE_IN_SYSTEM_MODULE true
set_module_property EDITABLE true
set_module_property REPORT_TO_TALKBACK false
set_module_property ALLOW_GREYBOX_GENERATION false
set_module_property REPORT_HIERARCHY false

add_fileset QUARTUS_SYNTH QUARTUS_SYNTH "" ""
set_fileset_property QUARTUS_SYNTH TOP_LEVEL pwm_fan
set_fileset_property QUARTUS_SYNTH ENABLE_RELATIVE_INCLUDE_PATHS false
set_fileset_property QUARTUS_SYNTH ENABLE_FILE_OVERWRITE_MODE false
add_fileset_file pwm_fan.v VERILOG PATH ../src/pwm_fan.v TOP_LEVEL_FILE

#
# clk: Avalon / soc_system fabric clock (~55 MHz)
#
add_interface clk clock end
set_interface_property clk clockRate 0
add_interface_port clk clk clk Input 1

#
# reset (active low, synchronous deassert)
#
add_interface reset reset end
set_interface_property reset associatedClock clk
set_interface_property reset synchronousEdges DEASSERT
add_interface_port reset reset_n reset_n Input 1

#
# s0: Avalon-MM slave (single DUTY register at address 0)
#
add_interface s0 avalon end
set_interface_property s0 addressUnits SYMBOLS
set_interface_property s0 associatedClock clk
set_interface_property s0 associatedReset reset
set_interface_property s0 bitsPerSymbol 8
set_interface_property s0 burstOnBurstBoundariesOnly false
set_interface_property s0 burstcountUnits WORDS
set_interface_property s0 explicitAddressSpan 0
set_interface_property s0 holdTime 0
set_interface_property s0 linewrapBursts false
set_interface_property s0 maximumPendingReadTransactions 0
set_interface_property s0 maximumPendingWriteTransactions 0
set_interface_property s0 readLatency 0
set_interface_property s0 readWaitTime 0
set_interface_property s0 setupTime 0
set_interface_property s0 timingUnits Cycles
set_interface_property s0 writeWaitTime 0

add_interface_port s0 avs_address     address     Input  8
add_interface_port s0 avs_read        read        Input  1
add_interface_port s0 avs_write       write       Input  1
add_interface_port s0 avs_writedata   writedata   Input  32
add_interface_port s0 avs_readdata    readdata    Output 32
add_interface_port s0 avs_waitrequest waitrequest Output 1

#
# pwm: 1-bit conduit output, the actual PWM waveform to the fan
#
add_interface pwm conduit end
add_interface_port pwm pwm_out pwm_out Output 1
