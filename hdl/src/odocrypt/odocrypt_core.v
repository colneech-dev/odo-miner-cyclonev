// -----------------------------------------------------------------------------
// Odocrypt core skeleton for Cyclone V (5CSXFC6C6U23)
// - Interface matches odocrypt_top
// - Single pipeline instance, one nonce at a time
// - FSM walks nonce range, asserts found + found_nonce on success
// - 84-round OdoCrypt-like pipeline with epoch-aware constants
// -----------------------------------------------------------------------------
module odocrypt_core (
    input  wire         clk,
    input  wire         reset_n,

    input  wire         start,
    input  wire [31:0]  nonce_start,
    input  wire [31:0]  nonce_end,
    input  wire [31:0]  header_words [0:19],
    input  wire [255:0]  target,
    input  wire [31:0]  epoch,

    output wire         busy,
    output reg          found,
    output reg  [31:0]  found_nonce,
    output reg [255:0]  hash_out,
    output reg          hash_valid
);

    // -------------------------------------------------------------------------
    // Parameters / localparams
    // -------------------------------------------------------------------------
    localparam ST_IDLE   = 3'd0;
    localparam ST_LOAD   = 3'd1;
    localparam ST_RUN    = 3'd2;
    localparam ST_CHECK  = 3'd3;
    localparam ST_DONE   = 3'd4;

    // Pipeline depth must match the compressor round count.
    localparam PIPE_DEPTH = 84;

    // -------------------------------------------------------------------------
    // State / control
    // -------------------------------------------------------------------------
    reg [2:0]  state, state_next;
    reg [31:0] nonce_cur, nonce_next;

    // Pipeline nonce tracking and valid flags for compressor output alignment.
    reg [31:0]  pipe_nonce   [0:PIPE_DEPTH];
    reg         pipe_valid   [0:PIPE_DEPTH];

    reg [255:0] compress_in_state;
    reg         compress_in_valid;
    wire [255:0] compress_out_state;
    wire         compress_out_valid;

    integer i;

    // -------------------------------------------------------------------------
    // FSM + nonce counter
    // -------------------------------------------------------------------------
    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            state      <= ST_IDLE;
            nonce_cur  <= 32'd0;
            found      <= 1'b0;
            found_nonce<= 32'd0;
            hash_out   <= 256'd0;
            hash_valid <= 1'b0;
            compress_in_state <= 256'd0;
            compress_in_valid <= 1'b0;

            for (i = 0; i <= PIPE_DEPTH; i = i + 1) begin
                pipe_nonce[i] <= 32'd0;
                pipe_valid[i] <= 1'b0;
            end
        end else begin
            state     <= state_next;
            nonce_cur <= nonce_next;

            // Shift nonce tracking for pipeline alignment.
            for (i = PIPE_DEPTH; i > 0; i = i - 1) begin
                pipe_nonce[i] <= pipe_nonce[i-1];
                pipe_valid[i] <= pipe_valid[i-1];
            end

            if (state == ST_LOAD || (state == ST_RUN && nonce_cur < nonce_end)) begin
                compress_in_state <= build_initial_state(header_words, nonce_cur, epoch);
                compress_in_valid <= 1'b1;
                pipe_nonce[0] <= nonce_cur;
                pipe_valid[0] <= 1'b1;
            end else begin
                compress_in_valid <= 1'b0;
                pipe_valid[0] <= 1'b0;
            end

            if (compress_out_valid && pipe_valid[PIPE_DEPTH]) begin
                hash_out   <= compress_out_state;
                hash_valid <= 1'b1;
                if (!found && hash_meets_target(compress_out_state)) begin
                    found       <= 1'b1;
                    found_nonce <= pipe_nonce[PIPE_DEPTH];
                end
            end else begin
                hash_valid <= 1'b0;
            end

            if (state == ST_IDLE && start) begin
                found       <= 1'b0;
                found_nonce <= 32'd0;
            end
        end
    end

    // -------------------------------------------------------------------------
    // Next-state logic
    // -------------------------------------------------------------------------
    always @(*) begin
        state_next  = state;
        nonce_next  = nonce_cur;

        busy        = (state != ST_IDLE && state != ST_DONE);

        case (state)
            ST_IDLE: begin
                if (start) begin
                    nonce_next = nonce_start;
                    state_next = ST_LOAD;
                end
            end

            ST_LOAD: begin
                state_next = ST_RUN;
            end

            ST_RUN: begin
                if (nonce_cur < nonce_end) begin
                    nonce_next = nonce_cur + 1;
                    state_next = ST_RUN;
                end else begin
                    state_next = ST_CHECK;
                end
            end

            ST_CHECK: begin
                if (!pipe_valid[PIPE_DEPTH])
                    state_next = ST_DONE;
            end

            ST_DONE: begin
                if (start) begin
                    // new job queued while previous was finishing — restart immediately
                    nonce_next = nonce_start;
                    state_next = ST_LOAD;
                end else begin
                    state_next = ST_IDLE;
                end
            end

            default: state_next = ST_IDLE;
        endcase
    end

    // -------------------------------------------------------------------------
    // Compressor instance for the OdoCrypt round pipeline.
    // -------------------------------------------------------------------------
    odocrypt_compress #(.ROUNDS(PIPE_DEPTH)) compress_inst (
        .clk       (clk),
        .reset_n   (reset_n),
        .in_state  (compress_in_state),
        .epoch     (epoch),
        .in_valid  (compress_in_valid),
        .out_state (compress_out_state),
        .out_valid (compress_out_valid)
    );

    // -------------------------------------------------------------------------
    // Functions: initial state and target compare.
    // -------------------------------------------------------------------------
    function [255:0] build_initial_state;
        input [31:0] hdr [0:19];
        input [31:0] nonce;
        input [31:0] epoch;
        reg   [63:0] w0;
        reg   [63:0] w1;
        reg   [63:0] w2;
        reg   [63:0] w3;
        reg   [63:0] w4;
        reg   [63:0] w5;
        reg   [63:0] w6;
        reg   [63:0] w7;
        reg   [63:0] w8;
        reg   [63:0] w9;
        reg   [63:0] pm;
        reg   [255:0] s;
        begin
            w0 = {hdr[1], hdr[0]};
            w1 = {hdr[3], hdr[2]};
            w2 = {hdr[5], hdr[4]};
            w3 = {hdr[7], hdr[6]};
            w4 = {hdr[9], hdr[8]};
            w5 = {hdr[11], hdr[10]};
            w6 = {hdr[13], hdr[12]};
            w7 = {hdr[15], hdr[14]};
            w8 = {hdr[17], hdr[16]};
            w9 = {hdr[18], nonce};

            pm = w0 ^ w1 ^ w2 ^ w3 ^ w4 ^ w5 ^ w6 ^ w7 ^ w8 ^ w9 ^ {epoch, epoch};

            w0 = w0 + pm;
            w1 = w1 ^ {pm[31:0], pm[63:32]};
            w2 = {w2[31:0], w2[63:32]} ^ pm;
            w3 = w3 + ({epoch, pm[31:0]} ^ w0);
            w4 = w4 ^ (pm + w1);
            w5 = w5 + (w2 ^ {32'd0, epoch});
            w6 = ((w6 << 17) | (w6 >> 47)) ^ pm;
            w7 = ((w7 >> 23) | (w7 << 41)) + w3;
            w8 = w8 ^ w4;
            w9 = w9 + w5;

            s = {w7 ^ w4, w5 ^ w0, w6 ^ w1, w9 ^ w8};
            build_initial_state = s;
        end
    endfunction

    function hash_meets_target;
        input [255:0] hash_state;
        begin
            hash_meets_target = (hash_state <= target);
        end
    endfunction

endmodule
