// tb_odocrypt_top.v — known-answer testbench for the OdoCrypt miner block.
//
// Exercises the full register interface the HPS uses:
//   1. Stream the 5964-word epoch table image into EPOCH_WR_DATA
//      (honouring waitrequest), verify EPOCH_WR_ADDR, COMMIT,
//      verify STATUS.TABLES_VALID.
//   2. Write header/target/nonce range, START via CONTROL.
//   3. Pass A (target = 0): range [nonce, nonce] completes with no find;
//      HASH registers must equal the C-generated expected hash.
//   4. Pass B (target = all-ones): same nonce; STATUS.FOUND must latch and
//      NONCE_FOUND must equal the expected nonce. CLEAR_FOUND must clear it
//      without re-latching (regression for the found re-latch bug).
//
// Vector files (from hps/gen_vectors.c) are passed with plusargs:
//   +STREAM=<path> +HEADER=<path> +EXPECT=<path>
//
// Exit: prints "TB_PASS" and finishes with exit code 0 on success;
// prints "TB_FAIL ..." and finishes with code 1 otherwise.

`timescale 1ns/1ps

module tb_odocrypt_top;

    // ---------------------------------------------------------------------
    // Clock / reset
    // ---------------------------------------------------------------------
    reg clk = 1'b0;
    reg reset_n = 1'b0;
    always #5 clk = ~clk;   // 100 MHz sim clock (period irrelevant)

    // ---------------------------------------------------------------------
    // DUT
    // ---------------------------------------------------------------------
    reg  [7:0]   avs_address  = 8'h0;
    reg          avs_read     = 1'b0;
    reg          avs_write    = 1'b0;
    reg  [31:0]  avs_writedata = 32'h0;
    wire [31:0]  avs_readdata;
    wire         avs_waitrequest;

    odocrypt_top dut (
        .clk            (clk),
        .reset_n        (reset_n),
        .avs_address    (avs_address),
        .avs_read       (avs_read),
        .avs_write      (avs_write),
        .avs_writedata  (avs_writedata),
        .avs_readdata   (avs_readdata),
        .avs_waitrequest(avs_waitrequest)
    );

    // ---------------------------------------------------------------------
    // Register map constants (mirror hps/hps_regs.h)
    // ---------------------------------------------------------------------
    localparam REG_CONTROL       = 8'h00;
    localparam REG_STATUS        = 8'h04;
    localparam REG_EPOCH         = 8'h0C;
    localparam REG_NONCE_START   = 8'h10;
    localparam REG_NONCE_END     = 8'h14;
    localparam REG_NONCE_FOUND   = 8'h18;
    localparam REG_TARGET_BASE   = 8'h20;
    localparam REG_HEADER_BASE   = 8'h40;
    localparam REG_HASH_BASE     = 8'h90;
    localparam REG_EPOCH_WR_DATA = 8'hC0;
    localparam REG_EPOCH_WR_RST  = 8'hC4;
    localparam REG_EPOCH_COMMIT  = 8'hC8;
    localparam REG_EPOCH_WR_ADDR = 8'hCC;

    localparam CTRL_START       = 32'h1;
    localparam CTRL_RESET       = 32'h2;
    localparam CTRL_ENABLE      = 32'h4;
    localparam CTRL_CLEAR_FOUND = 32'h8;

    localparam STAT_BUSY         = 32'h01;
    localparam STAT_FOUND        = 32'h02;
    localparam STAT_TABLES_VALID = 32'h10;

    // ---------------------------------------------------------------------
    // Avalon access tasks
    // ---------------------------------------------------------------------
    task av_write(input [7:0] addr, input [31:0] data);
        begin
            @(negedge clk);
            avs_address   = addr;
            avs_writedata = data;
            avs_write     = 1'b1;
            @(posedge clk);
            while (avs_waitrequest) @(posedge clk);
            @(negedge clk);
            avs_write = 1'b0;
        end
    endtask

    task av_read(input [7:0] addr, output [31:0] data);
        begin
            @(negedge clk);
            avs_address = addr;
            avs_read    = 1'b1;
            @(posedge clk);
            while (avs_waitrequest) @(posedge clk);
            data = avs_readdata;
            @(negedge clk);
            avs_read = 1'b0;
        end
    endtask

    // ---------------------------------------------------------------------
    // Vector storage
    // ---------------------------------------------------------------------
    reg [31:0] stream_mem [0:5963];
    reg [31:0] header_mem [0:19];
    reg [31:0] expect_mem [0:8];     // [0] = nonce, [1..8] = expected hash

    reg [1023:0] f_stream, f_header, f_expect;

    integer i;
    integer errors;
    reg [31:0] rd;
    reg [31:0] nonce;

    // ---------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------
    task wait_idle(input integer max_cycles);
        integer n;
        begin
            n = 0;
            rd = STAT_BUSY;
            while ((rd & STAT_BUSY) && n < max_cycles) begin
                av_read(REG_STATUS, rd);
                n = n + 20;
            end
            if (rd & STAT_BUSY) begin
                $display("TB_FAIL: core still busy after %0d cycles", max_cycles);
                $finish_and_return(1);
            end
        end
    endtask

    task check_hash(input [127:0] label);
        begin
            for (i = 0; i < 8; i = i + 1) begin
                av_read(REG_HASH_BASE + i*4, rd);
                if (rd !== expect_mem[1 + i]) begin
                    $display("TB_FAIL: %0s hash word %0d = %08x, expected %08x",
                             label, i, rd, expect_mem[1 + i]);
                    errors = errors + 1;
                end
            end
        end
    endtask

    // ---------------------------------------------------------------------
    // Main sequence
    // ---------------------------------------------------------------------
    initial begin
        errors = 0;

        if (!$value$plusargs("STREAM=%s", f_stream)) f_stream = "stream.hex";
        if (!$value$plusargs("HEADER=%s", f_header)) f_header = "header.hex";
        if (!$value$plusargs("EXPECT=%s", f_expect)) f_expect = "expect.hex";

        $readmemh(f_stream, stream_mem);
        $readmemh(f_header, header_mem);
        $readmemh(f_expect, expect_mem);
        nonce = expect_mem[0];

        // Reset
        reset_n = 1'b0;
        repeat (5) @(posedge clk);
        reset_n = 1'b1;
        repeat (2) @(posedge clk);

        // -----------------------------------------------------------------
        // 1. Load epoch tables: reset pointer, stream, verify count, commit
        // -----------------------------------------------------------------
        av_write(REG_EPOCH_WR_RST, 32'h1);
        av_read(REG_EPOCH_WR_ADDR, rd);
        if (rd !== 32'd0) begin
            $display("TB_FAIL: WR_ADDR after reset = %0d, expected 0", rd);
            errors = errors + 1;
        end

        for (i = 0; i < 5964; i = i + 1)
            av_write(REG_EPOCH_WR_DATA, stream_mem[i]);

        av_read(REG_EPOCH_WR_ADDR, rd);
        if (rd !== 32'd5964) begin
            $display("TB_FAIL: WR_ADDR after stream = %0d, expected 5964", rd);
            errors = errors + 1;
        end

        av_write(REG_EPOCH_COMMIT, 32'h1);
        repeat (2) @(posedge clk);
        av_read(REG_STATUS, rd);
        if (!(rd & STAT_TABLES_VALID)) begin
            $display("TB_FAIL: TABLES_VALID not set after commit (status=%08x)", rd);
            errors = errors + 1;
        end

        // -----------------------------------------------------------------
        // 2. Program the job
        // -----------------------------------------------------------------
        for (i = 0; i < 20; i = i + 1)
            av_write(REG_HEADER_BASE + i*4, header_mem[i]);
        av_write(REG_NONCE_START, nonce);
        av_write(REG_NONCE_END,   nonce);

        // -----------------------------------------------------------------
        // 3. Pass A: impossible target — range completes, hash captured
        // -----------------------------------------------------------------
        for (i = 0; i < 8; i = i + 1)
            av_write(REG_TARGET_BASE + i*4, 32'h0);

        av_write(REG_CONTROL, CTRL_ENABLE | CTRL_START);
        // Core must go busy promptly
        av_read(REG_STATUS, rd);
        if (!(rd & STAT_BUSY)) begin
            $display("TB_FAIL: core not busy after START (status=%08x)", rd);
            errors = errors + 1;
        end

        wait_idle(40000);
        av_read(REG_STATUS, rd);
        if (rd & STAT_FOUND) begin
            $display("TB_FAIL: FOUND set with impossible target (status=%08x)", rd);
            errors = errors + 1;
        end
        check_hash("passA");

        // -----------------------------------------------------------------
        // 4. Pass B: always-met target — FOUND latches with correct nonce
        // -----------------------------------------------------------------
        av_write(REG_CONTROL, CTRL_RESET);
        av_write(REG_CONTROL, CTRL_CLEAR_FOUND);
        av_write(REG_CONTROL, 32'h0);
        for (i = 0; i < 8; i = i + 1)
            av_write(REG_TARGET_BASE + i*4, 32'hFFFFFFFF);

        av_write(REG_CONTROL, CTRL_ENABLE | CTRL_START);
        wait_idle(40000);

        av_read(REG_STATUS, rd);
        if (!(rd & STAT_FOUND)) begin
            $display("TB_FAIL: FOUND not set with always-met target (status=%08x)", rd);
            errors = errors + 1;
        end
        av_read(REG_NONCE_FOUND, rd);
        if (rd !== nonce) begin
            $display("TB_FAIL: NONCE_FOUND = %08x, expected %08x", rd, nonce);
            errors = errors + 1;
        end
        check_hash("passB");

        // CLEAR_FOUND must stick (regression: found re-latch after clear)
        av_write(REG_CONTROL, CTRL_CLEAR_FOUND);
        av_write(REG_CONTROL, 32'h0);
        repeat (5) @(posedge clk);
        av_read(REG_STATUS, rd);
        if (rd & STAT_FOUND) begin
            $display("TB_FAIL: FOUND re-latched after CLEAR_FOUND (status=%08x)", rd);
            errors = errors + 1;
        end

        // -----------------------------------------------------------------
        if (errors == 0) begin
            $display("TB_PASS");
            $finish;
        end else begin
            $display("TB_FAIL: %0d error(s)", errors);
            $finish_and_return(1);
        end
    end

    // Global watchdog
    initial begin
        #80_000_000;   // 80 ms of sim time
        $display("TB_FAIL: global timeout");
        $finish_and_return(1);
    end

endmodule
