// odo_miner_core.v — trimmed from upstream odo-miner src/verilog/miner.v
// (cmp_256 + odo_keccak + miner only; JTAG miner_top + CRC pad_nonce removed
//  for Avalon integration). Upstream (C) 2019 MentalCollatz, GPLv3.
//
module cmp_256(clk, in, read, target, out, write);
    input clk;
    input [255:0] in;
    input read;
    input [255:0] target;
    output reg out;
    output reg write;
    
    reg [15:0] greater, less;
    reg progress;
    initial progress = 0;
    initial write = 0;
    
    genvar i;
    generate
    for (i = 0; i < 16; i = i+1)
    begin : loop
        always @(posedge clk)
        begin
            greater[i] <= (in[16*i+15:16*i] > target[16*i+15:16*i]);
            less[i] <= (in[16*i+15:16*i] < target[16*i+15:16*i]);
        end
    end
    endgenerate
    
    always @(posedge clk)
    begin
        out <= (greater < less);
        progress <= read;
        write <= progress;
    end
endmodule

module odo_keccak(clk, in, read, target, out, write);
    input clk;
    input [639:0] in;
    input read;
    input [255:0] target;
    output out;
    output write;

    wire [639:0] midstate;
    wire midread;
    wire [255:0] pow_hash;
    wire has_hash;
    
    odo_encrypt crypt(clk, in, read, midstate, midread);
    keccak_hasher #(640, `THROUGHPUT) hash(clk, midstate, midread, pow_hash, has_hash);
    cmp_256 compare(clk, pow_hash, has_hash, target, out, write);
endmodule

module miner(clk, header, target, nonce, found);
    parameter INONCE = 0; // for testing

    input clk;
    input [607:0] header;
    input [255:0] target;
    output reg [31:0] nonce;
    // 1-cycle strobe, asserted on the same edge `nonce` latches a qualifying
    // nonce. Lets the wrapper push EVERY find exactly once into the FIFO instead
    // of inferring finds from a change in `nonce` (which loses a find whenever a
    // new winner equals the value already latched, or when the FIFO is full).
    output reg found;

    reg [31:0] nonce_in;
    reg [31:0] nonce_out;
    initial nonce_in = INONCE;
    initial nonce_out = INONCE;

    reg [6:0] counter;
    reg advance;
    initial counter = `THROUGHPUT-1;
    initial advance = 0;
    initial found = 0;

    wire res;
    wire has_res;

    odo_keccak worker(clk, {nonce_in, header}, advance, target, res, has_res);

    always @(posedge clk)
    begin
        if (counter == `THROUGHPUT-1)
        begin
            counter <= 0;
            advance <= 1;
        end
        else
        begin
            counter <= counter + 1;
            advance <= 0;
        end
        if (advance)
            nonce_in <= nonce_in + 1;
        found <= 1'b0;            // default: one-cycle pulse
        if (has_res)
        begin
            if (res)
            begin
                nonce <= nonce_out;
                found <= 1'b1;   // qualifying nonce latched this edge
            end
            nonce_out <= nonce_out + 1;
        end
    end
endmodule
