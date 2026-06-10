# miner.sdc — Timing constraints for odo-miner Cyclone V SoC
#
# Single 50 MHz fabric domain: LWH2F bridge, miner core, SPI/PIO peripherals.

# 50 MHz base clock from board oscillator
create_clock -name clk_50 -period 20.000 [get_ports {CLOCK_50}]

derive_pll_clocks
derive_clock_uncertainty

# Asynchronous board inputs
set_false_path -from [get_ports {RESET_n KEY0 KEY1 TP_IRQ_n}]

# SPI display/touch and status pins: slow external interfaces with no
# meaningful timing relationship to the fabric clock.
set_false_path -to   [get_ports {LCD_* TP_SCLK TP_MOSI TP_CS_n LED[*] SDRAM_CS0_n SDRAM_CS1_n}]
set_false_path -from [get_ports {LCD_MISO TP_MISO}]
