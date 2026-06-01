// -----------------------------------------------------------------------------
// DSP-Accelerated Nonlinear Layer for Odocrypt Round
// - Uses Cyclone V DSP blocks for nonlinear mixing
// - 64-bit lane input, 64-bit lane output
// - Drop-in replacement for sbox_layer()
// -----------------------------------------------------------------------------
module odocrypt_sbox_dsp (
    input  wire [63:0] x,
    input  wire [63:0] rc,
    input  wire [31:0] epoch,
    output wire [63:0] y
);

    // -------------------------------------------------------------------------
    // 1. Epoch-dependent tweak (acts like a key schedule)
    // -------------------------------------------------------------------------
    wire [63:0] tweak = {epoch, epoch} ^ rc;

    // -------------------------------------------------------------------------
    // 2. DSP nonlinear mixing
    //    Build a compact nonlinear function that uses a rotation and two DSP multiplies.
    // -------------------------------------------------------------------------
    wire [63:0] rot = {x[47:0], x[63:48]};  // 16-bit rotate

    // DSP-friendly constants
    localparam [63:0] C1 = 64'h1F123BB5A7C4D921;
    localparam [63:0] C2 = 64'h9E3779B97F4A7C15;

    wire [63:0] mul1 = x[31:0]  * C1[31:0];
    wire [63:0] mul2 = rot[31:0] * C2[31:0];
    wire [63:0] mixed = mul1 ^ mul2 ^ tweak;
    wire [63:0] swapped = {mixed[31:0], mixed[63:32]};
    wire [63:0] rotated = (mixed << 13) | (mixed >> 51);

    // -------------------------------------------------------------------------
    // 3. Combine nonlinear outputs
    // -------------------------------------------------------------------------
    assign y = rotated ^ swapped ^ x ^ tweak;

endmodule
