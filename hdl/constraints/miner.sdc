# ------------------------------------------------------------------------------
# CLOCK DEFINITIONS
# ------------------------------------------------------------------------------

# 50 MHz base clock from board (QMTECH 5CSXFC6C6U23 — verify pin against schematic)
create_clock -name clk_50 -period 20.000 [get_ports {CLOCK_50}]

# Internal PLL output for hash pipeline (target 150–200 MHz)
# You will connect this to your pipeline clock domain.
create_generated_clock \
    -name clk_hash \
    -source [get_pins pll_inst|clk[0]] \
    -period 6.667 \
    [get_pins pll_inst|clk[1]]

# ------------------------------------------------------------------------------
# INPUT / OUTPUT DELAYS
# ------------------------------------------------------------------------------

set_input_delay  2.0 -clock clk_50 [all_inputs]
set_output_delay 2.0 -clock clk_50 [all_outputs]

# ------------------------------------------------------------------------------
# MULTI‑CYCLE PATHS FOR PIPELINE STAGES
# ------------------------------------------------------------------------------

# Each round is one pipeline stage, so no multi‑cycle needed for the core.
# But Avalon‑MM interface is slow relative to hash clock.
set_multicycle_path -from [get_clocks clk_50] -to [get_clocks clk_hash] 2
set_multicycle_path -from [get_clocks clk_hash] -to [get_clocks clk_50] 2

# ------------------------------------------------------------------------------
# FALSE PATHS
# ------------------------------------------------------------------------------

# HPS ↔ FPGA bridges are asynchronous to hash pipeline
set_false_path -from [get_clocks clk_50] -to [get_clocks clk_hash]
set_false_path -from [get_clocks clk_hash] -to [get_clocks clk_50]

# ------------------------------------------------------------------------------
# PIPELINE REGISTER PACKING
# ------------------------------------------------------------------------------

# Encourage Quartus to pack pipeline registers tightly
set_instance_assignment -name AUTO_SHIFT_REGISTER_RECOGNITION OFF -to *
set_global_assignment -name PHYSICAL_SYNTHESIS_REGISTER_DUPLICATION ON
set_global_assignment -name PHYSICAL_SYNTHESIS_COMBO_LOGIC ON

# ------------------------------------------------------------------------------
# HASH PIPELINE OPTIMISATION
# ------------------------------------------------------------------------------

# Keep round stages separate (avoid Quartus merging logic)
set_instance_assignment -name PRESERVE_REGISTER ON -to *round_inst*

# Encourage fast carry‑chain mapping for 256‑bit compare
set_instance_assignment -name CARRY_CHAIN_LENGTH 32 -to diff_inst|*

# ------------------------------------------------------------------------------
# MULTI‑CORE ARRAY PLACEMENT
# ------------------------------------------------------------------------------

# Spread cores across device to avoid routing congestion
set_location_assignment REGION_X1_Y1_TO_X50_Y50 -to GEN_CORES[0].*
set_location_assignment REGION_X51_Y1_TO_X100_Y50 -to GEN_CORES[1].*
set_location_assignment REGION_X1_Y51_TO_X50_Y100 -to GEN_CORES[2].*
set_location_assignment REGION_X51_Y51_TO_X100_Y100 -to GEN_CORES[3].*

# ------------------------------------------------------------------------------
# END OF FILE
# ------------------------------------------------------------------------------
