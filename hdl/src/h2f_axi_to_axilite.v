// h2f_axi_to_axilite.v
// Adapter: HPS h2f AXI3 master (64-bit data, 30-bit address, with ID + burst
// signals) -> 32-bit AXI-Lite slave-facing signals consumed by
// axi_lite_to_avalon.v.
//
// The HPS h2f_axi_master is a full AXI3 interface. The OdoCrypt register file
// is a small set of 32-bit registers accessed with single-beat transactions,
// so this adapter:
//   * Accepts only single-beat (AWLEN/ARLEN are ignored; treated as len 0).
//   * Selects the correct 32-bit half of the 64-bit data bus based on
//     address bit [2].
//   * Loops the transaction ID (AWID/ARID) back on the response channels
//     (BID/RID) as required by AXI3.
//
// Naming: ports prefixed s_* face the HPS h2f master (this module is the slave
// to the HPS). Ports prefixed m_* face the downstream 32-bit AXI-Lite bridge
// (this module is the master to that bridge).

module h2f_axi_to_axilite (
    input  wire        clk,
    input  wire        reset_n,

    // ---- Slave side: connects to soc_system h2f_axi_master_* -------------
    input  wire [11:0] s_awid,
    input  wire [29:0] s_awaddr,
    input  wire [3:0]  s_awlen,
    input  wire [2:0]  s_awsize,
    input  wire [1:0]  s_awburst,
    input  wire        s_awvalid,
    output wire        s_awready,

    input  wire [11:0] s_wid,
    input  wire [63:0] s_wdata,
    input  wire [7:0]  s_wstrb,
    input  wire        s_wlast,
    input  wire        s_wvalid,
    output wire        s_wready,

    output wire [11:0] s_bid,
    output wire [1:0]  s_bresp,
    output wire        s_bvalid,
    input  wire        s_bready,

    input  wire [11:0] s_arid,
    input  wire [29:0] s_araddr,
    input  wire [3:0]  s_arlen,
    input  wire [2:0]  s_arsize,
    input  wire [1:0]  s_arburst,
    input  wire        s_arvalid,
    output wire        s_arready,

    output wire [11:0] s_rid,
    output wire [63:0] s_rdata,
    output wire [1:0]  s_rresp,
    output wire        s_rlast,
    output wire        s_rvalid,
    input  wire        s_rready,

    // ---- Master side: connects to axi_lite_to_avalon ---------------------
    output wire [31:0] m_awaddr,
    output wire        m_awvalid,
    input  wire        m_awready,

    output wire [31:0] m_wdata,
    output wire [3:0]  m_wstrb,
    output wire        m_wvalid,
    input  wire        m_wready,

    input  wire [1:0]  m_bresp,
    input  wire        m_bvalid,
    output wire        m_bready,

    output wire [31:0] m_araddr,
    output wire        m_arvalid,
    input  wire        m_arready,

    input  wire [31:0] m_rdata,
    input  wire [1:0]  m_rresp,
    input  wire        m_rvalid,
    output wire        m_rready
);

    // ---------------------------------------------------------------------
    // Write address: latch ID and low address bit for response/data muxing.
    // ---------------------------------------------------------------------
    reg [11:0] aw_id_q;
    reg        aw_sel_hi_q;   // 1 => write data in upper 32 bits (addr[2]=1)

    always @(posedge clk or negedge reset_n) begin
        if (~reset_n) begin
            aw_id_q     <= 12'h0;
            aw_sel_hi_q <= 1'b0;
        end else if (s_awvalid && s_awready) begin
            aw_id_q     <= s_awid;
            aw_sel_hi_q <= s_awaddr[2];
        end
    end

    // Pass the write address straight through (zero-extend to 32 bits).
    assign m_awaddr  = {2'b00, s_awaddr};
    assign m_awvalid = s_awvalid;
    assign s_awready = m_awready;

    // Select the active 32-bit lane of the 64-bit write data bus. Use the
    // incoming address bit during the AW beat, then the latched value while
    // the data beat is outstanding.
    wire wsel_hi = (s_awvalid) ? s_awaddr[2] : aw_sel_hi_q;
    assign m_wdata = wsel_hi ? s_wdata[63:32] : s_wdata[31:0];
    assign m_wstrb = wsel_hi ? s_wstrb[7:4]   : s_wstrb[3:0];
    assign m_wvalid = s_wvalid;
    assign s_wready = m_wready;

    // Write response: replay the captured ID back to the HPS.
    assign s_bid    = aw_id_q;
    assign s_bresp  = m_bresp;
    assign s_bvalid = m_bvalid;
    assign m_bready = s_bready;

    // ---------------------------------------------------------------------
    // Read address: latch ID and low address bit for data placement.
    // ---------------------------------------------------------------------
    reg [11:0] ar_id_q;
    reg        ar_sel_hi_q;

    always @(posedge clk or negedge reset_n) begin
        if (~reset_n) begin
            ar_id_q     <= 12'h0;
            ar_sel_hi_q <= 1'b0;
        end else if (s_arvalid && s_arready) begin
            ar_id_q     <= s_arid;
            ar_sel_hi_q <= s_araddr[2];
        end
    end

    assign m_araddr  = {2'b00, s_araddr};
    assign m_arvalid = s_arvalid;
    assign s_arready = m_arready;

    // Place the 32-bit read data into the correct half of the 64-bit bus,
    // mirroring it onto both halves so byte-lane selection is harmless.
    assign s_rdata  = ar_sel_hi_q ? {m_rdata, 32'h0} : {32'h0, m_rdata};
    assign s_rid    = ar_id_q;
    assign s_rresp  = m_rresp;
    assign s_rlast  = 1'b1;            // single-beat transactions only
    assign s_rvalid = m_rvalid;
    assign m_rready = s_rready;

endmodule
