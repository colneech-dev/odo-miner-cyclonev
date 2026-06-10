# odocrypt_top_hw.tcl
# Platform Designer component definition for the OdoCrypt miner register block.
#
# Interfaces:
#   clk     : clock sink (LWH2F bridge clock, 50 MHz)
#   reset   : reset sink, active low
#   s0      : Avalon-MM slave, BYTE (symbol) addressed, 256-byte span.
#             The RTL decodes avs_address as a byte offset (0x00, 0x04, ...)
#             exactly as listed in hps/hps_regs.h — addressUnits MUST stay
#             SYMBOLS or every register lands on the wrong offset.
#             Reads are combinational (readLatency 0); writes may stall via
#             waitrequest while the epoch-table loader unpacks a word.

package require -exact qsys 16.1

#
# module odocrypt_top
#
set_module_property DESCRIPTION "OdoCrypt miner control/status register block"
set_module_property NAME odocrypt_top
set_module_property VERSION 1.0
set_module_property INTERNAL false
set_module_property OPAQUE_ADDRESS_MAP true
set_module_property AUTHOR ""
set_module_property DISPLAY_NAME odocrypt_top
set_module_property INSTANTIATE_IN_SYSTEM_MODULE true
set_module_property EDITABLE true
set_module_property REPORT_TO_TALKBACK false
set_module_property ALLOW_GREYBOX_GENERATION false
set_module_property REPORT_HIERARCHY false

#
# file sets — top plus the full miner RTL it instantiates
#
add_fileset QUARTUS_SYNTH QUARTUS_SYNTH "" ""
set_fileset_property QUARTUS_SYNTH TOP_LEVEL odocrypt_top
set_fileset_property QUARTUS_SYNTH ENABLE_RELATIVE_INCLUDE_PATHS false
set_fileset_property QUARTUS_SYNTH ENABLE_FILE_OVERWRITE_MODE false
add_fileset_file odocrypt_top.v          VERILOG PATH ../src/odocrypt_top.v TOP_LEVEL_FILE
add_fileset_file odocrypt_core.v         VERILOG PATH ../src/odocrypt/odocrypt_core.v
add_fileset_file odocrypt_epoch_tables.v VERILOG PATH ../src/odocrypt/odocrypt_epoch_tables.v
add_fileset_file keccak800.v             VERILOG PATH ../src/keccak/keccak800.v

#
# clock
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
# s0: Avalon-MM slave
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
