// -----------------------------------------------------------------------------
// Odocrypt core skeleton for Cyclone V (5CSXFC6C6U23)
// - Interface matches odocrypt_top
// - Single pipeline instance, one nonce at a time
// - FSM walks nonce range, asserts found + found_nonce on success
// - Replace ROUND function + COMPARE logic with real Odocrypt
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

    output reg          busy,
    output reg          found,
    output reg  [31:0]  found_nonce
);

    // -------------------------------------------------------------------------
    // Parameters / localparams
    // -------------------------------------------------------------------------
    localparam ST_IDLE   = 3'd0;
    localparam ST_LOAD   = 3'd1;
    localparam ST_RUN    = 3'd2;
    localparam ST_CHECK  = 3'd3;
    localparam ST_DONE   = 3'd4;

    // Pipeline depth (tune once you implement real rounds)
    localparam PIPE_DEPTH = 8;

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
            busy       <= 1'b0;
            found      <= 1'b0;
            found_nonce<= 32'd0;
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
                compress_in_state <= build_initial_state(header_words, nonce_cur);
                compress_in_valid <= 1'b1;
                pipe_nonce[0] <= nonce_cur;
                pipe_valid[0] <= 1'b1;
            end else begin
                compress_in_valid <= 1'b0;
                pipe_valid[0] <= 1'b0;
            end

            if (compress_out_valid && pipe_valid[PIPE_DEPTH]) begin
                if (!found && hash_meets_target(compress_out_state)) begin
                    found       <= 1'b1;
                    found_nonce <= pipe_nonce[PIPE_DEPTH];
                end
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
                if (!start)
                    state_next = ST_IDLE;
            end

            default: state_next = ST_IDLE;
        endcase
    end

    // -------------------------------------------------------------------------
    // Compressor instance for the OdoCrypt round pipeline.
    // -------------------------------------------------------------------------
    odocrypt_compress #(.ROUNDS(16)) compress_inst (
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
        reg   [255:0] s;
        integer k;
        begin
            s = {256{1'b0}};
            for (k = 0; k < 20; k = k + 1)
                s[k*32 +: 32] = hdr[k];
            s[7*32 +: 32] = nonce;
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
