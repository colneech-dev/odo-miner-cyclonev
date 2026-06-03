// -----------------------------------------------------------------------------
// OdoCrypt epoch mutator
// Generates per-round constants and rotation amounts from a 32-bit epoch.
// -----------------------------------------------------------------------------
module odocrypt_epoch_mutator #(
    parameter ROUNDS = 84
)(
    input  wire [31:0] epoch,

    output reg [5375:0] round_const,  // 84 x 64-bit packed as 5376 bits
    output reg [503:0]  rot_amount    // 84 x 6-bit packed as 504 bits
);

    integer i;

    always @* begin
        reg [63:0] seed64;
        seed64 = {epoch, epoch[31:0]} ^ 64'h9E3779B97F4A7C15;
        for (i = 0; i < ROUNDS; i = i + 1) begin
            round_const[64*i +: 64] = seed64 ^ (64'hA5A5_A5A5_A5A5_A5A5 + i * 64'h3C6EF372FE94F82A);
            rot_amount[6*i +: 6]    = ((epoch[5:0] + i * 5) ^ (seed64[5:0] + i)) & 6'h3f;
        end
    end

endmodule
