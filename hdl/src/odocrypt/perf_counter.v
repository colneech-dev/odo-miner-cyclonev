// -----------------------------------------------------------------------------
// Performance Counter Block
// - Counts hashes produced
// - Counts valid shares
// - Tracks active cycles (busy time)
// - Tracks idle cycles
// - 64-bit counters for long uptime
// -----------------------------------------------------------------------------
module perf_counter (
    input  wire        clk,
    input  wire        reset_n,

    input  wire        hash_valid,     // from compression pipeline
    input  wire        share_valid,    // from difficulty comparator
    input  wire        core_busy,      // from odocrypt_core

    output reg [63:0]  hash_count,
    output reg [63:0]  share_count,
    output reg [63:0]  busy_cycles,
    output reg [63:0]  idle_cycles
);

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            hash_count  <= 64'd0;
            share_count <= 64'd0;
            busy_cycles <= 64'd0;
            idle_cycles <= 64'd0;
        end else begin
            if (hash_valid)
                hash_count <= hash_count + 1;

            if (share_valid)
                share_count <= share_count + 1;

            if (core_busy)
                busy_cycles <= busy_cycles + 1;
            else
                idle_cycles <= idle_cycles + 1;
        end
    end

endmodule
