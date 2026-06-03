// -----------------------------------------------------------------------------
// Multi‑core Odocrypt engine for Cyclone V (5CSXFC6C6U23)
// - Instantiates N parallel odocrypt_core pipelines
// - Stripes nonce ranges across cores
// - Reports first-found nonce
// - Drop-in replacement for single-core engine
// -----------------------------------------------------------------------------
module odocrypt_array #(
    parameter CORES = 4
)(
    input  wire         clk,
    input  wire         reset_n,

    input  wire         start,
    input  wire [31:0]  nonce_start,
    input  wire [31:0]  nonce_end,
    input  wire [639:0] header_words,  // 20 x 32-bit words packed
    input  wire [255:0] target,
    input  wire [31:0]  epoch,

    // Epoch tables (shared across all cores, driven by odocrypt_epoch_tables)
    input  wire [20479:0]  sbox1_flat,
    input  wire [163839:0] sbox2_flat,
    input  wire [38399:0]  pmask_flat,
    input  wire [299:0]    prot_flat,
    input  wire [35:0]     rot_flat,
    input  wire [839:0]    rk_flat,
    input  wire            tables_valid,

    output wire         busy,
    output reg          found,
    output reg  [31:0]  found_nonce
);

    // -------------------------------------------------------------------------
    // Internal signals
    // -------------------------------------------------------------------------
    localparam ARRAY_WIDTH = CORES * 32 - 1;

    wire [CORES-1:0] core_busy;
    wire [CORES-1:0] core_found;
    wire [ARRAY_WIDTH:0]  core_found_nonce;

    reg  [ARRAY_WIDTH:0]  core_nonce_start;
    reg  [ARRAY_WIDTH:0]  core_nonce_end;

    integer i;

    // -------------------------------------------------------------------------
    // Stripe nonce ranges across cores
    // Example for CORES=4:
    //   core0: start, start+4, start+8, ...
    //   core1: start+1, start+5, start+9, ...
    //   core2: start+2, start+6, start+10, ...
    //   core3: start+3, start+7, start+11, ...
    // -------------------------------------------------------------------------
    always @(*) begin
        for (i = 0; i < CORES; i = i + 1) begin
            core_nonce_start[32*i +: 32] = nonce_start + i;
            core_nonce_end[32*i +: 32]   = nonce_end;
        end
    end

    // -------------------------------------------------------------------------
    // Instantiate cores
    // -------------------------------------------------------------------------
    genvar gi;
    generate
        for (gi = 0; gi < CORES; gi = gi + 1) begin : GEN_CORES
            odocrypt_core core_inst (
                .clk          (clk),
                .reset_n      (reset_n),
                .start        (start),
                .nonce_start  (core_nonce_start[32*gi +: 32]),
                .nonce_end    (core_nonce_end[32*gi +: 32]),
                .header_words (header_words),
                .target       (target),
                .epoch        (epoch),
                .sbox1_flat   (sbox1_flat),
                .sbox2_flat   (sbox2_flat),
                .pmask_flat   (pmask_flat),
                .prot_flat    (prot_flat),
                .rot_flat     (rot_flat),
                .rk_flat      (rk_flat),
                .tables_valid (tables_valid),
                .busy         (core_busy[gi]),
                .found        (core_found[gi]),
                .found_nonce  (core_found_nonce[32*gi +: 32]),
                .hash_out     (),
                .hash_valid   ()
            );
        end
    endgenerate

    // -------------------------------------------------------------------------
    // Busy = any core busy
    // -------------------------------------------------------------------------
    assign busy = |core_busy;

    // -------------------------------------------------------------------------
    // Found = first core that reports success
    // -------------------------------------------------------------------------
    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            found       <= 1'b0;
            found_nonce <= 32'd0;
        end else begin
            if (start) begin
                found       <= 1'b0;
                found_nonce <= 32'd0;
            end else begin
                for (i = 0; i < CORES; i = i + 1) begin
                    if (core_found[i] && !found) begin
                        found       <= 1'b1;
                        found_nonce <= core_found_nonce[i];
                    end
                end
            end
        end
    end

endmodule
