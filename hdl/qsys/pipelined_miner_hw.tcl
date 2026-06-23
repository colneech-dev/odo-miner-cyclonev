# pipelined_miner_hw.tcl
# Platform Designer component for the PIPELINED OdoCrypt miner (Phase 1).
# Drop-in replacement for odocrypt_top on the LWH2F bridge: identical s0 Avalon
# slave (8-bit byte address, SYMBOLS, readLatency 0). Adds a second clock sink
# `miner_clk` (150 MHz) that is EXPORTED to soc_top, where the fabric PLL drives
# it. The wrapper handles the 55<->150 MHz CDC internally (see
# hdl/src/pipelined/pipelined_miner_top.v). Register map: hps/hps_regs_pipe.h.
#
# Requires VERILOG_MACRO THROUGHPUT and ODOKEY in the qsf (the per-epoch
# odo_<seed>.v defines module odo_encrypt; ODOKEY = that epoch seed).

package require -exact qsys 16.1

set_module_property DESCRIPTION "Pipelined OdoCrypt miner (Avalon wrapper)"
set_module_property NAME pipelined_miner_top
set_module_property VERSION 1.0
set_module_property INTERNAL false
set_module_property OPAQUE_ADDRESS_MAP true
set_module_property AUTHOR ""
set_module_property DISPLAY_NAME pipelined_miner_top
set_module_property INSTANTIATE_IN_SYSTEM_MODULE true
set_module_property EDITABLE true
set_module_property REPORT_TO_TALKBACK false
set_module_property ALLOW_GREYBOX_GENERATION false
set_module_property REPORT_HIERARCHY false

#
# file sets — wrapper + trimmed upstream core + upstream keccak + per-epoch RTL.
# NOTE: odo_<seed>.v is generated (gitignored); update the seed here per epoch.
#
add_fileset QUARTUS_SYNTH QUARTUS_SYNTH "" ""
set_fileset_property QUARTUS_SYNTH TOP_LEVEL pipelined_miner_top
set_fileset_property QUARTUS_SYNTH ENABLE_RELATIVE_INCLUDE_PATHS false
set_fileset_property QUARTUS_SYNTH ENABLE_FILE_OVERWRITE_MODE false
add_fileset_file pipelined_miner_top.v VERILOG PATH ../src/pipelined/pipelined_miner_top.v TOP_LEVEL_FILE
add_fileset_file odo_miner_core.v      VERILOG PATH ../src/pipelined/odo_miner_core.v
add_fileset_file keccak800.v           VERILOG PATH ../src/pipelined/keccak800.v
add_fileset_file odo_1781568000_t5.v   VERILOG PATH ../src/pipelined/odo_1781568000_t5.v

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
# miner_clk: 150 MHz pipeline clock — exported to soc_top (fabric PLL clk1)
#
add_interface miner_clk clock end
set_interface_property miner_clk clockRate 150000000
add_interface_port miner_clk miner_clk clk Input 1

#
# s0: Avalon-MM slave (identical to odocrypt_top so it reuses the bridge map)
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
# irq: Avalon interrupt sender, level, asserted while a found nonce is
# waiting to be consumed (see pipelined_miner_top.v). docs/uio-miner-io-scope.md
# WS1.
#
add_interface irq interrupt end
set_interface_property irq associatedAddressablePoint s0
add_interface_port irq irq irq Output 1
