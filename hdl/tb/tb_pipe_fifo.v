// tb_pipe_fifo.v — focused regression for the found-handoff async FIFO in
// pipelined_miner_top (the depth-8 dual-clock FIFO + producer strobe added in
// the 2026-06-28 review-hardening pass).
//
// The real `miner` core is slow (full OdoCrypt+Keccak), so this TB compiles a
// STUB `miner` (same port list, selected by leaving odo_miner_core.v out of the
// fileset) that emits a controllable burst of `found` strobes with incrementing
// nonce values. That lets us prove the FIFO behaviour the bit-exact regression
// (run_tb_pipe.sh, single find) can't reach:
//   T1  buffers a burst of >1 finds and drops nothing below full,
//   T2  drops finds + latches the sticky overflow flag (STATUS bit3) when full,
//       keeping the OLDEST 8 (drop-newest backpressure),
//   T5  irq is a LEVEL held across the whole drain, falling on the read that
//       empties the FIFO.
//
// Requires -DODOKEY (read back at SEED; value irrelevant here). No commit is
// issued, so settle_cnt stays 0 and finds flow immediately.

`timescale 1ns/1ps

// ---- stub core: emits `BURST` finds, one every 8 clks, nonce = 0xA0000001.. ----
module miner(clk, header, target, nonce, found);
    parameter INONCE = 0;
    input  clk;
    input  [607:0] header;
    input  [255:0] target;
    output reg [31:0] nonce;
    output reg        found;

    integer    cnt;     // finds still to emit (poked by the TB)
    reg [31:0] nval;    // next nonce value to emit
    reg        run;     // TB sets to start the burst
    reg [3:0]  div;     // 1 find every 8 clks
    initial begin nonce = 0; found = 0; cnt = 0; nval = 32'hA0000001; run = 0; div = 0; end

    always @(posedge clk) begin
        found <= 1'b0;                 // default: one-cycle pulse
        if (run && cnt > 0) begin
            if (div == 4'd7) begin
                div   <= 0;
                nonce <= nval;
                found <= 1'b1;
                nval  <= nval + 1;
                cnt   <= cnt - 1;
            end else begin
                div <= div + 1;
            end
        end
    end
endmodule

module tb_pipe_fifo;
    reg clk = 0, miner_clk = 0, reset_n = 0;
    always #10 clk = ~clk;             // 50 MHz Avalon
    always #3  miner_clk = ~miner_clk; // ~167 MHz miner (exercises CDC)

    reg  [7:0]  avs_address = 0;
    reg         avs_read = 0, avs_write = 0;
    reg  [31:0] avs_writedata = 0;
    wire [31:0] avs_readdata;
    wire        avs_waitrequest;
    wire        irq;

    pipelined_miner_top dut (
        .clk(clk), .reset_n(reset_n), .miner_clk(miner_clk),
        .miner_pll_locked(1'b1),   // sim has no real PLL; tie locked so pll_ok reads 1
        .avs_address(avs_address), .avs_read(avs_read), .avs_write(avs_write),
        .avs_writedata(avs_writedata), .avs_readdata(avs_readdata),
        .avs_waitrequest(avs_waitrequest), .irq(irq)
    );

    localparam ADDR_STATUS  = 8'h04;
    localparam ADDR_FNONCE  = 8'h90;
    localparam ADDR_FSTATUS = 8'h94;

    reg [31:0] rdata, v;
    integer    k, errors;

    task avs_rd(input [7:0] addr, output [31:0] data);
        begin
            @(posedge clk); #1;
            avs_address = addr; avs_read = 1; #1;
            data = avs_readdata;
            @(posedge clk); #1;
            avs_read = 0;
        end
    endtask

    initial begin
        errors = 0;
        reset_n = 0;
        repeat (4) @(posedge clk);
        reset_n = 1;
        repeat (2) @(posedge clk);

        if (irq !== 1'b0) begin $display("TB_FAIL: irq high before any find"); errors=errors+1; end

        // Emit 12 finds into a depth-8 FIFO, draining nothing -> 8 buffered,
        // 4 dropped, overflow sticky set, oldest 8 kept (A0000001..A0000008).
        dut.u_miner.cnt = 12;
        dut.u_miner.run = 1;

        // Let all 12 finds emit (12*8 miner_clk ~ 576 ns) and CDC-settle.
        #2000;
        dut.u_miner.run = 0;

        // T2: not empty + overflow latched.
        avs_rd(ADDR_STATUS, rdata);
        if (rdata[2] !== 1'b0) begin
            $display("TB_FAIL: STATUS.empty set but FIFO should hold finds (0x%08x)", rdata);
            errors = errors + 1;
        end
        if (rdata[3] !== 1'b1) begin
            $display("TB_FAIL: STATUS.overflow not latched after 12 finds into depth-8 (0x%08x)", rdata);
            errors = errors + 1;
        end
        // T5: irq is a level, held while finds are pending.
        if (irq !== 1'b1) begin $display("TB_FAIL: irq not held high with finds pending"); errors=errors+1; end

        // T1: drain the 8 buffered finds; expect the OLDEST 8 in FIFO order.
        for (k = 0; k < 8; k = k + 1) begin
            avs_rd(ADDR_FSTATUS, rdata);
            if (rdata[0] !== 1'b1) begin
                $display("TB_FAIL: FSTATUS empty at drain %0d (expected 8 entries)", k);
                errors = errors + 1;
            end
            avs_rd(ADDR_FNONCE, v);
            if (v !== (32'hA0000001 + k)) begin
                $display("TB_FAIL: drain %0d got 0x%08x expected 0x%08x", k, v, 32'hA0000001 + k);
                errors = errors + 1;
            end
        end

        // After draining 8, FIFO empty: FSTATUS clear, STATUS.empty set, irq low.
        avs_rd(ADDR_FSTATUS, rdata);
        if (rdata[0] !== 1'b0) begin $display("TB_FAIL: FIFO not empty after draining 8"); errors=errors+1; end
        avs_rd(ADDR_STATUS, rdata);
        if (rdata[2] !== 1'b1) begin $display("TB_FAIL: STATUS.empty not set after drain (0x%08x)", rdata); errors=errors+1; end
        if (irq !== 1'b0) begin $display("TB_FAIL: irq still high after draining FIFO"); errors=errors+1; end

        if (errors == 0) $display("TB_FIFO_PASS: burst buffered (8), overflow latched, drained in order, irq level OK");
        else             $display("TB_FIFO_FAIL: %0d error(s)", errors);
        $finish;
    end

    initial begin
        #5000000;
        $display("TB_FIFO_FAIL: global timeout");
        $finish;
    end
endmodule
