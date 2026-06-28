// pipelined_miner_top.v — Avalon-MM wrapper for the upstream pipelined OdoCrypt
// miner (Phase 1 of docs/pipelined-phase1-plan.md).
//
// Replaces the upstream JTAG (altsource_probe) interface with an HPS-driven
// register file and crosses into the 150 MHz miner clock domain.
//
// The upstream `miner` core FREE-RUNS: it continuously sweeps all 2^32 nonces
// (a new nonce every `THROUGHPUT cycles) and latches its `nonce` output whenever
// a hash <= target. There is no start/stop and no found strobe — the host polls.
// We:
//   * snapshot header/target into the miner domain on a commit handshake
//     (data-stable CDC: the HPS writes all words, then toggles COMMIT; only the
//      1-bit toggle is synchronized, the data is stable when sampled), and
//   * hand found nonces back through a dual-clock async FIFO (depth 8, Gray-code
//     pointer CDC; read-to-consume), so bursts of finds buffer rather than drop.
//
// Requires `THROUGHPUT and `ODOKEY defined (VERILOG_MACRO in the qsf / -D in the
// testbench), exactly like the upstream flow. The per-epoch odo_<seed>.v (module
// odo_encrypt), upstream keccak800.v, miner.v and checksum.v must be in the
// compile fileset.

module pipelined_miner_top (
    input  wire        clk,         // Avalon / soc_system fabric clock (~55 MHz)
    input  wire        reset_n,
    input  wire        miner_clk,   // 150 MHz pipeline clock (PLL clk1)

    // Avalon-MM Lite slave
    input  wire [7:0]  avs_address,
    input  wire        avs_read,
    input  wire        avs_write,
    input  wire [31:0] avs_writedata,
    output reg  [31:0] avs_readdata,
    output wire        avs_waitrequest,

    // Avalon interrupt sender: level, asserted while a found nonce is
    // waiting to be consumed (mirrors FSTATUS bit0); clears itself the
    // same cycle the HPS reads ADDR_FNONCE, no separate ack register.
    output wire        irq
);
    assign avs_waitrequest = 1'b0;   // single-cycle register access

    // ----------------------------------------------------------------- regmap
    localparam ADDR_CONTROL = 8'h00; // W : bit1 soft_reset (informational)
    localparam ADDR_STATUS  = 8'h04; // R : bit0 running, bit1 pll_ok, bit2 empty
    localparam ADDR_VERSION = 8'h08; // R : 0x0002_xxxx (pipelined)
    localparam ADDR_SEED    = 8'h0C; // R : baked-in `ODOKEY (epoch of bitstream)
    localparam ADDR_TARGET  = 8'h20; // W : 0x20..0x3C  (8 words, 256 bits)
    localparam ADDR_HEADER  = 8'h40; // W : 0x40..0x88  (19 words, 608 bits)
    localparam ADDR_COMMIT  = 8'h8C; // W : toggle -> latch header/target
    localparam ADDR_FNONCE  = 8'h90; // R : pop found nonce (read-to-consume)
    localparam ADDR_FSTATUS = 8'h94; // R : bit0 valid

    // ----------------------------------------------- Avalon-domain config regs
    reg [31:0] header_reg [0:18];
    reg [31:0] target_reg [0:7];
    reg        commit_tgl;
    reg        soft_reset;

    wire [607:0] header_flat;
    wire [255:0] target_flat;
    genvar gi;
    generate
        for (gi = 0; gi < 19; gi = gi + 1) begin : hdr_flat
            assign header_flat[32*gi +: 32] = header_reg[gi];
        end
        for (gi = 0; gi < 8; gi = gi + 1) begin : tgt_flat
            assign target_flat[32*gi +: 32] = target_reg[gi];
        end
    endgenerate

    integer i;
    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            commit_tgl <= 1'b0;
            soft_reset <= 1'b0;
            for (i = 0; i < 19; i = i + 1) header_reg[i] <= 32'h0;
            for (i = 0; i < 8;  i = i + 1) target_reg[i] <= 32'h0;
        end else if (avs_write) begin
            if (avs_address == ADDR_CONTROL)
                soft_reset <= avs_writedata[1];
            else if (avs_address >= ADDR_TARGET && avs_address < ADDR_TARGET + 8'd32)
                target_reg[(avs_address - ADDR_TARGET) >> 2] <= avs_writedata;
            else if (avs_address >= ADDR_HEADER && avs_address < ADDR_HEADER + 8'd76)
                header_reg[(avs_address - ADDR_HEADER) >> 2] <= avs_writedata;
            else if (avs_address == ADDR_COMMIT)
                commit_tgl <= ~commit_tgl;   // request a config snapshot
        end
    end

    // ----------------------------------- Config CDC: Avalon -> miner (150 MHz)
    // Sync the commit toggle; on its edge the header/target buses have been
    // stable for many cycles, so sampling them is a safe data-stable crossing.
    // After a commit the pipeline still holds in-flight nonces hashed with the
    // PREVIOUS header; those drain over the pipeline latency and can spuriously
    // qualify against the new target. Suppress found-reporting for SETTLE cycles
    // after each commit so only nonces fully processed with the new header are
    // reported (the upstream host filters the same staleness via re-check).
    localparam [12:0] SETTLE = 13'd4096;
    reg cmt_s1, cmt_s2, cmt_s3;
    reg [12:0]  settle_cnt;
    reg [607:0] header_m;
    reg [255:0] target_m;
    initial begin
        cmt_s1 = 0; cmt_s2 = 0; cmt_s3 = 0;
        header_m = 0; target_m = 0; settle_cnt = 0;
    end
    always @(posedge miner_clk) begin
        cmt_s1 <= commit_tgl;
        cmt_s2 <= cmt_s1;
        cmt_s3 <= cmt_s2;
        if (cmt_s2 ^ cmt_s3) begin
            header_m   <= header_flat;
            target_m   <= target_flat;
            settle_cnt <= SETTLE;
        end else if (settle_cnt != 0) begin
            settle_cnt <= settle_cnt - 1'b1;
        end
    end

    // ----------------------- Reset synchronizer into the miner_clk domain
    // The async FIFO's write-side state lives in miner_clk; without a reset
    // there it only ever cleared at power-on (FPGA config). Synchronize the
    // Avalon reset into miner_clk so a runtime reset_n clears BOTH pointer sets
    // coherently (async-assert, sync-deassert).
    reg miner_rst_s1, miner_rst_s2;
    always @(posedge miner_clk or negedge reset_n) begin
        if (!reset_n) begin miner_rst_s1 <= 1'b1; miner_rst_s2 <= 1'b1; end
        else          begin miner_rst_s1 <= 1'b0; miner_rst_s2 <= miner_rst_s1; end
    end
    wire miner_rst = miner_rst_s2;

    // ------------------------------------------- Free-running pipelined miner
    wire [31:0] found_nonce_m;
    wire        found_strobe_m;
    miner u_miner (miner_clk, header_m, target_m, found_nonce_m, found_strobe_m);

    // ----------------------------- Found handoff: miner domain -> Avalon domain
    // Dual-clock async FIFO (Gray-code pointers, Cummings-style CDC), depth 8, so
    // a burst of finds buffers instead of dropping while the HPS drains them.
    // Each core `found` strobe (past the settle window, FIFO not full) pushes one
    // nonce; reading ADDR_FNONCE pops (read-to-consume). irq/FSTATUS = not empty.
    // A strobe that arrives while full is dropped and latches a sticky overflow
    // flag (STATUS bit3) so the daemon can observe the loss.
    localparam FIFO_AW = 3;                       // 8 entries (2**FIFO_AW)
    reg  [31:0]      fifo_mem [0:(1<<FIFO_AW)-1];
    // write side (miner_clk)
    reg  [FIFO_AW:0] wbin, wgray;
    reg  [FIFO_AW:0] rgray_wq1, rgray_wq2;        // read-gray synced into write domain
    reg              fifo_ovf_m;                  // sticky: a find was dropped (full)
    // read side (Avalon clk)
    reg  [FIFO_AW:0] rbin, rgray;
    reg  [FIFO_AW:0] wgray_rq1, wgray_rq2;        // write-gray synced into read domain
    reg              ovf_rq1, ovf_rq2;            // overflow flag synced into read domain
    // write-side combinational
    wire [FIFO_AW:0] wbin_nxt  = wbin + 1'b1;
    wire [FIFO_AW:0] wgray_nxt = (wbin_nxt >> 1) ^ wbin_nxt;
    // Full on the CURRENT write pointer (symmetric with the empty test, which
    // uses the current read pointer): the FIFO is full when wptr has lapped rptr
    // by 2**FIFO_AW, i.e. the two MSBs are inverted and the low bits match. Using
    // wgray_nxt here instead asserts full one slot early (depth 7, not 8).
    wire             wfull = (wgray == {~rgray_wq2[FIFO_AW:FIFO_AW-1],
                                        rgray_wq2[FIFO_AW-2:0]});
    wire             new_find = found_strobe_m && (settle_cnt == 0);
    wire             w_en = new_find && !wfull;
    // read-side combinational
    wire [FIFO_AW:0] rbin_nxt  = rbin + 1'b1;
    wire [FIFO_AW:0] rgray_nxt = (rbin_nxt >> 1) ^ rbin_nxt;
    wire             found_valid = (rgray != wgray_rq2);   // not empty
    wire             r_en = avs_read && (avs_address == ADDR_FNONCE) && found_valid;
    wire [31:0]      fnonce_a = fifo_mem[rbin[FIFO_AW-1:0]];
    assign           irq = found_valid;
    initial begin
        wbin = 0; wgray = 0; rgray_wq1 = 0; rgray_wq2 = 0; fifo_ovf_m = 0;
    end
    always @(posedge miner_clk) begin            // write side
        if (miner_rst) begin
            wbin <= 0; wgray <= 0; rgray_wq1 <= 0; rgray_wq2 <= 0; fifo_ovf_m <= 1'b0;
        end else begin
            rgray_wq1 <= rgray;
            rgray_wq2 <= rgray_wq1;
            if (new_find && wfull) fifo_ovf_m <= 1'b1;   // dropped a find (full)
            if (w_en) begin
                fifo_mem[wbin[FIFO_AW-1:0]] <= found_nonce_m;
                wbin  <= wbin_nxt;
                wgray <= wgray_nxt;
            end
        end
    end
    always @(posedge clk or negedge reset_n) begin   // read side
        if (!reset_n) begin
            rbin <= 0; rgray <= 0; wgray_rq1 <= 0; wgray_rq2 <= 0;
            ovf_rq1 <= 0; ovf_rq2 <= 0;
        end else begin
            wgray_rq1 <= wgray;
            wgray_rq2 <= wgray_rq1;
            ovf_rq1   <= fifo_ovf_m;
            ovf_rq2   <= ovf_rq1;
            if (r_en) begin
                rbin  <= rbin_nxt;
                rgray <= rgray_nxt;
            end
        end
    end

    // --------------------------------------------------------------- readback
    integer r;
    always @(*) begin
        avs_readdata = 32'h0;
        if (avs_address >= ADDR_TARGET && avs_address < ADDR_TARGET + 8'd32)
            avs_readdata = target_reg[(avs_address - ADDR_TARGET) >> 2];
        else if (avs_address >= ADDR_HEADER && avs_address < ADDR_HEADER + 8'd76)
            avs_readdata = header_reg[(avs_address - ADDR_HEADER) >> 2];
        else case (avs_address)
            ADDR_CONTROL: avs_readdata = {30'h0, soft_reset, 1'b0};
            ADDR_STATUS:  avs_readdata = {28'h0, ovf_rq2, ~found_valid, 1'b1, 1'b1};
            ADDR_VERSION: avs_readdata = 32'h0002_0000;
            ADDR_SEED:    avs_readdata = `ODOKEY;
            ADDR_FNONCE:  avs_readdata = fnonce_a;
            ADDR_FSTATUS: avs_readdata = {31'h0, found_valid};
            default:      avs_readdata = 32'h0;
        endcase
    end

endmodule
