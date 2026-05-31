// -----------------------------------------------------------------------------
// Odocrypt Round Function (Hardware Architecture)
// - 256-bit state
// - 4 × 64-bit lanes
// - Nonlinear DSP layer
// - Add / xor / rotate / lane permutation
// - Epoch-dependent mutation
// -----------------------------------------------------------------------------
module odocrypt_round (
    input  wire [255:0] in_state,
    input  wire [31:0]  epoch,
    input  wire [63:0]  rc,
    input  wire [5:0]   rot,
    output wire [255:0] out_state
);

    // Split into 4 lanes
    wire [63:0] A = in_state[ 63:  0];
    wire [63:0] B = in_state[127: 64];
    wire [63:0] C = in_state[191:128];
    wire [63:0] D = in_state[255:192];

    // Nonlinear transformations
    wire [63:0] fB;
    wire [63:0] fD;

    odocrypt_sbox_dsp nlB (
        .x    (B),
        .rc   (rc),
        .epoch(epoch),
        .y    (fB)
    );

    odocrypt_sbox_dsp nlD (
        .x    (D),
        .rc   (rc),
        .epoch(epoch),
        .y    (fD)
    );

    // Round operations
    wire [63:0] round_key0 = rc ^ {epoch, epoch};
    wire [63:0] round_key1 = {rc[31:0], rc[63:32]} ^ {32'hF0F0F0F0, epoch};
    wire [63:0] round_key2 = rc + {epoch, epoch};
    wire [63:0] round_key3 = rc ^ {~epoch, epoch};

    wire [63:0] A1 = A + fB + round_key0;
    wire [63:0] B1 = B ^ (fD + round_key1);
    wire [63:0] C1 = C + ((A1 ^ round_key2) + {8'd0, epoch, 24'd0});
    wire [63:0] D1 = D ^ ((B1 + round_key3) ^ {epoch, epoch});

    wire [63:0] A2 = rotr64(A1 ^ C1, rot);
    wire [63:0] B2 = rotr64(B1 ^ D1, (rot + 6'd17) & 6'h3f);
    wire [63:0] C2 = rotr64(C1 + A1, (rot ^ 6'd13));
    wire [63:0] D2 = rotr64(D1 + B1, (rot + epoch[4:0]) & 6'h3f);

    // Lane permutation (fixed)
    assign out_state = {B2, D2, A2, C2};

    function [63:0] rotr64;
        input [63:0] x;
        input [5:0]  r;
        begin
            if (r == 6'd0)
                rotr64 = x;
            else
                rotr64 = (x >> r) | (x << (64 - r));
        end
    endfunction

endmodule
