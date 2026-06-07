// soc_top.v — Top-level FPGA module for QMTECH Cyclone V SoC
//
// Instantiates the Platform Designer system (soc_system) which contains:
//   - HPS with 32-bit single-rank DDR3 (2x MT41K256M16, 1 GB total)
//   - Lightweight H2F bridge (for future OdoCrypt miner integration)
//   - Full HPS peripherals (Ethernet, USB, SD, UART, I2C, SPI, GPIO)
//
// Board I/O: DDR3 pins are managed entirely by HPS hard memory controller.
// HPS peripherals route through dedicated HPS I/O banks (not FPGA fabric pins).

module soc_top (
    // ---- Board clock & reset ----
    input  wire        CLOCK_50,   // 50 MHz oscillator
    input  wire        RESET_n,    // Active-low board reset

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
    output wire        HPS_SPIM_SS
);

    // ---- Platform Designer system (HPS + DDR3 + LW H2F bridge) ----
    soc_system u_soc (
        // Clock & reset
        .clk_clk                               (CLOCK_50),
        .reset_reset_n                         (RESET_n),

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
