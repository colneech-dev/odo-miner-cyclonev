// tb_pipelined_miner.v — functional gate for the pipelined Avalon wrapper (P1.2).
//
// Drives header/target into pipelined_miner_top over Avalon (two clock domains:
// a slow Avalon clk + a fast miner_clk), commits, then waits for the free-running
// core to report a found nonce and checks it equals the oracle's first-qualifying
// nonce (gen_vectors_pipe). Proves header packing + CDC + hash + readback.
//
// Requires +HEADER/+TARGET/+EXPECT plusargs and -DTHROUGHPUT -DODOKEY.

`timescale 1ns/1ps

module tb_pipelined_miner;
    reg clk = 0;        // Avalon fabric clock
    reg miner_clk = 0;  // 150 MHz pipeline clock
    reg reset_n = 0;

    always #10 clk = ~clk;        // 50 MHz
    always #3  miner_clk = ~miner_clk; // ~167 MHz (fast domain, exercises CDC)

    reg  [7:0]  avs_address = 0;
    reg         avs_read = 0;
    reg         avs_write = 0;
    reg  [31:0] avs_writedata = 0;
    wire [31:0] avs_readdata;
    wire        avs_waitrequest;

    pipelined_miner_top dut (
        .clk(clk), .reset_n(reset_n), .miner_clk(miner_clk),
        .avs_address(avs_address), .avs_read(avs_read), .avs_write(avs_write),
        .avs_writedata(avs_writedata), .avs_readdata(avs_readdata),
        .avs_waitrequest(avs_waitrequest)
    );

    // register map (mirror of hps_regs_pipe.h)
    localparam ADDR_STATUS  = 8'h04;
    localparam ADDR_SEED    = 8'h0C;
    localparam ADDR_TARGET  = 8'h20;
    localparam ADDR_HEADER  = 8'h40;
    localparam ADDR_COMMIT  = 8'h8C;
    localparam ADDR_FNONCE  = 8'h90;
    localparam ADDR_FSTATUS = 8'h94;

    reg [31:0] header_mem [0:18];
    reg [31:0] target_mem [0:7];

    integer i;
    reg [31:0] rdata, found_nonce;
    reg [1023:0] hfile, tfile;

    task avs_wr(input [7:0] addr, input [31:0] data);
        begin
            @(posedge clk); #1;
            avs_address = addr; avs_writedata = data; avs_write = 1;
            @(posedge clk); #1;
            avs_write = 0;
        end
    endtask

    // combinational readdata; pulse avs_read for one clk (consumes on FNONCE)
    task avs_rd(input [7:0] addr, output [31:0] data);
        begin
            @(posedge clk); #1;
            avs_address = addr; avs_read = 1; #1;
            data = avs_readdata;
            @(posedge clk); #1;
            avs_read = 0;
        end
    endtask

    integer polls;
    initial begin
        if (!$value$plusargs("HEADER=%s", hfile)) begin $display("no +HEADER"); $finish; end
        if (!$value$plusargs("TARGET=%s", tfile)) begin $display("no +TARGET"); $finish; end
        $readmemh(hfile, header_mem);
        $readmemh(tfile, target_mem);

        // reset
        reset_n = 0;
        repeat (4) @(posedge clk);
        reset_n = 1;
        repeat (2) @(posedge clk);

        // sanity: SEED register == ODOKEY (bitstream epoch)
        avs_rd(ADDR_SEED, rdata);
        $display("SEED reg = 0x%08x (expect 0x%08x)", rdata, `ODOKEY);

        // load header (19), target (8)
        for (i = 0; i < 19; i = i + 1) avs_wr(ADDR_HEADER + i*4, header_mem[i]);
        for (i = 0; i < 8;  i = i + 1) avs_wr(ADDR_TARGET + i*4, target_mem[i]);
        // commit -> snapshot into miner domain
        avs_wr(ADDR_COMMIT, 32'h1);

        // poll for a find
        rdata = 0; polls = 0;
        while ((rdata[0] !== 1'b1) && (polls < 200000)) begin
            avs_rd(ADDR_FSTATUS, rdata);
            polls = polls + 1;
        end

        if (rdata[0] !== 1'b1) begin
            $display("TB_FAIL: no nonce found within timeout (%0d polls)", polls);
            $finish;
        end

        avs_rd(ADDR_FNONCE, found_nonce);  // read-to-consume
        $display("FOUND_NONCE=%08x  (after %0d polls)", found_nonce, polls);
        $display("TB_FOUND");  // run script verifies the nonce via the oracle
        $finish;
    end

    // global timeout guard
    initial begin
        #20000000;  // 20 ms sim time
        $display("TB_FAIL: global timeout");
        $finish;
    end
endmodule
