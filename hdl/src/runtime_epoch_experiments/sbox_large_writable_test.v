// Scratch experiment (feat/runtime-epoch-pipeline), revision 3: drop the
// ping-pong doubled-depth bank (revision 2 measured 4 M10K/instance, ~2x
// today's per-instance cost -- would push the real design to ~79.6% M10K).
// The doubling exists in odocrypt_sbox_bank.v specifically so epoch loads
// can happen in the BACKGROUND while still mining (zero downtime). We don't
// need that property -- epoch transitions are rare (1-10 days apart) and a
// brief mining pause during the load (a few seconds to stream ~6000 words)
// is trivially acceptable next to today's multi-minute recompile+reboot
// cycle. Single-depth array (matches today's M10K footprint exactly), port A
// time-multiplexed between loader-write and core-read (mining is paused
// during the load, so these never collide), port B a pure read port.
module sbox_large_writable_test(
    clk, a_in, b_in, a_out, b_out,
    wr_addr, wr_data, wr_en
);
    input clk;
    input [9:0] a_in, b_in;
    output reg [9:0] a_out, b_out;
    input [9:0] wr_addr;
    input [9:0] wr_data;
    input wr_en;

    reg [9:0] mem [0:1023];
    wire [9:0] addr_a = wr_en ? wr_addr : a_in;

    always @(posedge clk) begin
        if (wr_en)
            mem[addr_a] <= wr_data;
        else
            a_out <= mem[addr_a];
    end
    always @(posedge clk) begin
        b_out <= mem[b_in];
    end
endmodule

// 10 instances (LARGE_SBOX_COUNT), one physical "round slot" worth -- real
// internal wiring via a counter, XOR-reduced output to dodge an I/O pad
// explosion (same trick as the other tests).
module sbox_large_writable_test_array(clk, reset_n, seed, wr_addr, wr_data, wr_en, out);
    input clk;
    input reset_n;
    input [31:0] seed;
    input [9:0] wr_addr;
    input [9:0] wr_data;
    input [9:0] wr_en;
    output [9:0] out;

    reg [31:0] ctr;
    always @(posedge clk or negedge reset_n)
        if (!reset_n) ctr <= seed;
        else ctr <= ctr + 32'hF4914F6D;

    wire [9:0] a_out [0:9];
    wire [9:0] b_out [0:9];
    genvar i;
    generate
        for (i = 0; i < 10; i = i + 1) begin : sboxes
            sbox_large_writable_test inst(
                .clk(clk),
                .a_in(ctr[(i%21)+9:(i%21)] ^ {6'h0, i[3:0]}),
                .b_in(~ctr[(i%19)+9:(i%19)] ^ {6'h0, i[3:0]}),
                .a_out(a_out[i]), .b_out(b_out[i]),
                .wr_addr(wr_addr),
                .wr_data(wr_data ^ {6'h0, i[3:0]}),
                .wr_en(wr_en[i])
            );
        end
    endgenerate

    reg [9:0] out_r;
    integer j;
    always @(posedge clk) begin
        out_r = 10'h0;
        for (j = 0; j < 10; j = j + 1) out_r = out_r ^ a_out[j] ^ b_out[j];
    end
    assign out = out_r;
endmodule
