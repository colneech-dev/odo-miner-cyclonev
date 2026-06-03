// soc_top.v — Top-level FPGA module for the QMTECH Cyclone V SoC (5CSXFC6C6U23)
//
// This module sits at the top of the Quartus hierarchy. It:
//   1. Instantiates the Platform Designer system (soc_system) — which contains
//      the HPS, DDR3 controller, EMAC, and the LWH2F Avalon-MM bridge.
//   2. Instantiates odocrypt_top as the LWH2F slave.
//   3. Wires board-level I/O (clocks, DDR3, Ethernet) to the Qsys system.
//
// The LWH2F bridge output from soc_system connects directly to odocrypt_top's
// Avalon-MM slave ports. The slave's base address within the bridge window is
// set to 0x0 in Platform Designer, so the miner registers appear at 0xFF200000.
//
// NOTE: The soc_system instantiation is commented out until Platform Designer
// has been run and soc_system.v has been generated. Until then, the module
// compiles stand-alone for linting / analysis.
//
// Pin assignments: verify ALL assignments against the QMTECH GHRD and board
// schematic before synthesis. The .qsf has placeholder assignments that must
// be confirmed.

module soc_top (
    // -- Board clock & reset --------------------------------------------------
    input  wire        CLOCK_50,   // 50 MHz oscillator
    input  wire        RESET_n,    // Active-low board reset

    // -- HPS DDR3 SDRAM -------------------------------------------------------
    // Managed by the HPS hard memory controller; pins assigned by Platform
    // Designer from the QMTECH GHRD handoff. Declare here for port completeness.
    output wire [14:0] HPS_DDR3_ADDR,
    output wire [2:0]  HPS_DDR3_BA,
    output wire        HPS_DDR3_CAS_n,
    output wire        HPS_DDR3_CKE,
    output wire        HPS_DDR3_CK_n,
    output wire        HPS_DDR3_CK_p,
    output wire        HPS_DDR3_CS_n,
    output wire [3:0]  HPS_DDR3_DM,
    inout  wire [31:0] HPS_DDR3_DQ,
    inout  wire [3:0]  HPS_DDR3_DQS_n,
    inout  wire [3:0]  HPS_DDR3_DQS_p,
    output wire        HPS_DDR3_ODT,
    output wire        HPS_DDR3_RAS_n,
    output wire        HPS_DDR3_RESET_n,
    output wire        HPS_DDR3_WE_n,
    input  wire        HPS_DDR3_RZQ,

    // -- HPS Ethernet (RGMII, connected to EMAC1) -----------------------------
    output wire        HPS_ENET_GTX_CLK,
    inout  wire        HPS_ENET_INT_n,
    output wire        HPS_ENET_MDC,
    inout  wire        HPS_ENET_MDIO,
    input  wire        HPS_ENET_RX_CLK,
    input  wire [3:0]  HPS_ENET_RX_DATA,
    input  wire        HPS_ENET_RX_DV,
    output wire [3:0]  HPS_ENET_TX_DATA,
    output wire        HPS_ENET_TX_EN,

    // -- HPS SD card ----------------------------------------------------------
    output wire        HPS_SD_CLK,
    inout  wire        HPS_SD_CMD,
    inout  wire [3:0]  HPS_SD_DATA,

    // -- HPS UART (USB-serial) ------------------------------------------------
    input  wire        HPS_UART_RX,
    output wire        HPS_UART_TX,

    // -- HPS USB OTG ----------------------------------------------------------
    input  wire        HPS_USB_CLKOUT,
    inout  wire [7:0]  HPS_USB_DATA,
    input  wire        HPS_USB_DIR,
    input  wire        HPS_USB_NXT,
    output wire        HPS_USB_STP
);

    // -------------------------------------------------------------------------
    // LWH2F bridge signals (driven by soc_system, consumed by odocrypt_top)
    // -------------------------------------------------------------------------
    wire        lw_clk;          // bridge clock (same as CLOCK_50 from HPS)
    wire        lw_reset_n;      // bridge reset (from HPS)
    wire [7:0]  lw_address;      // byte-addressed within the slave's span
    wire        lw_read;
    wire        lw_write;
    wire [31:0] lw_writedata;
    wire [31:0] lw_readdata;
    wire        lw_waitrequest;

    // -------------------------------------------------------------------------
    // AXI Lite bridge signals (from soc_system h2f_lw_axi_master)
    // -------------------------------------------------------------------------
    wire [31:0] axi_lw_awaddr;
    wire        axi_lw_awvalid;
    wire        axi_lw_awready;
    wire [31:0] axi_lw_wdata;
    wire [3:0]  axi_lw_wstrb;
    wire        axi_lw_wvalid;
    wire        axi_lw_wready;
    wire [1:0]  axi_lw_bresp;
    wire        axi_lw_bvalid;
    wire        axi_lw_bready;
    wire [31:0] axi_lw_araddr;
    wire        axi_lw_arvalid;
    wire        axi_lw_arready;
    wire [31:0] axi_lw_rdata;
    wire [1:0]  axi_lw_rresp;
    wire        axi_lw_rvalid;
    wire        axi_lw_rready;

    // -------------------------------------------------------------------------
    // soc_system — Platform Designer generated wrapper
    //
    // Instantiates HPS, DDR3, Ethernet, SD, UART, USB, and the LWH2F AXI bridge.
    // -------------------------------------------------------------------------
    soc_system u_soc (
        // Clocks & resets
        .clk_clk                        (CLOCK_50),
        .reset_reset_n                  (RESET_n),

        // DDR3
        .memory_mem_a                   (HPS_DDR3_ADDR),
        .memory_mem_ba                  (HPS_DDR3_BA),
        .memory_mem_ck                  (HPS_DDR3_CK_p),
        .memory_mem_ck_n                (HPS_DDR3_CK_n),
        .memory_mem_cke                 (HPS_DDR3_CKE),
        .memory_mem_cs_n                (HPS_DDR3_CS_n),
        .memory_mem_ras_n               (HPS_DDR3_RAS_n),
        .memory_mem_cas_n               (HPS_DDR3_CAS_n),
        .memory_mem_we_n                (HPS_DDR3_WE_n),
        .memory_mem_reset_n             (HPS_DDR3_RESET_n),
        .memory_mem_dq                  (HPS_DDR3_DQ),
        .memory_mem_dqs                 (HPS_DDR3_DQS_p),
        .memory_mem_dqs_n               (HPS_DDR3_DQS_n),
        .memory_mem_odt                 (HPS_DDR3_ODT),
        .memory_mem_dm                  (HPS_DDR3_DM),
        .memory_oct_rzqin               (HPS_DDR3_RZQ),

        // Ethernet (EMAC1 → RGMII)
        .hps_io_hps_io_emac1_inst_TX_CLK (HPS_ENET_GTX_CLK),
        .hps_io_hps_io_emac1_inst_TXD0   (HPS_ENET_TX_DATA[0]),
        .hps_io_hps_io_emac1_inst_TXD1   (HPS_ENET_TX_DATA[1]),
        .hps_io_hps_io_emac1_inst_TXD2   (HPS_ENET_TX_DATA[2]),
        .hps_io_hps_io_emac1_inst_TXD3   (HPS_ENET_TX_DATA[3]),
        .hps_io_hps_io_emac1_inst_TX_CTL (HPS_ENET_TX_EN),
        .hps_io_hps_io_emac1_inst_RX_CLK (HPS_ENET_RX_CLK),
        .hps_io_hps_io_emac1_inst_RXD0   (HPS_ENET_RX_DATA[0]),
        .hps_io_hps_io_emac1_inst_RXD1   (HPS_ENET_RX_DATA[1]),
        .hps_io_hps_io_emac1_inst_RXD2   (HPS_ENET_RX_DATA[2]),
        .hps_io_hps_io_emac1_inst_RXD3   (HPS_ENET_RX_DATA[3]),
        .hps_io_hps_io_emac1_inst_RX_CTL (HPS_ENET_RX_DV),
        .hps_io_hps_io_emac1_inst_MDC    (HPS_ENET_MDC),
        .hps_io_hps_io_emac1_inst_MDIO   (HPS_ENET_MDIO),
        .hps_io_hps_io_emac1_inst_RX_ER  (),

        // SD card
        .hps_io_hps_io_sdio_inst_CLK  (HPS_SD_CLK),
        .hps_io_hps_io_sdio_inst_CMD  (HPS_SD_CMD),
        .hps_io_hps_io_sdio_inst_D0   (HPS_SD_DATA[0]),
        .hps_io_hps_io_sdio_inst_D1   (HPS_SD_DATA[1]),
        .hps_io_hps_io_sdio_inst_D2   (HPS_SD_DATA[2]),
        .hps_io_hps_io_sdio_inst_D3   (HPS_SD_DATA[3]),

        // UART
        .hps_io_hps_io_uart0_inst_RX  (HPS_UART_RX),
        .hps_io_hps_io_uart0_inst_TX  (HPS_UART_TX),

        // USB OTG
        .hps_io_hps_io_usb1_inst_CLK  (HPS_USB_CLKOUT),
        .hps_io_hps_io_usb1_inst_D0   (HPS_USB_DATA[0]),
        .hps_io_hps_io_usb1_inst_D1   (HPS_USB_DATA[1]),
        .hps_io_hps_io_usb1_inst_D2   (HPS_USB_DATA[2]),
        .hps_io_hps_io_usb1_inst_D3   (HPS_USB_DATA[3]),
        .hps_io_hps_io_usb1_inst_D4   (HPS_USB_DATA[4]),
        .hps_io_hps_io_usb1_inst_D5   (HPS_USB_DATA[5]),
        .hps_io_hps_io_usb1_inst_D6   (HPS_USB_DATA[6]),
        .hps_io_hps_io_usb1_inst_D7   (HPS_USB_DATA[7]),
        .hps_io_hps_io_usb1_inst_DIR  (HPS_USB_DIR),
        .hps_io_hps_io_usb1_inst_NXT  (HPS_USB_NXT),
        .hps_io_hps_io_usb1_inst_STP  (HPS_USB_STP),

        // LWH2F AXI Lite bridge (h2f_lw_axi_master)
        .h2f_lw_axi_clk     (CLOCK_50),
        .h2f_lw_AWADDR      (axi_lw_awaddr),
        .h2f_lw_AWVALID     (axi_lw_awvalid),
        .h2f_lw_AWREADY     (axi_lw_awready),
        .h2f_lw_WDATA       (axi_lw_wdata),
        .h2f_lw_WSTRB       (axi_lw_wstrb),
        .h2f_lw_WVALID      (axi_lw_wvalid),
        .h2f_lw_WREADY      (axi_lw_wready),
        .h2f_lw_BRESP       (axi_lw_bresp),
        .h2f_lw_BVALID      (axi_lw_bvalid),
        .h2f_lw_BREADY      (axi_lw_bready),
        .h2f_lw_ARADDR      (axi_lw_araddr),
        .h2f_lw_ARVALID     (axi_lw_arvalid),
        .h2f_lw_ARREADY     (axi_lw_arready),
        .h2f_lw_RDATA       (axi_lw_rdata),
        .h2f_lw_RRESP       (axi_lw_rresp),
        .h2f_lw_RVALID      (axi_lw_rvalid),
        .h2f_lw_RREADY      (axi_lw_rready)
    );

    // -------------------------------------------------------------------------
    // AXI Lite to Avalon-MM converter (bridge AXI to Avalon-MM)
    // -------------------------------------------------------------------------
    axi_lite_to_avalon u_axi_to_avl (
        .clk                (CLOCK_50),
        .reset_n            (RESET_n),

        // AXI Lite master (from soc_system)
        .AWADDR             (axi_lw_awaddr),
        .AWVALID            (axi_lw_awvalid),
        .AWREADY            (axi_lw_awready),
        .WDATA              (axi_lw_wdata),
        .WSTRB              (axi_lw_wstrb),
        .WVALID             (axi_lw_wvalid),
        .WREADY             (axi_lw_wready),
        .BRESP              (axi_lw_bresp),
        .BVALID             (axi_lw_bvalid),
        .BREADY             (axi_lw_bready),
        .ARADDR             (axi_lw_araddr),
        .ARVALID            (axi_lw_arvalid),
        .ARREADY            (axi_lw_arready),
        .RDATA              (axi_lw_rdata),
        .RRESP              (axi_lw_rresp),
        .RVALID             (axi_lw_rvalid),
        .RREADY             (axi_lw_rready),

        // Avalon-MM slave (to odocrypt_top)
        .avs_address        (lw_address),
        .avs_read           (lw_read),
        .avs_write          (lw_write),
        .avs_writedata      (lw_writedata),
        .avs_readdata       (lw_readdata),
        .avs_waitrequest    (lw_waitrequest)
    );

    // -------------------------------------------------------------------------
    // OdoCrypt miner slave
    // -------------------------------------------------------------------------
    odocrypt_top u_miner (
        .clk            (lw_clk),
        .reset_n        (lw_reset_n),
        .avs_address    (lw_address),
        .avs_read       (lw_read),
        .avs_write      (lw_write),
        .avs_writedata  (lw_writedata),
        .avs_readdata   (lw_readdata),
        .avs_waitrequest(lw_waitrequest)
    );

    // -------------------------------------------------------------------------
    // Unused board outputs — drive to safe defaults until HPS system is live
    // -------------------------------------------------------------------------
    assign HPS_DDR3_ADDR    = 15'h0;
    assign HPS_DDR3_BA      = 3'h0;
    assign HPS_DDR3_CAS_n   = 1'b1;
    assign HPS_DDR3_CKE     = 1'b0;
    assign HPS_DDR3_CK_n    = 1'b1;
    assign HPS_DDR3_CK_p    = 1'b0;
    assign HPS_DDR3_CS_n    = 1'b1;
    assign HPS_DDR3_DM      = 4'h0;
    assign HPS_DDR3_ODT     = 1'b0;
    assign HPS_DDR3_RAS_n   = 1'b1;
    assign HPS_DDR3_RESET_n = 1'b0;
    assign HPS_DDR3_WE_n    = 1'b1;
    assign HPS_ENET_GTX_CLK = 1'b0;
    assign HPS_ENET_MDC     = 1'b0;
    assign HPS_ENET_TX_DATA = 4'h0;
    assign HPS_ENET_TX_EN   = 1'b0;
    assign HPS_SD_CLK       = 1'b0;
    assign HPS_UART_TX      = 1'b1;
    assign HPS_USB_STP      = 1'b1;

endmodule
