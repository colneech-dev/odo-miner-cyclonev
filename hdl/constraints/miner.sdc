# miner.sdc — Timing constraints for odo-miner Cyclone V SoC
#
# Fabric domain: LWH2F bridge, miner core, SPI/PIO peripherals.
# clk_50 (50 MHz board oscillator) drives u_pll_fab in soc_top.v.
# u_pll_fab outputs clk_fab (55 MHz, 11/10 ratio) which clocks soc_system.
# derive_pll_clocks picks up clk_fab automatically — no manual create_clock needed.

# 50 MHz base clock from board oscillator
create_clock -name clk_50 -period 20.000 [get_ports {CLOCK_50}]

derive_pll_clocks
derive_clock_uncertainty

# The pipelined miner runs in its own 150 MHz domain (u_pll_miner). The only
# crossings to the 55 MHz fabric (u_pll_fab) are the wrapper's async handshakes
# (commit toggle, found 2-phase, data-stable header/target/nonce snapshots), so
# treat the two PLL domains as asynchronous — they must not be timed as
# single-cycle paths. (Only present in the pipelined-miner build.)
set_clock_groups -asynchronous \
    -group [get_clocks {*u_pll_fab*}] \
    -group [get_clocks {*u_pll_miner*}]

# Asynchronous board inputs
set_false_path -from [get_ports {RESET_n KEY0 KEY1 TP_IRQ_n}]

# SPI display/touch and status pins: slow external interfaces with no
# meaningful timing relationship to the fabric clock.
set_false_path -to   [get_ports {LCD_* TP_SCLK TP_MOSI TP_CS_n LED[*] SDRAM_CS0_n SDRAM_CS1_n}]
set_false_path -from [get_ports {LCD_MISO TP_MISO}]
