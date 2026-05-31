// -----------------------------------------------------------------------------
// Nonce Scheduler for Multi-Core Odocrypt Miner
// - Generates continuous nonces for N cores
// - Each core gets a unique stream: base + core_index
// - Stride = number of cores
// - 64-bit counter prevents rollover issues
// - No gaps, no overlaps, no stalls
// -----------------------------------------------------------------------------
module nonce_scheduler #(
    parameter CORES = 4
)(
    input  wire        clk,
    input  wire        reset_n,
    input  wire        enable,        // asserted when a job is active

    output reg  [63:0] nonce_out   [0:CORES-1],
    output reg         nonce_valid [0:CORES-1]
);

    reg [63:0] global_nonce;

    integer i;

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            global_nonce <= 64'd0;
            for (i = 0; i < CORES; i = i + 1) begin
                nonce_out[i]   <= 64'd0;
                nonce_valid[i] <= 1'b0;
            end
        end else begin
            if (enable) begin
                // Assign one nonce per core per cycle
                for (i = 0; i < CORES; i = i + 1) begin
                    nonce_out[i]   <= global_nonce + i;
                    nonce_valid[i] <= 1'b1;
                end

                // Advance global counter by number of cores
                global_nonce <= global_nonce + CORES;
            end else begin
                for (i = 0; i < CORES; i = i + 1)
                    nonce_valid[i] <= 1'b0;
            end
        end
    end

endmodule
