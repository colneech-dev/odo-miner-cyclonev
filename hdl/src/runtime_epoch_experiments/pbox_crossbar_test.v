// Scratch experiment (feat/runtime-epoch-pipeline): cost of a runtime-
// configurable bit permutation, vs today's design where apply_pbox0/1 are
// emitted as FIXED WIRES (assign out[j] = in[k];, computed once at RTL-gen
// time from the epoch's mask/rotation values -- zero ALM cost today). Making
// this runtime-loadable means the hardware must support ANY permutation, not
// one fixed wiring.
//
// This is the WORST-CASE (full crossbar, N output muxes each N:1) version --
// structurally simple, low bug-risk, deliberately NOT the cheaper O(N log N)
// Benes-network construction. If even this naive worst case is affordable,
// great. If it's already too expensive, a cleverer network won't need
// evaluating -- the answer is already no.
//
// `sel` (the per-output-bit select, i.e. the "loaded epoch permutation")
// is driven internally from a free-running register, NOT a top-level input
// -- a real design would load it via the same write-distribution bus as the
// S-boxes, and exposing 640*6=3840 select bits as pins would blow the I/O
// pad budget. Internal + non-constant is enough to stop Quartus folding the
// muxes away; this measures the switching network itself.
module pbox_crossbar64(clk, in, sel, out);
    parameter WIDTH = 64;
    parameter SEL_BITS = 6; // ceil(log2(64))
    input clk;
    input [WIDTH-1:0] in;
    input [WIDTH*SEL_BITS-1:0] sel;
    output reg [WIDTH-1:0] out;

    integer i;
    always @(posedge clk) begin
        for (i = 0; i < WIDTH; i = i + 1)
            out[i] <= in[sel[i*SEL_BITS +: SEL_BITS]];
    end
endmodule

// 10 instances (STATE_SIZE words), real internal wiring via a counter,
// XOR-reduced output to dodge an I/O pad explosion. `sel` for each instance
// derived from a second free-running register (distinct constant step so it
// doesn't trivially correlate with `in`).
module pbox_crossbar_test_array(clk, reset_n, seed, out);
    parameter WIDTH = 64;
    parameter SEL_BITS = 6;
    input clk;
    input reset_n;
    input [31:0] seed;
    output [WIDTH-1:0] out;

    reg [31:0] ctr;
    always @(posedge clk or negedge reset_n)
        if (!reset_n) ctr <= seed;
        else ctr <= ctr + 32'hF4914F6D;

    reg [383:0] selreg; // 64*6 = 384 bits, enough for one word's sel; reused per instance with offset
    always @(posedge clk or negedge reset_n)
        if (!reset_n) selreg <= {seed, seed, seed, seed, seed, seed, seed, seed, seed, seed, seed, seed};
        else selreg <= {selreg[382:0], selreg[383] ^ ctr[0]};

    wire [WIDTH-1:0] w_out [0:9];
    genvar i;
    generate
        for (i = 0; i < 10; i = i + 1) begin : words
            pbox_crossbar64 #(.WIDTH(WIDTH), .SEL_BITS(SEL_BITS)) inst(
                .clk(clk),
                .in(ctr ^ {58'h0, i[5:0]}),
                .sel(selreg ^ {6{i[5:0], 58'h0}}),
                .out(w_out[i])
            );
        end
    endgenerate

    reg [WIDTH-1:0] out_r;
    integer j;
    always @(posedge clk) begin
        out_r = {WIDTH{1'b0}};
        for (j = 0; j < 10; j = j + 1) out_r = out_r ^ w_out[j];
    end
    assign out = out_r;
endmodule
