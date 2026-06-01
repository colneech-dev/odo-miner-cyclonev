// odocrypt_epoch_tables.v
//
// Stores all per-epoch OdoCrypt tables and exposes them as combinatorial outputs.
// The HPS loads a new epoch by streaming 5964 32-bit words via EPOCH_WR_DATA,
// then writing EPOCH_COMMIT to swap the loading buffer into the active buffer.
//
// Write sequence (5964 words total, in strict order):
//   [   0.. 639]  Small S-boxes:   640 words  (40 sbox × 64 entries, packed 4×8-bit)
//   [ 640..5759]  Large S-boxes:  5120 words  (10 sbox × 1024 entries, packed 2×16-bit)
//   [5760..5819]  Pbox-0 masks:     60 words  (6 rounds × 5 lanes × 2 words / 64-bit)
//   [5820..5844]  Pbox-0 rotations: 25 words  (5 rounds × 5 lanes, 6-bit each)
//   [5845..5904]  Pbox-1 masks:     60 words
//   [5905..5929]  Pbox-1 rotations: 25 words
//   [5930..5935]  Global rotations:  6 words  (6-bit each)
//   [5936..5963]  Round keys:       28 words  (3 × 10-bit per word, 84 total)
//
// After streaming, HPS writes EPOCH_COMMIT (any value) to activate new tables.
// Cores should be stopped (CTRL_RESET) before loading and restarted after commit.
//
// Output flat packing (matches odocrypt_state.c layout):
//   sbox1_out[8*(s*64+e) +: 8]       = sbox1[s][e]   (6-bit value in 8-bit slot)
//   sbox2_out[16*(s*1024+e) +: 16]   = sbox2[s][e]   (10-bit value in 16-bit slot)
//   pmask_out[64*((p*6+j)*5+k) +: 64]= pbox[p].mask[j][k]
//   prot_out[6*((p*5+j)*5+k) +: 6]   = pbox[p].rotation[j][k]
//   rot_out[6*r +: 6]                 = rotations[r]
//   rk_out[10*r +: 10]               = round_key[r]

module odocrypt_epoch_tables (
    input  wire        clk,
    input  wire        reset_n,

    // Streaming write interface (from odocrypt_top Avalon-MM slave)
    input  wire        wr_en,     // pulse to write one word
    input  wire [31:0] wr_data,   // write data
    input  wire        commit,    // pulse to swap loading → active buffer

    // Table outputs (active buffer, combinatorial)
    output wire [20479:0]  sbox1_out,   // 40 × 64 × 8-bit
    output wire [163839:0] sbox2_out,   // 10 × 1024 × 16-bit
    output wire [38399:0]  pmask_out,   // 2 × 6 × 5 × 64-bit
    output wire [299:0]    prot_out,    // 2 × 5 × 5 × 6-bit
    output wire [35:0]     rot_out,     // 6 × 6-bit
    output wire [839:0]    rk_out,      // 84 × 10-bit

    output wire        tables_valid,    // high once at least one commit has occurred
    output wire [12:0] wr_addr_out      // current write pointer (read-back for debug)
);

    // -------------------------------------------------------------------------
    // Write-address counter
    // -------------------------------------------------------------------------
    localparam TOTAL_WORDS = 5964;

    reg [12:0] wr_addr;
    assign wr_addr_out = wr_addr;

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n)
            wr_addr <= 13'd0;
        else if (commit)
            wr_addr <= 13'd0;       // reset pointer after commit
        else if (wr_en && wr_addr < TOTAL_WORDS)
            wr_addr <= wr_addr + 1;
    end

    // -------------------------------------------------------------------------
    // Loading buffer (written by HPS over MMIO)
    // -------------------------------------------------------------------------

    // Small S-boxes: 640 words, packed 4 × 8-bit per word
    reg [7:0]  load_sbox1 [0:39][0:63];

    // Large S-boxes: 5120 words, packed 2 × 16-bit per word
    reg [15:0] load_sbox2 [0:9][0:1023];

    // P-box masks: 60 words per P-box (6 subrounds × 5 lanes × 2 words)
    reg [63:0] load_pmask [0:1][0:5][0:4];
    reg [31:0] load_pmask_hi_buf;  // holds hi 32-bit while lo is being written
    reg        load_pmask_lo_written;

    // P-box rotations: 25 words per P-box (5 subrounds × 5 lanes)
    reg [5:0]  load_prot [0:1][0:4][0:4];

    // Global rotations: 6 words
    reg [5:0]  load_rot [0:5];

    // Round keys: 28 words (3 × 10-bit per word)
    reg [9:0]  load_rk [0:83];

    // Active buffer (committed copy)
    reg [7:0]  act_sbox1 [0:39][0:63];
    reg [15:0] act_sbox2 [0:9][0:1023];
    reg [63:0] act_pmask [0:1][0:5][0:4];
    reg [5:0]  act_prot  [0:1][0:4][0:4];
    reg [5:0]  act_rot   [0:5];
    reg [9:0]  act_rk    [0:83];

    reg        valid_r;
    assign tables_valid = valid_r;

    // -------------------------------------------------------------------------
    // Decode write address and write loading buffer
    // -------------------------------------------------------------------------
    // Address ranges:
    //   [0..639]      small sbox:  word = s*16 + e/4;  entry = e%4
    //   [640..5759]   large sbox:  word = 640 + s*512 + e/2;  entry = e%2
    //   [5760..5819]  pmask[0]:    60 words = j*10 + k*2 + lo/hi
    //   [5820..5844]  prot[0]:     25 words = j*5 + k
    //   [5845..5904]  pmask[1]:    60 words
    //   [5905..5929]  prot[1]:     25 words
    //   [5930..5935]  rot:          6 words
    //   [5936..5963]  round_key:   28 words = r/3

    integer i, j, k;

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            valid_r <= 1'b0;
            for (i = 0; i < 40; i = i+1)
                for (j = 0; j < 64; j = j+1)
                    load_sbox1[i][j] <= 8'd0;
            for (i = 0; i < 10; i = i+1)
                for (j = 0; j < 1024; j = j+1)
                    load_sbox2[i][j] <= 16'd0;
            for (i = 0; i < 2; i = i+1)
                for (j = 0; j < 6; j = j+1)
                    for (k = 0; k < 5; k = k+1)
                        load_pmask[i][j][k] <= 64'd0;
            for (i = 0; i < 2; i = i+1)
                for (j = 0; j < 5; j = j+1)
                    for (k = 0; k < 5; k = k+1)
                        load_prot[i][j][k] <= 6'd0;
            for (i = 0; i < 6; i = i+1) load_rot[i] <= 6'd0;
            for (i = 0; i < 84; i = i+1) load_rk[i] <= 10'd0;
            load_pmask_lo_written <= 1'b0;
        end else if (wr_en) begin
            if (wr_addr < 640) begin
                // Small S-boxes: 4 × 8-bit per word
                // sbox index = wr_addr / 16; entry group = wr_addr % 16
                // entry = (wr_addr % 16) × 4 + [0..3]
                begin
                    integer si, eg;
                    si = wr_addr / 16;
                    eg = (wr_addr % 16) * 4;
                    load_sbox1[si][eg+0] <= wr_data[7:0];
                    load_sbox1[si][eg+1] <= wr_data[15:8];
                    load_sbox1[si][eg+2] <= wr_data[23:16];
                    load_sbox1[si][eg+3] <= wr_data[31:24];
                end
            end else if (wr_addr < 5760) begin
                // Large S-boxes: 2 × 16-bit per word
                // offset within large sbox region: wr_addr - 640
                // sbox index = (wr_addr-640) / 512; entry group = (wr_addr-640)%512
                begin
                    integer si2, eg2;
                    si2 = (wr_addr - 640) / 512;
                    eg2 = ((wr_addr - 640) % 512) * 2;
                    load_sbox2[si2][eg2+0] <= {6'd0, wr_data[9:0]};
                    load_sbox2[si2][eg2+1] <= {6'd0, wr_data[25:16]};
                end
            end else if (wr_addr < 5820) begin
                // Pbox-0 masks: 60 words (lo/hi pairs for each 64-bit mask)
                // offset = wr_addr - 5760; pair_idx = offset/2; lo=0,hi=1
                begin
                    integer off, pi, jj, kk;
                    off = wr_addr - 5760;
                    pi  = off / 2;
                    jj  = pi / 5;
                    kk  = pi % 5;
                    if (off[0] == 1'b0)
                        load_pmask_hi_buf <= wr_data;
                    else
                        load_pmask[0][jj][kk] <= {wr_data, load_pmask_hi_buf};
                end
            end else if (wr_addr < 5845) begin
                // Pbox-0 rotations
                begin
                    integer off2, jj2, kk2;
                    off2 = wr_addr - 5820;
                    jj2  = off2 / 5;
                    kk2  = off2 % 5;
                    load_prot[0][jj2][kk2] <= wr_data[5:0];
                end
            end else if (wr_addr < 5905) begin
                // Pbox-1 masks
                begin
                    integer off3, pi3, jj3, kk3;
                    off3 = wr_addr - 5845;
                    pi3  = off3 / 2;
                    jj3  = pi3 / 5;
                    kk3  = pi3 % 5;
                    if (off3[0] == 1'b0)
                        load_pmask_hi_buf <= wr_data;
                    else
                        load_pmask[1][jj3][kk3] <= {wr_data, load_pmask_hi_buf};
                end
            end else if (wr_addr < 5930) begin
                // Pbox-1 rotations
                begin
                    integer off4, jj4, kk4;
                    off4 = wr_addr - 5905;
                    jj4  = off4 / 5;
                    kk4  = off4 % 5;
                    load_prot[1][jj4][kk4] <= wr_data[5:0];
                end
            end else if (wr_addr < 5936) begin
                // Global rotations
                load_rot[wr_addr - 5930] <= wr_data[5:0];
            end else begin
                // Round keys: 3 × 10-bit per word
                begin
                    integer rbase;
                    rbase = (wr_addr - 5936) * 3;
                    if (rbase    < 84) load_rk[rbase]   <= wr_data[9:0];
                    if (rbase+1  < 84) load_rk[rbase+1] <= wr_data[19:10];
                    if (rbase+2  < 84) load_rk[rbase+2] <= wr_data[29:20];
                end
            end
        end else if (commit) begin
            // Swap loading buffer → active buffer
            valid_r <= 1'b1;
            for (i = 0; i < 40; i = i+1)
                for (j = 0; j < 64; j = j+1)
                    act_sbox1[i][j] <= load_sbox1[i][j];
            for (i = 0; i < 10; i = i+1)
                for (j = 0; j < 1024; j = j+1)
                    act_sbox2[i][j] <= load_sbox2[i][j];
            for (i = 0; i < 2; i = i+1)
                for (j = 0; j < 6; j = j+1)
                    for (k = 0; k < 5; k = k+1)
                        act_pmask[i][j][k] <= load_pmask[i][j][k];
            for (i = 0; i < 2; i = i+1)
                for (j = 0; j < 5; j = j+1)
                    for (k = 0; k < 5; k = k+1)
                        act_prot[i][j][k] <= load_prot[i][j][k];
            for (i = 0; i < 6; i = i+1) act_rot[i] <= load_rot[i];
            for (i = 0; i < 84; i = i+1) act_rk[i] <= load_rk[i];
        end
    end

    // -------------------------------------------------------------------------
    // Flatten active buffer to output wires
    // -------------------------------------------------------------------------
    genvar gs, ge, gp, gj, gk, gr;

    generate
        for (gs = 0; gs < 40; gs = gs+1)
            for (ge = 0; ge < 64; ge = ge+1)
                assign sbox1_out[8*(gs*64+ge) +: 8] = act_sbox1[gs][ge];
    endgenerate

    generate
        for (gs = 0; gs < 10; gs = gs+1)
            for (ge = 0; ge < 1024; ge = ge+1)
                assign sbox2_out[16*(gs*1024+ge) +: 16] = act_sbox2[gs][ge];
    endgenerate

    generate
        for (gp = 0; gp < 2; gp = gp+1)
            for (gj = 0; gj < 6; gj = gj+1)
                for (gk = 0; gk < 5; gk = gk+1)
                    assign pmask_out[64*((gp*6+gj)*5+gk) +: 64] = act_pmask[gp][gj][gk];
    endgenerate

    generate
        for (gp = 0; gp < 2; gp = gp+1)
            for (gj = 0; gj < 5; gj = gj+1)
                for (gk = 0; gk < 5; gk = gk+1)
                    assign prot_out[6*((gp*5+gj)*5+gk) +: 6] = act_prot[gp][gj][gk];
    endgenerate

    generate
        for (gr = 0; gr < 6; gr = gr+1)
            assign rot_out[6*gr +: 6] = act_rot[gr];
    endgenerate

    generate
        for (gr = 0; gr < 84; gr = gr+1)
            assign rk_out[10*gr +: 10] = act_rk[gr];
    endgenerate

endmodule
