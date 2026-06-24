// soc_top.v — Top-level FPGA module for QMTECH Cyclone V SoC KFB (dual SDRAM)
//
// Instantiates the Platform Designer system (soc_system) which contains:
//   - HPS with 32-bit single-rank DDR3 (2x MT41K256M16, 1 GB total)
//   - Lightweight H2F bridge -> odocrypt_top miner @ 0xFF200000
//   - SPI masters for ILI9341 TFT (25 MHz) and XPT2046 touch (1.56 MHz)
//   - PIOs for LCD control, touch IRQ / keys, board LEDs
//   - Full HPS peripherals (Ethernet, USB, SD, UART, I2C, SPI, GPIO)
//
// Display wiring uses the GPIO_0 header (DE10-Nano-compatible ball-out,
// verified against the QMTECH KFB schematic). The header shares pins with
// the onboard MiSTer-style SDRAM chips; both SDRAM chip selects are driven
// high here so the chips stay quiet while the header is used as GPIO.

// ---- 50 → 55 MHz fabric PLL ---------------------------------------------------
// Ratio 11/10 → 55 MHz. The dual-core engine with shared epoch FF tables
// (odocrypt_sbox_bank split) fits at 70% ALM; netlist Fmax ≈ 55.9 MHz, so
// 55 MHz leaves ~+0.3 ns setup margin at the Slow/100C signoff corner.
// 56.25 MHz failed that corner by -0.111 ns; 75 MHz is infeasible on this
// device — the pbox barrel-rotator critical path is ~17.9 ns vs 13.33 ns @75.
// derive_pll_clocks in miner.sdc picks up this output automatically.
// fabric_reset_n is held low until both POR and PLL lock are asserted.

module soc_top (
    // ---- Board clock & reset ----
    input  wire        CLOCK_50,   // 50 MHz oscillator
    input  wire        RESET_n,    // Active-low board reset

    // ---- SPI TFT display (ILI9341-class, GPIO_0 header) ----
    output wire        LCD_SCLK,
    output wire        LCD_MOSI,
    input  wire        LCD_MISO,
    output wire        LCD_CS_n,
    output wire        LCD_DC,     // data/command
    output wire        LCD_RST_n,
    output wire        LCD_BL,     // backlight enable

    // ---- SPI touch controller (XPT2046, GPIO_0 header) ----
    output wire        TP_SCLK,
    output wire        TP_MOSI,
    input  wire        TP_MISO,
    output wire        TP_CS_n,
    input  wire        TP_IRQ_n,   // pen interrupt, active low

    // ---- User buttons & LEDs ----
    input  wire        KEY0,
    input  wire        KEY1,
    output wire [7:0]  LED,

    // ---- Onboard fabric SDRAM (shares GPIO_0 pins) — held disabled ----
    output wire        SDRAM_CS0_n,
    output wire        SDRAM_CS1_n,

    // ---- HPS DDR3 SDRAM (auto-assigned by HPS hard memory controller) ----
    output wire [14:0] HPS_DDR3_ADDR,
    output wire [2:0]  HPS_DDR3_BA,
    output wire        HPS_DDR3_CAS_n,
    output wire [1:0]  HPS_DDR3_CKE,
    output wire        HPS_DDR3_CK_n,
    output wire        HPS_DDR3_CK_p,
    output wire [1:0]  HPS_DDR3_CS_n,
    output wire [3:0]  HPS_DDR3_DM,
    inout  wire [31:0] HPS_DDR3_DQ,
    inout  wire [3:0]  HPS_DDR3_DQS_n,
    inout  wire [3:0]  HPS_DDR3_DQS_p,
    output wire [1:0]  HPS_DDR3_ODT,
    output wire        HPS_DDR3_RAS_n,
    output wire        HPS_DDR3_RESET_n,
    output wire        HPS_DDR3_WE_n,
    input  wire        HPS_DDR3_RZQ,

    // ---- HPS Ethernet (EMAC1, RGMII) ----
    output wire        HPS_ENET_GTX_CLK,
    output wire        HPS_ENET_TX_EN,
    output wire [3:0]  HPS_ENET_TXD,
    input  wire        HPS_ENET_RX_CLK,
    input  wire        HPS_ENET_RX_DV,
    input  wire [3:0]  HPS_ENET_RXD,
    inout  wire        HPS_ENET_MDIO,
    output wire        HPS_ENET_MDC,

    // ---- HPS USB (USB1, ULPI) ----
    input  wire        HPS_USB_CLKOUT,
    inout  wire [7:0]  HPS_USB_DATA,
    input  wire        HPS_USB_DIR,
    input  wire        HPS_USB_NXT,
    output wire        HPS_USB_STP,

    // ---- HPS SD/MMC (8-bit) ----
    output wire        HPS_SD_CLK,
    inout  wire        HPS_SD_CMD,
    inout  wire [7:0]  HPS_SD_DATA,

    // ---- HPS UART0 ----
    input  wire        HPS_UART_RX,
    output wire        HPS_UART_TX,

    // ---- HPS I2C0 / I2C1 ----
    inout  wire        HPS_I2C0_SDAT,
    inout  wire        HPS_I2C0_SCLK,
    inout  wire        HPS_I2C1_SDAT,
    inout  wire        HPS_I2C1_SCLK,

    // ---- HPS SPI master 0 ----
    output wire        HPS_SPIM_CLK,
    output wire        HPS_SPIM_MOSI,
    input  wire        HPS_SPIM_MISO,
    output wire        HPS_SPIM_SS,

    // ---- Fan/thermal header (J10 "GPIO_1", FPGA fabric, pins 35/37/38) ----
    // bit0=DS18B20 data (one-wire, bidirectional), bit1=tach, bit2=reset
    // button. See docs/FAN_SENSOR_WIRING.md.
    inout  wire [2:0]  THERMAL_IO,

    // ---- Fan PWM speed control (J10 pin 36, FPGA fabric) ----
    // Driven by the pwm_fan peripheral; same physical net pio_thermal's
    // bit1 used to own when fan control was on/off-only.
    output wire        FAN_PWM
);

    // ---- Keep the onboard fabric SDRAM deselected (GPIO_0 used as GPIO) ----
    assign SDRAM_CS0_n = 1'b1;
    assign SDRAM_CS1_n = 1'b1;

    // ---- PLL: 50 MHz → 55 MHz fabric clock --------------------------------
    wire        clk_fab;
    wire        pll_locked;
    wire [5:0]  pll_clk_bus;
    assign clk_fab = pll_clk_bus[0];

    altpll u_pll_fab (
        .inclk ({1'b0, CLOCK_50}),
        .clk   (pll_clk_bus),
        .locked(pll_locked)
    );
    defparam u_pll_fab.intended_device_family  = "Cyclone V";
    defparam u_pll_fab.lpm_type                = "altpll";
    defparam u_pll_fab.operation_mode          = "NORMAL";
    defparam u_pll_fab.compensate_clock        = "CLK0";
    defparam u_pll_fab.inclk0_input_frequency  = 20000;   // 50 MHz = 20 000 ps
    defparam u_pll_fab.clk0_multiply_by        = 11;      // 50 × 11/10 = 55 MHz
    defparam u_pll_fab.clk0_divide_by          = 10;
    defparam u_pll_fab.clk0_duty_cycle         = 50;
    defparam u_pll_fab.clk0_phase_shift        = "0";
    defparam u_pll_fab.port_inclk1             = "PORT_UNUSED";
    defparam u_pll_fab.port_clk0               = "PORT_USED";
    defparam u_pll_fab.port_clk1               = "PORT_UNUSED";
    defparam u_pll_fab.port_clk2               = "PORT_UNUSED";
    defparam u_pll_fab.port_clk3               = "PORT_UNUSED";
    defparam u_pll_fab.port_clk4               = "PORT_UNUSED";
    defparam u_pll_fab.port_clk5               = "PORT_UNUSED";
    defparam u_pll_fab.port_locked             = "PORT_USED";
    defparam u_pll_fab.width_clock             = 6;

    // ---- PLL: 50 MHz → 150 MHz pipelined-miner clock -----------------------
    // Dedicated PLL for the pipelined OdoCrypt core. DEPLOYED CONFIG:
    // THROUGHPUT=7 @ 150 MHz ≈ 21.4 MH/s raw (see odo_miner.qsf VERILOG_MACRO).
    // The clock-exploration narrative below predates the T=7 deployment and is
    // written against the older T=8 build — kept for the power-regime context,
    // but the live number is T=7/150 MHz/21.4 MH/s.
    // Separate from u_pll_fab so the 150 MHz and 55 MHz domains don't share a
    // VCO solution. Exported into soc_system as miner_clk_clk; the wrapper's CDC
    // bridges 55<->150 MHz.
    // NOTE: an EARLIER 150 MHz brownout was at THROUGHPUT=4 (~2x this design's
    // active logic) — a different power regime. T=8 has now soaked stable on
    // hardware at 100/125/137.5 MHz with margin to spare (Fmax 158.58 MHz @
    // Slow/100C at the 137.5 build); 150 MHz is the next data point, not a
    // repeat of the old failure.
    // POWER NOTE: the brownouts were all at THROUGHPUT=4 (150 and 125 MHz) —
    // T=4 unrolls ~2x the pipeline logic, so those drew ~2.5-3x the T=8 @ 100
    // dynamic power and browned the core rail. KEEPING T=8 (35% ALM) and only
    // raising the clock is a much smaller step: 125 MHz ≈ 1.25x the T=8 @ 100
    // power. Pipeline Fmax is 143.97 MHz @ Slow/100C, so 125 MHz has margin.
    // If this is stable under sustained load, 137.5 MHz (×11/4) is the next step.
    wire        clk_miner;
    wire        miner_pll_locked;
    wire [5:0]  miner_clk_bus;
    assign clk_miner = miner_clk_bus[0];

    altpll u_pll_miner (
        .inclk ({1'b0, CLOCK_50}),
        .clk   (miner_clk_bus),
        .locked(miner_pll_locked)
    );
    defparam u_pll_miner.intended_device_family = "Cyclone V";
    defparam u_pll_miner.lpm_type               = "altpll";
    defparam u_pll_miner.operation_mode         = "NORMAL";
    defparam u_pll_miner.compensate_clock       = "CLK0";
    defparam u_pll_miner.inclk0_input_frequency  = 20000;  // 50 MHz = 20 000 ps
    defparam u_pll_miner.clk0_multiply_by        = 25;     // 50 × 25/8 = 156.25 MHz
    defparam u_pll_miner.clk0_divide_by          = 8;      // +4% over 150 -> ~26 MH/s @ T=6 (Fmax/power-edge experiment)
    defparam u_pll_miner.clk0_duty_cycle         = 50;
    defparam u_pll_miner.clk0_phase_shift        = "0";
    defparam u_pll_miner.port_inclk1             = "PORT_UNUSED";
    defparam u_pll_miner.port_clk0               = "PORT_USED";
    defparam u_pll_miner.port_clk1               = "PORT_UNUSED";
    defparam u_pll_miner.port_clk2               = "PORT_UNUSED";
    defparam u_pll_miner.port_clk3               = "PORT_UNUSED";
    defparam u_pll_miner.port_clk4               = "PORT_UNUSED";
    defparam u_pll_miner.port_clk5               = "PORT_UNUSED";
    defparam u_pll_miner.port_locked             = "PORT_USED";
    defparam u_pll_miner.width_clock             = 6;

    // ---- Fabric power-on reset --------------------------------------------
    // The external RESET_n pin (AE25) is a DE10-Nano-convention guess that is
    // NOT verified against the QMTECH silkscreen. On first silicon the fabric
    // was frozen (every LWH2F register access hung) — consistent with that
    // input floating low and holding soc_system in reset forever, even though
    // the FPGA configured (MODE=user) and the bridges were enabled.
    //
    // Remove the dependence on that pin ENTIRELY: generate reset internally
    // from the 50 MHz clock. Hold reset asserted for 256 cycles (~5 us) after
    // config, then release. RESET_n (AE25) is deliberately NOT used — if it
    // floats low it would re-wedge the fabric, which is exactly the failure
    // we are fixing. (Re-introduce a real button reset only once AE25 is
    // confirmed against the silkscreen.)
    reg [7:0] por_cnt = 8'd0;
    reg       por_rst_n = 1'b0;
    always @(posedge CLOCK_50) begin
        if (por_cnt != 8'hFF) begin
            por_cnt   <= por_cnt + 8'd1;
            por_rst_n <= 1'b0;
        end else begin
            por_rst_n <= 1'b1;
        end
    end
    // Hold fabric in reset until both the POR timer and PLL lock are satisfied.
    wire fabric_reset_n = por_rst_n & pll_locked;

    // ---- LCD control PIO bit mapping (bit0=D/C, bit1=RESET_n, bit2=BL) ----
    wire [2:0] pio_lcd_export;
    assign LCD_DC    = pio_lcd_export[0];
    assign LCD_RST_n = pio_lcd_export[1];
    assign LCD_BL    = pio_lcd_export[2];

    // ---- Platform Designer system (HPS + DDR3 + miner + display SPI) ----
    soc_system u_soc (
        // Clock & reset — fabric runs at 55 MHz from u_pll_fab
        .clk_clk                               (clk_fab),
        .reset_reset_n                         (fabric_reset_n),

        // 150 MHz pipelined-miner clock (exported by the pipelined component)
        .miner_clk_clk                         (clk_miner),

        // SPI display
        .spi_lcd_SCLK                          (LCD_SCLK),
        .spi_lcd_MOSI                          (LCD_MOSI),
        .spi_lcd_MISO                          (LCD_MISO),
        .spi_lcd_SS_n                          (LCD_CS_n),

        // SPI touch
        .spi_touch_SCLK                        (TP_SCLK),
        .spi_touch_MOSI                        (TP_MOSI),
        .spi_touch_MISO                        (TP_MISO),
        .spi_touch_SS_n                        (TP_CS_n),

        // PIOs
        .pio_lcd_export                        (pio_lcd_export),
        .pio_in_export                         ({KEY1, KEY0, TP_IRQ_n}),
        .pio_led_export                        (LED),
        .pio_thermal_export                    (THERMAL_IO),
        .pwm_fan_pwm_out                       (FAN_PWM),

        // HPS DDR3 (memory conduit — auto-assigned by HPS)
        .memory_mem_a                          (HPS_DDR3_ADDR),
        .memory_mem_ba                         (HPS_DDR3_BA),
        .memory_mem_ck                         (HPS_DDR3_CK_p),
        .memory_mem_ck_n                       (HPS_DDR3_CK_n),
        .memory_mem_cke                        (HPS_DDR3_CKE),
        .memory_mem_cs_n                       (HPS_DDR3_CS_n),
        .memory_mem_ras_n                      (HPS_DDR3_RAS_n),
        .memory_mem_cas_n                      (HPS_DDR3_CAS_n),
        .memory_mem_we_n                       (HPS_DDR3_WE_n),
        .memory_mem_reset_n                    (HPS_DDR3_RESET_n),
        .memory_mem_dq                         (HPS_DDR3_DQ),
        .memory_mem_dqs                        (HPS_DDR3_DQS_p),
        .memory_mem_dqs_n                      (HPS_DDR3_DQS_n),
        .memory_mem_odt                        (HPS_DDR3_ODT),
        .memory_mem_dm                         (HPS_DDR3_DM),
        .memory_oct_rzqin                      (HPS_DDR3_RZQ),

        // HPS peripheral I/O (hps_io conduit — auto-assigned by HPS)
        .hps_io_hps_io_emac1_inst_TX_CLK       (HPS_ENET_GTX_CLK),
        .hps_io_hps_io_emac1_inst_TX_CTL       (HPS_ENET_TX_EN),
        .hps_io_hps_io_emac1_inst_TXD0         (HPS_ENET_TXD[0]),
        .hps_io_hps_io_emac1_inst_TXD1         (HPS_ENET_TXD[1]),
        .hps_io_hps_io_emac1_inst_TXD2         (HPS_ENET_TXD[2]),
        .hps_io_hps_io_emac1_inst_TXD3         (HPS_ENET_TXD[3]),
        .hps_io_hps_io_emac1_inst_RX_CLK       (HPS_ENET_RX_CLK),
        .hps_io_hps_io_emac1_inst_RX_CTL       (HPS_ENET_RX_DV),
        .hps_io_hps_io_emac1_inst_RXD0         (HPS_ENET_RXD[0]),
        .hps_io_hps_io_emac1_inst_RXD1         (HPS_ENET_RXD[1]),
        .hps_io_hps_io_emac1_inst_RXD2         (HPS_ENET_RXD[2]),
        .hps_io_hps_io_emac1_inst_RXD3         (HPS_ENET_RXD[3]),
        .hps_io_hps_io_emac1_inst_MDIO         (HPS_ENET_MDIO),
        .hps_io_hps_io_emac1_inst_MDC          (HPS_ENET_MDC),

        .hps_io_hps_io_usb1_inst_CLK           (HPS_USB_CLKOUT),
        .hps_io_hps_io_usb1_inst_STP           (HPS_USB_STP),
        .hps_io_hps_io_usb1_inst_DIR           (HPS_USB_DIR),
        .hps_io_hps_io_usb1_inst_NXT           (HPS_USB_NXT),
        .hps_io_hps_io_usb1_inst_D0            (HPS_USB_DATA[0]),
        .hps_io_hps_io_usb1_inst_D1            (HPS_USB_DATA[1]),
        .hps_io_hps_io_usb1_inst_D2            (HPS_USB_DATA[2]),
        .hps_io_hps_io_usb1_inst_D3            (HPS_USB_DATA[3]),
        .hps_io_hps_io_usb1_inst_D4            (HPS_USB_DATA[4]),
        .hps_io_hps_io_usb1_inst_D5            (HPS_USB_DATA[5]),
        .hps_io_hps_io_usb1_inst_D6            (HPS_USB_DATA[6]),
        .hps_io_hps_io_usb1_inst_D7            (HPS_USB_DATA[7]),

        .hps_io_hps_io_sdio_inst_CLK           (HPS_SD_CLK),
        .hps_io_hps_io_sdio_inst_CMD           (HPS_SD_CMD),
        .hps_io_hps_io_sdio_inst_D0            (HPS_SD_DATA[0]),
        .hps_io_hps_io_sdio_inst_D1            (HPS_SD_DATA[1]),
        .hps_io_hps_io_sdio_inst_D2            (HPS_SD_DATA[2]),
        .hps_io_hps_io_sdio_inst_D3            (HPS_SD_DATA[3]),
        .hps_io_hps_io_sdio_inst_D4            (HPS_SD_DATA[4]),
        .hps_io_hps_io_sdio_inst_D5            (HPS_SD_DATA[5]),
        .hps_io_hps_io_sdio_inst_D6            (HPS_SD_DATA[6]),
        .hps_io_hps_io_sdio_inst_D7            (HPS_SD_DATA[7]),

        .hps_io_hps_io_uart0_inst_RX           (HPS_UART_RX),
        .hps_io_hps_io_uart0_inst_TX           (HPS_UART_TX),

        .hps_io_hps_io_i2c0_inst_SDA           (HPS_I2C0_SDAT),
        .hps_io_hps_io_i2c0_inst_SCL           (HPS_I2C0_SCLK),
        .hps_io_hps_io_i2c1_inst_SDA           (HPS_I2C1_SDAT),
        .hps_io_hps_io_i2c1_inst_SCL           (HPS_I2C1_SCLK),

        .hps_io_hps_io_spim0_inst_CLK          (HPS_SPIM_CLK),
        .hps_io_hps_io_spim0_inst_MOSI         (HPS_SPIM_MOSI),
        .hps_io_hps_io_spim0_inst_MISO         (HPS_SPIM_MISO),
        .hps_io_hps_io_spim0_inst_SS0          (HPS_SPIM_SS)
    );

endmodule
