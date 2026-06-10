// odocrypt_epoch_tables.v
//
// Stores all per-epoch OdoCrypt tables. S-boxes live in inferred block RAM
// (M10K/MLAB) with two banks (ping-pong): the HPS streams a new epoch into
// the inactive bank, then a COMMIT write flips the active bank. The small
// P-box masks/rotations, global rotations, and round keys stay in registers
// with a loading copy committed into an active copy (they are only ~5 Kbit).
//
// Write sequence (5964 32-bit words total, in strict order):
//   [   0.. 639]  Small S-boxes:   640 words  (40 sbox × 64 entries, 4 × 8-bit)
//   [ 640..5759]  Large S-boxes:  5120 words  (10 sbox × 1024 entries, 2 × 16-bit)
//   [5760..5819]  Pbox-0 masks:     60 words  (6 subrounds × 5 lanes × lo/hi)
//   [5820..5844]  Pbox-0 rotations: 25 words  (5 subrounds × 5 lanes)
//   [5845..5904]  Pbox-1 masks:     60 words
//   [5905..5929]  Pbox-1 rotations: 25 words
//   [5930..5935]  Global rotations:  6 words
//   [5936..5963]  Round keys:       28 words  (3 × 10-bit per word)
//
// S-box words carry multiple entries, but the entry-wide RAMs have a single
// write port, so each accepted word is unpacked over several cycles (4 for
// small, 2 for large). wr_busy is asserted while unpacking; odocrypt_top
// stalls the Avalon write (waitrequest) when a new EPOCH_WR_DATA write
// arrives during that window, so no stream word is ever dropped.
//
// S-box read ports (used by odocrypt_core, synchronous, 1-cycle latency):
//   sb1_addr[6*i +: 6]    address into small sbox i (i = 0..39)
//   sb1_q   [6*i +: 6]    entry value, valid the cycle after the address
//   sb2_addr_a/b[10*i +: 10]  two read ports into large sbox i (i = 0..9)
//   sb2_q_a/b  [10*i +: 10]   entry values, 1-cycle latency
//
// FF table outputs (active copy, combinational):
//   pmask_out[64*((p*6+j)*5+k) +: 64] = pbox[p].mask[j][k]
//   prot_out [6*((p*5+j)*5+k) +: 6]   = pbox[p].rotation[j][k]
//   rot_out  [6*r +: 6]               = rotations[r]
//   rk_out   [10*r +: 10]             = round_key[r]

module odocrypt_epoch_tables (
    input  wire        clk,
    input  wire        reset_n,

    // Streaming write interface (from odocrypt_top Avalon-MM slave)
    input  wire        wr_en,     // pulse: accept one stream word
    input  wire [31:0] wr_data,
    input  wire        wr_reset,  // pulse: reset the write pointer to 0
    input  wire        commit,    // pulse: flip loading bank -> active
    output wire        wr_busy,   // unpacking previous word; stall new writes

    // Small S-box read ports (40 × 6-bit)
    input  wire [239:0] sb1_addr,
    output wire [239:0] sb1_q,

    // Large S-box read ports (10 × 10-bit, two ports)
    input  wire [99:0]  sb2_addr_a,
    input  wire [99:0]  sb2_addr_b,
    output wire [99:0]  sb2_q_a,
    output wire [99:0]  sb2_q_b,

    // FF tables (active copy)
    output wire [38399:0] pmask_out,
    output wire [299:0]   prot_out,
    output wire [35:0]    rot_out,
    output wire [839:0]   rk_out,

    output wire        tables_valid,
    output wire [12:0] wr_addr_out
);

    localparam TOTAL_WORDS = 5964;

    // -------------------------------------------------------------------------
    // Bank select: bank being loaded vs bank being read by the core
    // -------------------------------------------------------------------------
    reg active_bank;
    reg valid_r;
    assign tables_valid = valid_r;
    wire load_bank = ~active_bank;

    // -------------------------------------------------------------------------
    // Stream write pointer
    // -------------------------------------------------------------------------
    reg [12:0] wr_addr;
    assign wr_addr_out = wr_addr;

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n)
            wr_addr <= 13'd0;
        else if (wr_reset || commit)
            wr_addr <= 13'd0;
        else if (wr_en && !wr_busy && wr_addr < TOTAL_WORDS)
            wr_addr <= wr_addr + 13'd1;
    end

    // -------------------------------------------------------------------------
    // Region decode for the incoming stream word
    // -------------------------------------------------------------------------
    wire in_sb1  = (wr_addr < 13'd640);
    wire in_sb2  = (wr_addr >= 13'd640)  && (wr_addr < 13'd5760);

    // -------------------------------------------------------------------------
    // S-box write unpacker: serialises multi-entry words into the single
    // write port of the entry-wide RAMs.
    //   small word -> 4 entry writes; large word -> 2 entry writes.
    // The first entry is written in the same cycle the word is accepted;
    // the remaining entries occupy the unpack counter.
    // -------------------------------------------------------------------------
    reg  [31:0] unp_data;
    reg  [1:0]  unp_cnt;       // remaining entries after the current one
    reg         unp_is_small;
    reg  [5:0]  unp_sb1_sel;   // which small sbox (0..39)
    reg  [3:0]  unp_sb2_sel;   // which large sbox (0..9)
    reg  [6:0]  unp_sb1_base;  // first entry index within small sbox (0..63)
    reg  [10:0] unp_sb2_base;  // first entry index within large sbox (0..1023)

    assign wr_busy = (unp_cnt != 2'd0);

    // Accept pulse: a stream word for an S-box region enters the unpacker
    wire accept    = wr_en && !wr_busy;
    wire accept_sb = accept && (in_sb1 || in_sb2);

    // Decode target sbox/entry for the accepted word
    wire [5:0]  dec_sb1_sel  = wr_addr[9:4];                // wr_addr / 16 (0..39)
    wire [6:0]  dec_sb1_base = {wr_addr[3:0], 2'b00};       // (wr_addr % 16) * 4
    wire [12:0] sb2_off      = wr_addr - 13'd640;
    wire [3:0]  dec_sb2_sel  = sb2_off[12:9];               // off / 512
    wire [10:0] dec_sb2_base = {sb2_off[8:0], 1'b0};        // (off % 512) * 2

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            unp_cnt      <= 2'd0;
            unp_data     <= 32'd0;
            unp_is_small <= 1'b0;
            unp_sb1_sel  <= 6'd0;
            unp_sb2_sel  <= 4'd0;
            unp_sb1_base <= 7'd0;
            unp_sb2_base <= 11'd0;
        end else if (accept_sb) begin
            unp_data     <= wr_data;
            unp_is_small <= in_sb1;
            unp_sb1_sel  <= dec_sb1_sel;
            unp_sb2_sel  <= dec_sb2_sel;
            unp_sb1_base <= dec_sb1_base;
            unp_sb2_base <= dec_sb2_base;
            unp_cnt      <= in_sb1 ? 2'd3 : 2'd1;  // entries left after entry 0
        end else if (unp_cnt != 2'd0) begin
            unp_cnt <= unp_cnt - 2'd1;
        end
    end

    // Current entry being written: 0 on the accept cycle, then 4-cnt for
    // small (cnt 3,2,1 -> entries 1,2,3) and always 1 for large (cnt 1).
    wire [1:0] step_small = accept_sb ? 2'd0 : (2'd0 - unp_cnt);
    wire [1:0] step_large = accept_sb ? 2'd0 : 2'd1;

    // Write strobes and operands presented to the RAM banks
    wire        sb1_we     = (accept_sb && in_sb1) || (wr_busy && unp_is_small);
    wire [5:0]  sb1_wsel   = accept_sb ? dec_sb1_sel  : unp_sb1_sel;
    wire [6:0]  sb1_wentry = (accept_sb ? dec_sb1_base : unp_sb1_base) + {5'd0, step_small};
    wire [31:0] sb1_wword  = accept_sb ? wr_data : unp_data;
    wire [5:0]  sb1_wdata  = sb1_wword[8*step_small +: 6];

    wire        sb2_we     = (accept_sb && in_sb2) || (wr_busy && !unp_is_small);
    wire [3:0]  sb2_wsel   = accept_sb ? dec_sb2_sel  : unp_sb2_sel;
    wire [10:0] sb2_wentry = (accept_sb ? dec_sb2_base : unp_sb2_base) + {9'd0, step_large};
    wire [31:0] sb2_wword  = accept_sb ? wr_data : unp_data;
    wire [9:0]  sb2_wdata  = sb2_wword[16*step_large +: 10];

    // -------------------------------------------------------------------------
    // Small S-box RAMs: 40 × (2 banks × 64 entries × 6 bit)
    // Simple dual port: 1 write (loader), 1 read (core). Inferred MLAB/M10K.
    // -------------------------------------------------------------------------
    genvar gi;
    generate
        for (gi = 0; gi < 40; gi = gi + 1) begin : sb1_ram
            // Force M10K implementation. Without a hint (and even with an
            // MLAB hint — 128 deep exceeds MLAB geometry) Quartus silently
            // implements these arrays as ~770 registers + read muxes EACH,
            // blowing the ALM budget. no_rw_check waives the old-data
            // read-during-write semantics, which is safe: the core is held
            // in reset during table loads, so RDW never occurs.
            (* ramstyle = "M10K, no_rw_check" *) reg [5:0] mem [0:127];
            reg [5:0] q;
            wire we = sb1_we && (sb1_wsel == gi);
            always @(posedge clk) begin
                if (we)
                    mem[{load_bank, sb1_wentry[5:0]}] <= sb1_wdata;
                q <= mem[{active_bank, sb1_addr[6*gi +: 6]}];
            end
            assign sb1_q[6*gi +: 6] = q;
        end
    endgenerate

    // -------------------------------------------------------------------------
    // Large S-box RAMs: 10 × (2 banks × 1024 entries × 10 bit)
    // True dual port: port A = loader write / core read a, port B = core read b.
    // While loading, the core is held in reset, so port A never collides.
    // -------------------------------------------------------------------------
    generate
        for (gi = 0; gi < 10; gi = gi + 1) begin : sb2_ram
            reg [9:0] mem [0:2047];
            reg [9:0] q_a, q_b;
            wire we = sb2_we && (sb2_wsel == gi);
            wire [10:0] addr_a = we ? {load_bank, sb2_wentry[9:0]}
                                    : {active_bank, sb2_addr_a[10*gi +: 10]};
            always @(posedge clk) begin
                if (we)
                    mem[addr_a] <= sb2_wdata;
                else
                    q_a <= mem[addr_a];
            end
            always @(posedge clk) begin
                q_b <= mem[{active_bank, sb2_addr_b[10*gi +: 10]}];
            end
            assign sb2_q_a[10*gi +: 10] = q_a;
            assign sb2_q_b[10*gi +: 10] = q_b;
        end
    endgenerate

    // -------------------------------------------------------------------------
    // P-box masks/rotations, global rotations, round keys.
    // Single FF copy, written directly during the load stream. The core is
    // held in reset while tables load (epoch_watcher stops it), so no
    // double-buffering is needed — and the copy-commit muxes it would take
    // cost ~10k ALMs on this device.
    // -------------------------------------------------------------------------
    reg [63:0] tbl_pmask [0:1][0:5][0:4];
    reg [31:0] load_pmask_lo_buf;          // holds LOW 32 bits until the high
                                           // word arrives (lo is sent first)
    reg [5:0]  tbl_prot [0:1][0:4][0:4];
    reg [5:0]  tbl_rot  [0:5];
    reg [9:0]  tbl_rk   [0:83];

    integer i, j, k;

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            valid_r     <= 1'b0;
            active_bank <= 1'b0;
            load_pmask_lo_buf <= 32'd0;
            for (i = 0; i < 2; i = i+1)
                for (j = 0; j < 6; j = j+1)
                    for (k = 0; k < 5; k = k+1)
                        tbl_pmask[i][j][k] <= 64'd0;
            for (i = 0; i < 2; i = i+1)
                for (j = 0; j < 5; j = j+1)
                    for (k = 0; k < 5; k = k+1)
                        tbl_prot[i][j][k] <= 6'd0;
            for (i = 0; i < 6; i = i+1)  tbl_rot[i] <= 6'd0;
            for (i = 0; i < 84; i = i+1) tbl_rk[i]  <= 10'd0;
        end else if (accept && !in_sb1 && !in_sb2) begin
            if (wr_addr < 13'd5820) begin
                // Pbox-0 masks: lo word then hi word per 64-bit mask
                begin : pm0
                    integer off, pi, jj, kk;
                    off = wr_addr - 5760;
                    pi  = off / 2;
                    jj  = pi / 5;
                    kk  = pi % 5;
                    if (off[0] == 1'b0)
                        load_pmask_lo_buf <= wr_data;
                    else
                        tbl_pmask[0][jj][kk] <= {wr_data, load_pmask_lo_buf};
                end
            end else if (wr_addr < 13'd5845) begin
                begin : pr0
                    integer off2, jj2, kk2;
                    off2 = wr_addr - 5820;
                    jj2  = off2 / 5;
                    kk2  = off2 % 5;
                    tbl_prot[0][jj2][kk2] <= wr_data[5:0];
                end
            end else if (wr_addr < 13'd5905) begin
                begin : pm1
                    integer off3, pi3, jj3, kk3;
                    off3 = wr_addr - 5845;
                    pi3  = off3 / 2;
                    jj3  = pi3 / 5;
                    kk3  = pi3 % 5;
                    if (off3[0] == 1'b0)
                        load_pmask_lo_buf <= wr_data;
                    else
                        tbl_pmask[1][jj3][kk3] <= {wr_data, load_pmask_lo_buf};
                end
            end else if (wr_addr < 13'd5930) begin
                begin : pr1
                    integer off4, jj4, kk4;
                    off4 = wr_addr - 5905;
                    jj4  = off4 / 5;
                    kk4  = off4 % 5;
                    tbl_prot[1][jj4][kk4] <= wr_data[5:0];
                end
            end else if (wr_addr < 13'd5936) begin
                tbl_rot[wr_addr - 5930] <= wr_data[5:0];
            end else begin
                begin : rkw
                    integer rbase;
                    rbase = (wr_addr - 5936) * 3;
                    if (rbase   < 84) tbl_rk[rbase]   <= wr_data[9:0];
                    if (rbase+1 < 84) tbl_rk[rbase+1] <= wr_data[19:10];
                    if (rbase+2 < 84) tbl_rk[rbase+2] <= wr_data[29:20];
                end
            end
        end else if (commit) begin
            valid_r     <= 1'b1;
            active_bank <= ~active_bank;
        end
    end

    // -------------------------------------------------------------------------
    // Flatten FF tables to output wires
    // -------------------------------------------------------------------------
    genvar gp, gj, gk, gr;

    generate
        for (gp = 0; gp < 2; gp = gp+1) begin : gp_loop
            for (gj = 0; gj < 6; gj = gj+1) begin : gj_loop
                for (gk = 0; gk < 5; gk = gk+1) begin : gk_loop
                    assign pmask_out[64*((gp*6+gj)*5+gk) +: 64] = tbl_pmask[gp][gj][gk];
                end
            end
        end
    endgenerate

    generate
        for (gp = 0; gp < 2; gp = gp+1) begin : gp_loop2
            for (gj = 0; gj < 5; gj = gj+1) begin : gj_loop2
                for (gk = 0; gk < 5; gk = gk+1) begin : gk_loop2
                    assign prot_out[6*((gp*5+gj)*5+gk) +: 6] = tbl_prot[gp][gj][gk];
                end
            end
        end
    endgenerate

    generate
        for (gr = 0; gr < 6; gr = gr+1) begin : gr_loop
            assign rot_out[6*gr +: 6] = tbl_rot[gr];
        end
    endgenerate

    generate
        for (gr = 0; gr < 84; gr = gr+1) begin : gr_loop2
            assign rk_out[10*gr +: 10] = tbl_rk[gr];
        end
    endgenerate

endmodule
