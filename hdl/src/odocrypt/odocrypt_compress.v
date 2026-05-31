// -----------------------------------------------------------------------------
// Odocrypt Compression Pipeline (Multi-Round, Fully Pipelined)
// - Parameterised number of rounds (R)
// - One round per pipeline stage
// - New input every cycle, one output every cycle after fill
// - Designed for Cyclone V 5CSXFC6C6U23 timing
// -----------------------------------------------------------------------------
module odocrypt_compress #(
    parameter ROUNDS = 16
)(
    input  wire         clk,
    input  wire         reset_n,

    input  wire [255:0] in_state,
    input  wire [31:0]  epoch,
    input  wire         in_valid,

    output wire [255:0] out_state,
    output wire         out_valid
);

    // -------------------------------------------------------------------------
    // Pipeline registers
    // -------------------------------------------------------------------------
    reg [255:0] stage_state [0:ROUNDS];
    reg [31:0]  stage_epoch [0:ROUNDS];
    reg         stage_valid [0:ROUNDS];

    integer i;

    // -------------------------------------------------------------------------
    // Stage 0 input
    // -------------------------------------------------------------------------
    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            stage_state[0] <= 256'd0;
            stage_epoch[0] <= 32'd0;
            stage_valid[0] <= 1'b0;
        end else begin
            stage_state[0] <= in_state;
            stage_epoch[0] <= epoch;
            stage_valid[0] <= in_valid;
        end
    end

    // -------------------------------------------------------------------------
    // Round pipeline
    // -------------------------------------------------------------------------
    genvar gi;
    generate
        for (gi = 1; gi <= ROUNDS; gi = gi + 1) begin : GEN_ROUND_PIPE
            wire [255:0] round_out;

            odocrypt_round round_inst (
                .in_state (stage_state[gi-1]),
                .epoch    (stage_epoch[gi-1]),
                .out_state(round_out)
            );

            always @(posedge clk or negedge reset_n) begin
                if (!reset_n) begin
                    stage_state[gi] <= 256'd0;
                    stage_epoch[gi] <= 32'd0;
                    stage_valid[gi] <= 1'b0;
                end else begin
                    stage_state[gi] <= round_out;
                    stage_epoch[gi] <= stage_epoch[gi-1];
                    stage_valid[gi] <= stage_valid[gi-1];
                end
            end
        end
    endgenerate

    // -------------------------------------------------------------------------
    // Output
    // -------------------------------------------------------------------------
    assign out_state = stage_state[ROUNDS];
    assign out_valid = stage_valid[ROUNDS];

endmodule
