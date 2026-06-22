# qsys_add_peripherals.tcl
# Incrementally extends the existing soc_system.qsys (preserving the tuned
# HPS/DDR3 configuration) with:
#   - odo_0      : OdoCrypt miner register block (odocrypt_top_hw.tcl)
#   - spi_lcd    : Avalon SPI master for the ILI9341 TFT (SCLK ~= 25 MHz)
#   - spi_touch  : Avalon SPI master for the XPT2046 touch (SCLK ~= 1.56 MHz)
#   - pio_lcd    : 3-bit output PIO (D/C, RESET_n, backlight)
#   - pio_in     : 3-bit input PIO with falling-edge IRQ (PENIRQ_n, KEY0, KEY1)
#   - pio_led    : 8-bit output PIO (board LEDs)
#   - pio_thermal: 3-bit bidirectional PIO (DS18B20 data, tach, reset btn)
#                  on J10 (FPGA-fabric header) — see docs/FAN_SENSOR_WIRING.md
#   - pwm_fan    : fan-speed PWM generator (pwm_fan_hw.tcl), ~26.9 kHz carrier,
#                  8-bit duty register; drives the J10 fan pin pio_thermal
#                  used to own (PIN_AF20) — see hdl/src/pwm_fan.v
# and connects everything to the LWH2F bridge + f2h_irq0.
#
# Run from hdl/qsys:
#   qsys-script --script=qsys_add_peripherals.tcl --search-path="<this dir>,$"
# then regenerate HDL:
#   qsys-generate soc_system.qsys --synthesis=VERILOG --output-directory=soc_system
#
# NOTE: do NOT rebuild the system from soc_system.tcl — its HPS parameter
# names predate Quartus 25.1 and silently drop the DDR3 configuration.

package require -exact qsys 25.1

load_system {soc_system.qsys}

# Enable fabric-to-HPS interrupts (f2h_irq0/f2h_irq1)
set_instance_parameter_value hps_0 {F2SINTERRUPT_Enable} {true}

# -----------------------------------------------------------------------------
# Instances
# -----------------------------------------------------------------------------
add_instance odo_0 odocrypt_top 1.0

add_instance spi_lcd altera_avalon_spi 25.1
set_instance_parameter_value spi_lcd {clockPhase}      {0}
set_instance_parameter_value spi_lcd {clockPolarity}   {0}
set_instance_parameter_value spi_lcd {dataWidth}       {8}
set_instance_parameter_value spi_lcd {masterSPI}       {true}
set_instance_parameter_value spi_lcd {numberOfSlaves}  {1}
set_instance_parameter_value spi_lcd {targetClockRate} {25000000.0}

add_instance spi_touch altera_avalon_spi 25.1
set_instance_parameter_value spi_touch {clockPhase}      {0}
set_instance_parameter_value spi_touch {clockPolarity}   {0}
set_instance_parameter_value spi_touch {dataWidth}       {8}
set_instance_parameter_value spi_touch {masterSPI}       {true}
set_instance_parameter_value spi_touch {numberOfSlaves}  {1}
set_instance_parameter_value spi_touch {targetClockRate} {2000000.0}

add_instance pio_lcd altera_avalon_pio 25.1
set_instance_parameter_value pio_lcd {direction}  {Output}
set_instance_parameter_value pio_lcd {width}      {3}
set_instance_parameter_value pio_lcd {resetValue} {0x2}

add_instance pio_in altera_avalon_pio 25.1
set_instance_parameter_value pio_in {direction}   {Input}
set_instance_parameter_value pio_in {width}       {3}
set_instance_parameter_value pio_in {edgeType}    {FALLING}
set_instance_parameter_value pio_in {captureEdge} {true}
set_instance_parameter_value pio_in {generateIRQ} {true}
set_instance_parameter_value pio_in {irqType}     {EDGE}

add_instance pio_led altera_avalon_pio 25.1
set_instance_parameter_value pio_led {direction}  {Output}
set_instance_parameter_value pio_led {width}      {8}
set_instance_parameter_value pio_led {resetValue} {0x0}

add_instance pio_thermal altera_avalon_pio 25.1
set_instance_parameter_value pio_thermal {direction}  {Bidir}
set_instance_parameter_value pio_thermal {width}      {3}
set_instance_parameter_value pio_thermal {resetValue} {0x0}

add_instance pwm_fan pwm_fan 1.0

# -----------------------------------------------------------------------------
# Clocks and resets
# -----------------------------------------------------------------------------
foreach inst {odo_0 spi_lcd spi_touch pio_lcd pio_in pio_led pio_thermal pwm_fan} {
    add_connection clk_0.clk       ${inst}.clk
    add_connection clk_0.clk_reset ${inst}.reset
}

# -----------------------------------------------------------------------------
# LWH2F bridge → peripheral address map (byte offsets from 0xFF200000).
# odo_0 MUST stay at 0x0000: hps/hps_regs.h assumes MINER_BASE_OFFSET = 0.
# -----------------------------------------------------------------------------
add_connection hps_0.h2f_lw_axi_master odo_0.s0
set_connection_parameter_value hps_0.h2f_lw_axi_master/odo_0.s0 baseAddress {0x0000}

add_connection hps_0.h2f_lw_axi_master spi_lcd.spi_control_port
set_connection_parameter_value hps_0.h2f_lw_axi_master/spi_lcd.spi_control_port baseAddress {0x1000}

add_connection hps_0.h2f_lw_axi_master spi_touch.spi_control_port
set_connection_parameter_value hps_0.h2f_lw_axi_master/spi_touch.spi_control_port baseAddress {0x1100}

add_connection hps_0.h2f_lw_axi_master pio_lcd.s1
set_connection_parameter_value hps_0.h2f_lw_axi_master/pio_lcd.s1 baseAddress {0x1200}

add_connection hps_0.h2f_lw_axi_master pio_in.s1
set_connection_parameter_value hps_0.h2f_lw_axi_master/pio_in.s1 baseAddress {0x1300}

add_connection hps_0.h2f_lw_axi_master pio_led.s1
set_connection_parameter_value hps_0.h2f_lw_axi_master/pio_led.s1 baseAddress {0x1400}

add_connection hps_0.h2f_lw_axi_master pio_thermal.s1
set_connection_parameter_value hps_0.h2f_lw_axi_master/pio_thermal.s1 baseAddress {0x1500}

add_connection hps_0.h2f_lw_axi_master pwm_fan.s0
set_connection_parameter_value hps_0.h2f_lw_axi_master/pwm_fan.s0 baseAddress {0x1600}

# -----------------------------------------------------------------------------
# Interrupts → f2h_irq0 (Linux GIC: 72 + n on Cyclone V)
# -----------------------------------------------------------------------------
add_connection hps_0.f2h_irq0 spi_lcd.irq
set_connection_parameter_value hps_0.f2h_irq0/spi_lcd.irq irqNumber {0}
add_connection hps_0.f2h_irq0 spi_touch.irq
set_connection_parameter_value hps_0.f2h_irq0/spi_touch.irq irqNumber {1}
add_connection hps_0.f2h_irq0 pio_in.irq
set_connection_parameter_value hps_0.f2h_irq0/pio_in.irq irqNumber {2}

# -----------------------------------------------------------------------------
# Exports: SPI / PIO pins out to soc_top; drop the raw AXI export now that
# the bridge is internally connected.
# -----------------------------------------------------------------------------
remove_interface h2f_lw_axi_master

add_interface          spi_lcd conduit end
set_interface_property spi_lcd EXPORT_OF spi_lcd.external
add_interface          spi_touch conduit end
set_interface_property spi_touch EXPORT_OF spi_touch.external
add_interface          pio_lcd conduit end
set_interface_property pio_lcd EXPORT_OF pio_lcd.external_connection
add_interface          pio_in conduit end
set_interface_property pio_in EXPORT_OF pio_in.external_connection
add_interface          pio_led conduit end
set_interface_property pio_led EXPORT_OF pio_led.external_connection
add_interface          pio_thermal conduit end
set_interface_property pio_thermal EXPORT_OF pio_thermal.external_connection
add_interface          pwm_fan conduit end
set_interface_property pwm_fan EXPORT_OF pwm_fan.pwm

save_system {soc_system.qsys}
