// -----------------------------------------------------------------------------
// Difficulty Comparator (256-bit)
// - Compares hash <= target
// - Fully combinational
// - Cyclone V friendly (LUT-based)
// -----------------------------------------------------------------------------
module difficulty_compare (
    input  wire [255:0] hash,
    input  wire [255:0] target,
    output wire         valid
);

    // Compare MSB-first (big-endian)
    assign valid = (hash <= target);

endmodule
