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
//   * hand found nonces back through a 1-deep 2-phase handshake (read-to-consume;
//     widen to an async FIFO before hardware soak — see plan, found-FIFO).
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

    // ------------------------------------------- Free-running pipelined miner
    wire [31:0] found_nonce_m;
    miner u_miner (miner_clk, header_m, target_m, found_nonce_m);

    // ----------------------------- Found handoff: miner (150 MHz) -> Avalon
    // 1-deep 2-phase handshake. New finds while a previous one is unconsumed are
    // dropped (replace with an async FIFO before hardware soak).
    reg [31:0] prev_nonce_m;
    reg [31:0] fnonce_hold_m;
    reg        req_tgl_m;
    reg        ackm_s1, ackm_s2;     // ack synced into miner domain
    reg        reqa_s1, reqa_s2;     // req synced into Avalon domain
    reg        ack_tgl_a;
    reg [31:0] fnonce_a;
    wire       found_valid = (reqa_s2 != ack_tgl_a);
    assign     irq = found_valid;
    initial begin
        prev_nonce_m = 0; fnonce_hold_m = 0; req_tgl_m = 0;
        ackm_s1 = 0; ackm_s2 = 0;
    end

    always @(posedge miner_clk) begin
        ackm_s1 <= ack_tgl_a;
        ackm_s2 <= ackm_s1;
        prev_nonce_m <= found_nonce_m;
        // new find (nonce changed), handshake idle, and past the settle window
        if ((found_nonce_m != prev_nonce_m) && (req_tgl_m == ackm_s2)
            && (settle_cnt == 0)) begin
            fnonce_hold_m <= found_nonce_m;
            req_tgl_m     <= ~req_tgl_m;
        end
    end

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            reqa_s1 <= 1'b0; reqa_s2 <= 1'b0;
            ack_tgl_a <= 1'b0; fnonce_a <= 32'h0;
        end else begin
            reqa_s1 <= req_tgl_m;
            reqa_s2 <= reqa_s1;
            // fnonce_hold_m is stable while the handshake is pending
            if (found_valid)
                fnonce_a <= fnonce_hold_m;
            // reading the nonce consumes the entry
            if (avs_read && (avs_address == ADDR_FNONCE) && found_valid)
                ack_tgl_a <= ~ack_tgl_a;
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
            ADDR_STATUS:  avs_readdata = {29'h0, ~found_valid, 1'b1, 1'b1};
            ADDR_VERSION: avs_readdata = 32'h0002_0000;
            ADDR_SEED:    avs_readdata = `ODOKEY;
            ADDR_FNONCE:  avs_readdata = fnonce_a;
            ADDR_FSTATUS: avs_readdata = {31'h0, found_valid};
            default:      avs_readdata = 32'h0;
        endcase
    end

endmodule
