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
    input  wire [31:0]  header_words [0:23],

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

    // Pipeline registers for hash state
    reg [255:0] pipe_state   [0:PIPE_DEPTH];  // example width
    reg [31:0]  pipe_nonce   [0:PIPE_DEPTH];
    reg         pipe_valid   [0:PIPE_DEPTH];

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

            for (i = 0; i <= PIPE_DEPTH; i = i + 1) begin
                pipe_state[i] <= {256{1'b0}};
                pipe_nonce[i] <= 32'd0;
                pipe_valid[i] <= 1'b0;
            end
        end else begin
            state     <= state_next;
            nonce_cur <= nonce_next;

            // Shift pipeline
            for (i = PIPE_DEPTH; i > 0; i = i - 1) begin
                pipe_state[i] <= pipe_state[i-1];
                pipe_nonce[i] <= pipe_nonce[i-1];
                pipe_valid[i] <= pipe_valid[i-1];
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
        // found is latched when we hit a good nonce; cleared on new start

        case (state)
            ST_IDLE: begin
                if (start) begin
                    nonce_next = nonce_start;
                    state_next = ST_LOAD;
                end
            end

            ST_LOAD: begin
                // Load first nonce into pipeline input
                state_next = ST_RUN;
            end

            ST_RUN: begin
                // Keep feeding nonces until we reach end
                if (nonce_cur < nonce_end) begin
                    nonce_next = nonce_cur + 1;
                    state_next = ST_RUN;
                end else begin
                    state_next = ST_CHECK;
                end
            end

            ST_CHECK: begin
                // Wait for pipeline to drain and check last outputs
                // Once pipe_valid[PIPE_DEPTH] has been low for a while,
                // we can go to DONE. For now, just go straight to DONE.
                state_next = ST_DONE;
            end

            ST_DONE: begin
                if (!start) // wait for start to deassert
                    state_next = ST_IDLE;
            end

            default: state_next = ST_IDLE;
        endcase
    end

    // -------------------------------------------------------------------------
    // Pipeline input (stage 0)
    // -------------------------------------------------------------------------
    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            pipe_state[0] <= {256{1'b0}};
            pipe_nonce[0] <= 32'd0;
            pipe_valid[0] <= 1'b0;
            found         <= 1'b0;
            found_nonce   <= 32'd0;
        end else begin
            // Clear found on new start
            if (state == ST_IDLE && start) begin
                found       <= 1'b0;
                found_nonce <= 32'd0;
            end

            if (state == ST_LOAD || state == ST_RUN) begin
                // Build initial state from header + nonce
                pipe_state[0] <= build_initial_state(header_words, nonce_cur);
                pipe_nonce[0] <= nonce_cur;
                pipe_valid[0] <= 1'b1;
            end else begin
                pipe_valid[0] <= 1'b0;
            end

            // Check pipeline output for valid hash
            if (pipe_valid[PIPE_DEPTH]) begin
                if (hash_meets_target(pipe_state[PIPE_DEPTH])) begin
                    found       <= 1'b1;
                    found_nonce <= pipe_nonce[PIPE_DEPTH];
                end
            end
        end
    end

    // -------------------------------------------------------------------------
    // Round pipeline (stages 1..PIPE_DEPTH)
    // -------------------------------------------------------------------------
    genvar gi;
    generate
        for (gi = 1; gi <= PIPE_DEPTH; gi = gi + 1) begin : GEN_ROUNDS
            always @(posedge clk or negedge reset_n) begin
                if (!reset_n) begin
                    // already cleared in main reset loop
                end else if (pipe_valid[gi-1]) begin
                    pipe_state[gi] <= odocrypt_round(pipe_state[gi-1]);
                    pipe_nonce[gi] <= pipe_nonce[gi-1];
                    pipe_valid[gi] <= 1'b1;
                end else begin
                    pipe_valid[gi] <= 1'b0;
                end
            end
        end
    endgenerate

    // -------------------------------------------------------------------------
    // Functions: initial state, round, target check
    // -------------------------------------------------------------------------
    function [255:0] build_initial_state;
        input [31:0] hdr [0:23];
        input [31:0] nonce;
        reg   [255:0] s;
        integer k;
        begin
            // Simple placeholder: pack first 7 words + nonce
            s = {256{1'b0}};
            for (k = 0; k < 7; k = k + 1)
                s[k*32 +: 32] = hdr[k];
            s[7*32 +: 32] = nonce;
            build_initial_state = s;
        end
    endfunction

    function [255:0] odocrypt_round;
        input [255:0] in_state;
        reg   [255:0] out_state;
        begin
            // *** REPLACE THIS WITH REAL ODOCRYPT ROUND ***
            // Example: simple rotation + xor (placeholder)
            out_state = {in_state[126:0], in_state[255:127]} ^ 256'hA5A5_5A5A_A5A5_5A5A_A5A5_5A5A_A5A5_5A5A;
            odocrypt_round = out_state;
        end
    endfunction

    function hash_meets_target;
        input [255:0] hash_state;
        reg   [255:0] target;
        begin
            // *** REPLACE WITH REAL TARGET COMPARISON ***
            // Example: require top 16 bits to be zero
            target = 256'h0000_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF;
            hash_meets_target = (hash_state <= target);
        end
    endfunction

endmodule
