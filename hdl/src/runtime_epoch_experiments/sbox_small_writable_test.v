// Scratch experiment (feat/runtime-epoch-pipeline), revision 2: the first
// pass used VIRTUAL_PIN to dodge the I/O pad limit, but that inflated the
// ALM count (612/2148 ALMs were flagged as virtual-pin routing artifacts,
// not real logic). This version XOR-reduces all 64 instances down to a
// single real output pin so the fitter only needs a handful of genuine I/O,
// giving an uninflated ALM count for 64 real, internally-wired instances.
module sbox_small_writable_test(clk, in, out, wr_addr, wr_data, wr_en);
    input clk;
    input [5:0] in;
    output reg [5:0] out;
    input [5:0] wr_addr;
    input [5:0] wr_data;
    input wr_en;

    (* ramstyle = "MLAB" *) reg [5:0] mem[0:63];

    always @(posedge clk) begin
        if (wr_en) mem[wr_addr] <= wr_data;
        out <= mem[in];
    end
endmodule

// 64 instances, each fed a distinct slice of a free-running counter (so
// the synthesizer can't constant-fold/optimize them away), outputs
// XOR-reduced to one small bus -- real internal wiring, minimal I/O.
module sbox_small_writable_test_array(clk, reset_n, seed, wr_addr, wr_data, wr_en, out);
    input clk;
    input reset_n;
    input [31:0] seed;
    input [5:0] wr_addr;
    input [5:0] wr_data;
    input [63:0] wr_en;
    output [5:0] out;

    reg [31:0] ctr;
    always @(posedge clk or negedge reset_n)
        if (!reset_n) ctr <= seed;
        else ctr <= ctr + 32'h2545F4914F6CDD1D;

    wire [5:0] sbox_out [0:63];
    genvar i;
    generate
        for (i = 0; i < 64; i = i + 1) begin : sboxes
            sbox_small_writable_test inst(
                .clk(clk),
                .in(ctr[(i%27)+5:(i%27)] ^ i[5:0]),
                .out(sbox_out[i]),
                .wr_addr(wr_addr),
                .wr_data(wr_data ^ i[5:0]),
                .wr_en(wr_en[i])
            );
        end
    endgenerate

    reg [5:0] out_r;
    integer j;
    always @(posedge clk) begin
        out_r = 6'h0;
        for (j = 0; j < 64; j = j + 1) out_r = out_r ^ sbox_out[j];
    end
    assign out = out_r;
endmodule
