// soc_top.v — Top-level FPGA module for the QMTECH Cyclone V SoC (5CSXFC6C6U23)
//
// This module sits at the top of the Quartus hierarchy. It:
//   1. Instantiates the Platform Designer system (soc_system) — which contains
//      the HPS, the DDR3 controller, and the HPS-to-FPGA (h2f) AXI master
//      bridge.
//   2. Adapts the 64-bit h2f AXI3 master down to a 32-bit AXI-Lite stream and
//      then to Avalon-MM, driving odocrypt_top as the register slave.
//   3. Wires board-level I/O (clock, reset, DDR3) to the Qsys system.
//
// PORT CONTRACT — derived from the GENERATED wrapper
//   hdl/qsys/soc_system/synthesis/soc_system.v
//
// The generated soc_system exports ONLY:
//   * clk_clk, reset_reset_n
//   * memory_mem_* / memory_oct_rzqin   (DDR3, configured 32-bit wide, 2 DRAM chips)
//   * h2f_axi_master_*                   (64-bit AXI3 HPS->FPGA master)
//   * h2f_reset_reset_n                  (reset output from the HPS)
//
// It does NOT export any hps_io_* peripheral ports (EMAC/SD/UART/USB). On this
// device those HPS peripherals are routed through the dedicated HPS I/O bank and
// are configured by the bootloader / device tree pin-mux — they are NOT FPGA
// fabric ports, so they must not be connected here.
//
// NOTE ON DDR3 WIDTH: QMTECH board uses 32-bit DDR3 (MT41K256M16TW x2 = 32-bit).
// Qsys/Platform Designer is configured for 32-bit data path (mem_dq[31:0],
// mem_dqs[1:0], mem_dm[3:0], mem_a[14:0]). Declarations match the target
// board configuration.

module soc_top (
    // -- Board clock & reset --------------------------------------------------
    input  wire        CLOCK_50,   // 50 MHz oscillator
    input  wire        RESET_n,    // Active-low board reset

    // -- HPS DDR3 SDRAM -------------------------------------------------------
    // Driven by the HPS hard memory controller. 32-bit data path (two 16-bit DRAM chips).
    output wire [14:0] HPS_DDR3_ADDR,
    output wire [2:0]  HPS_DDR3_BA,
    output wire        HPS_DDR3_CAS_n,
    output wire [1:0]  HPS_DDR3_CKE,
    output wire        HPS_DDR3_CK_n,
    output wire        HPS_DDR3_CK_p,
    output wire [1:0]  HPS_DDR3_CS_n,
    output wire [3:0]  HPS_DDR3_DM,
    inout  wire [31:0] HPS_DDR3_DQ,
    inout  wire [1:0]  HPS_DDR3_DQS_n,
    inout  wire [1:0]  HPS_DDR3_DQS_p,
    output wire [1:0]  HPS_DDR3_ODT,
    output wire        HPS_DDR3_RAS_n,
    output wire        HPS_DDR3_RESET_n,
    output wire        HPS_DDR3_WE_n,
    input  wire        HPS_DDR3_RZQ
);

    // -------------------------------------------------------------------------
    // h2f AXI master bus — exported by soc_system, driven by the HPS.
    // 64-bit data, 30-bit address, AXI3 (with ID + burst fields).
    // -------------------------------------------------------------------------
    // Write address
    wire [11:0] h2f_awid;
    wire [29:0] h2f_awaddr;
    wire [3:0]  h2f_awlen;
    wire [2:0]  h2f_awsize;
    wire [1:0]  h2f_awburst;
    wire [1:0]  h2f_awlock;
    wire [3:0]  h2f_awcache;
    wire [2:0]  h2f_awprot;
    wire        h2f_awvalid;
    wire        h2f_awready;
    // Write data
    wire [11:0] h2f_wid;
    wire [63:0] h2f_wdata;
    wire [7:0]  h2f_wstrb;
    wire        h2f_wlast;
    wire        h2f_wvalid;
    wire        h2f_wready;
    // Write response
    wire [11:0] h2f_bid;
    wire [1:0]  h2f_bresp;
    wire        h2f_bvalid;
    wire        h2f_bready;
    // Read address
    wire [11:0] h2f_arid;
    wire [29:0] h2f_araddr;
    wire [3:0]  h2f_arlen;
    wire [2:0]  h2f_arsize;
    wire [1:0]  h2f_arburst;
    wire [1:0]  h2f_arlock;
    wire [3:0]  h2f_arcache;
    wire [2:0]  h2f_arprot;
    wire        h2f_arvalid;
    wire        h2f_arready;
    // Read data
    wire [11:0] h2f_rid;
    wire [63:0] h2f_rdata;
    wire [1:0]  h2f_rresp;
    wire        h2f_rlast;
    wire        h2f_rvalid;
    wire        h2f_rready;

    // HPS-sourced reset for the fabric (active-low).
    wire        h2f_reset_n;

    // -------------------------------------------------------------------------
    // soc_system — Platform Designer generated wrapper (HPS + DDR3 + h2f AXI)
    // Port names below MUST match hdl/qsys/soc_system/synthesis/soc_system.v.
    // -------------------------------------------------------------------------
    soc_system u_soc (
        // Clocks & resets
        .clk_clk                 (CLOCK_50),
        .reset_reset_n           (RESET_n),

        // DDR3
        .memory_mem_a            (HPS_DDR3_ADDR),
        .memory_mem_ba           (HPS_DDR3_BA),
        .memory_mem_ck           (HPS_DDR3_CK_p),
        .memory_mem_ck_n         (HPS_DDR3_CK_n),
        .memory_mem_cke          (HPS_DDR3_CKE),
        .memory_mem_cs_n         (HPS_DDR3_CS_n),
        .memory_mem_ras_n        (HPS_DDR3_RAS_n),
        .memory_mem_cas_n        (HPS_DDR3_CAS_n),
        .memory_mem_we_n         (HPS_DDR3_WE_n),
        .memory_mem_reset_n      (HPS_DDR3_RESET_n),
        .memory_mem_dq           (HPS_DDR3_DQ),
        .memory_mem_dqs          (HPS_DDR3_DQS_p),
        .memory_mem_dqs_n        (HPS_DDR3_DQS_n),
        .memory_mem_odt          (HPS_DDR3_ODT),
        .memory_mem_dm           (HPS_DDR3_DM),
        .memory_oct_rzqin        (HPS_DDR3_RZQ),

        // HPS-to-FPGA AXI master (64-bit)
        .h2f_axi_master_awid     (h2f_awid),
        .h2f_axi_master_awaddr   (h2f_awaddr),
        .h2f_axi_master_awlen    (h2f_awlen),
        .h2f_axi_master_awsize   (h2f_awsize),
        .h2f_axi_master_awburst  (h2f_awburst),
        .h2f_axi_master_awlock   (h2f_awlock),
        .h2f_axi_master_awcache  (h2f_awcache),
        .h2f_axi_master_awprot   (h2f_awprot),
        .h2f_axi_master_awvalid  (h2f_awvalid),
        .h2f_axi_master_awready  (h2f_awready),
        .h2f_axi_master_wid      (h2f_wid),
        .h2f_axi_master_wdata    (h2f_wdata),
        .h2f_axi_master_wstrb    (h2f_wstrb),
        .h2f_axi_master_wlast    (h2f_wlast),
        .h2f_axi_master_wvalid   (h2f_wvalid),
        .h2f_axi_master_wready   (h2f_wready),
        .h2f_axi_master_bid      (h2f_bid),
        .h2f_axi_master_bresp    (h2f_bresp),
        .h2f_axi_master_bvalid   (h2f_bvalid),
        .h2f_axi_master_bready   (h2f_bready),
        .h2f_axi_master_arid     (h2f_arid),
        .h2f_axi_master_araddr   (h2f_araddr),
        .h2f_axi_master_arlen    (h2f_arlen),
        .h2f_axi_master_arsize   (h2f_arsize),
        .h2f_axi_master_arburst  (h2f_arburst),
        .h2f_axi_master_arlock   (h2f_arlock),
        .h2f_axi_master_arcache  (h2f_arcache),
        .h2f_axi_master_arprot   (h2f_arprot),
        .h2f_axi_master_arvalid  (h2f_arvalid),
        .h2f_axi_master_arready  (h2f_arready),
        .h2f_axi_master_rid      (h2f_rid),
        .h2f_axi_master_rdata    (h2f_rdata),
        .h2f_axi_master_rresp    (h2f_rresp),
        .h2f_axi_master_rlast    (h2f_rlast),
        .h2f_axi_master_rvalid   (h2f_rvalid),
        .h2f_axi_master_rready   (h2f_rready),

        // HPS-to-FPGA reset
        .h2f_reset_reset_n       (h2f_reset_n)
    );

    // -------------------------------------------------------------------------
    // 32-bit AXI-Lite signals between the h2f adapter and the AXI-Lite->Avalon
    // bridge.
    // -------------------------------------------------------------------------
    wire [31:0] al_awaddr;
    wire        al_awvalid;
    wire        al_awready;
    wire [31:0] al_wdata;
    wire [3:0]  al_wstrb;
    wire        al_wvalid;
    wire        al_wready;
    wire [1:0]  al_bresp;
    wire        al_bvalid;
    wire        al_bready;
    wire [31:0] al_araddr;
    wire        al_arvalid;
    wire        al_arready;
    wire [31:0] al_rdata;
    wire [1:0]  al_rresp;
    wire        al_rvalid;
    wire        al_rready;

    // -------------------------------------------------------------------------
    // Avalon-MM signals between the AXI-Lite bridge and odocrypt_top.
    // -------------------------------------------------------------------------
    wire [7:0]  avs_address;
    wire        avs_read;
    wire        avs_write;
    wire [31:0] avs_writedata;
    wire [31:0] avs_readdata;
    wire        avs_waitrequest;

    // Fabric reset for the miner subsystem (active-low, from the HPS).
    wire fabric_reset_n = h2f_reset_n;

    // -------------------------------------------------------------------------
    // 64-bit h2f AXI3 master -> 32-bit AXI-Lite adapter
    // -------------------------------------------------------------------------
    h2f_axi_to_axilite u_h2f_adapt (
        .clk        (CLOCK_50),
        .reset_n    (fabric_reset_n),

        .s_awid     (h2f_awid),
        .s_awaddr   (h2f_awaddr),
        .s_awlen    (h2f_awlen),
        .s_awsize   (h2f_awsize),
        .s_awburst  (h2f_awburst),
        .s_awvalid  (h2f_awvalid),
        .s_awready  (h2f_awready),

        .s_wid      (h2f_wid),
        .s_wdata    (h2f_wdata),
        .s_wstrb    (h2f_wstrb),
        .s_wlast    (h2f_wlast),
        .s_wvalid   (h2f_wvalid),
        .s_wready   (h2f_wready),

        .s_bid      (h2f_bid),
        .s_bresp    (h2f_bresp),
        .s_bvalid   (h2f_bvalid),
        .s_bready   (h2f_bready),

        .s_arid     (h2f_arid),
        .s_araddr   (h2f_araddr),
        .s_arlen    (h2f_arlen),
        .s_arsize   (h2f_arsize),
        .s_arburst  (h2f_arburst),
        .s_arvalid  (h2f_arvalid),
        .s_arready  (h2f_arready),

        .s_rid      (h2f_rid),
        .s_rdata    (h2f_rdata),
        .s_rresp    (h2f_rresp),
        .s_rlast    (h2f_rlast),
        .s_rvalid   (h2f_rvalid),
        .s_rready   (h2f_rready),

        .m_awaddr   (al_awaddr),
        .m_awvalid  (al_awvalid),
        .m_awready  (al_awready),
        .m_wdata    (al_wdata),
        .m_wstrb    (al_wstrb),
        .m_wvalid   (al_wvalid),
        .m_wready   (al_wready),
        .m_bresp    (al_bresp),
        .m_bvalid   (al_bvalid),
        .m_bready   (al_bready),
        .m_araddr   (al_araddr),
        .m_arvalid  (al_arvalid),
        .m_arready  (al_arready),
        .m_rdata    (al_rdata),
        .m_rresp    (al_rresp),
        .m_rvalid   (al_rvalid),
        .m_rready   (al_rready)
    );

    // -------------------------------------------------------------------------
    // 32-bit AXI-Lite -> Avalon-MM bridge
    // -------------------------------------------------------------------------
    axi_lite_to_avalon u_axi_to_avl (
        .clk             (CLOCK_50),
        .reset_n         (fabric_reset_n),

        .AWADDR          (al_awaddr),
        .AWVALID         (al_awvalid),
        .AWREADY         (al_awready),
        .WDATA           (al_wdata),
        .WSTRB           (al_wstrb),
        .WVALID          (al_wvalid),
        .WREADY          (al_wready),
        .BRESP           (al_bresp),
        .BVALID          (al_bvalid),
        .BREADY          (al_bready),
        .ARADDR          (al_araddr),
        .ARVALID         (al_arvalid),
        .ARREADY         (al_arready),
        .RDATA           (al_rdata),
        .RRESP           (al_rresp),
        .RVALID          (al_rvalid),
        .RREADY          (al_rready),

        .avs_address     (avs_address),
        .avs_read        (avs_read),
        .avs_write       (avs_write),
        .avs_writedata   (avs_writedata),
        .avs_readdata    (avs_readdata),
        .avs_waitrequest (avs_waitrequest)
    );

    // -------------------------------------------------------------------------
    // OdoCrypt miner — Avalon-MM register slave
    // -------------------------------------------------------------------------
    odocrypt_top u_miner (
        .clk             (CLOCK_50),
        .reset_n         (fabric_reset_n),

        .avs_address     (avs_address),
        .avs_read        (avs_read),
        .avs_write       (avs_write),
        .avs_writedata   (avs_writedata),
        .avs_readdata    (avs_readdata),
        .avs_waitrequest (avs_waitrequest)
    );

endmodule
