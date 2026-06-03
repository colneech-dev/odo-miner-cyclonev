// Keccak-800 hash core — ported from upstream odo-miner
// Original copyright (C) 2019 MentalCollatz, GPL v3.
//
// Used as the PoW hash step after odo_encrypt:
//   odo_encrypt output (640 bits) → keccak_hasher → 256-bit PoW hash → target compare
//
// Parameters:
//   WIDTH      - input width in bits (640 for real OdoCrypt; 256 during RTL bring-up)
//   THROUGHPUT - clock cycles between new inputs (1 = one hash per cycle, max rate)
//
// Latency with THROUGHPUT=1: 25 clock cycles from read strobe to write strobe.

// ---------------------------------------------------------------------------
// Round-key LFSR: advances the 8-bit Keccak round key to the next round.
// ---------------------------------------------------------------------------
module keccak_next_round (
    input  wire [7:0] in,
    output wire [7:0] out
);
    assign out[0] = in[7];
    assign out[1] = in[0] ^ in[4] ^ in[5] ^ in[6];
    assign out[2] = in[1] ^ in[5] ^ in[6] ^ in[7];
    assign out[3] = in[0] ^ in[2] ^ in[4] ^ in[5] ^ in[7];
    assign out[4] = in[0] ^ in[1] ^ in[3] ^ in[4];
    assign out[5] = in[1] ^ in[2] ^ in[4] ^ in[5];
    assign out[6] = in[2] ^ in[3] ^ in[5] ^ in[6];
    assign out[7] = in[3] ^ in[4] ^ in[6] ^ in[7];
endmodule

// ---------------------------------------------------------------------------
// Round-key expansion: 8-bit key → 32-bit XOR mask applied to lane [0,0].
// ---------------------------------------------------------------------------
module keccak_key_expand (
    input  wire [7:0]  in,
    output wire [31:0] out
);
    assign out = {in[5], 15'b0, in[4], 7'b0, in[3], 3'b0, in[2], 1'b0, in[1], in[0]};
endmodule

// ---------------------------------------------------------------------------
// Index macros: Keccak-800 uses a 5×5 array of 32-bit lanes (800 bits total).
// IDX32(n) selects lane n as a 32-bit slice.
// LANE(x,y) gives the flat index of lane at position (x mod 5, y mod 5).
// ---------------------------------------------------------------------------
`define IDX32(x) ((x)*(32)) +: 32
`define LANE(x,y) (((x)%5)+5*((y)%5))

// ---------------------------------------------------------------------------
// Theta step: column-parity mixing.
// ---------------------------------------------------------------------------
module keccak_theta (
    input  wire [799:0] in,
    output wire [799:0] out
);
    wire [31:0] parity [4:0];

    genvar i;
    generate
        for (i = 0; i < 5; i = i+1) begin : parity_gen
            assign parity[i] = in[`IDX32(i)]    ^ in[`IDX32(i+5)]  ^
                               in[`IDX32(i+10)] ^ in[`IDX32(i+15)] ^
                               in[`IDX32(i+20)];
        end
    endgenerate

    generate
        for (i = 0; i < 25; i = i+1) begin : theta_gen
            wire [31:0] tmp = {parity[(i+1)%5][30:0], parity[(i+1)%5][31]};
            assign out[`IDX32(i)] = in[`IDX32(i)] ^ parity[(i+4)%5] ^ tmp;
        end
    endgenerate
endmodule

// ---------------------------------------------------------------------------
// Rho step: per-lane bit rotation (offsets hardcoded for Keccak-800 / 32-bit).
// ---------------------------------------------------------------------------
module keccak_rho (
    input  wire [799:0] in,
    output wire [799:0] out
);
    assign out = {
        in[785:768], in[799:786],
        in[743:736], in[767:744],
        in[706:704], in[735:707],
        in[701:672], in[703:702],
        in[653:640], in[671:654],
        in[631:608], in[639:632],
        in[586:576], in[607:587],
        in[560:544], in[575:561],
        in[530:512], in[543:531],
        in[502:480], in[511:503],
        in[472:448], in[479:473],
        in[422:416], in[447:423],
        in[404:384], in[415:405],
        in[373:352], in[383:374],
        in[348:320], in[351:349],
        in[299:288], in[319:300],
        in[264:256], in[287:265],
        in[249:224], in[255:250],
        in[211:192], in[223:212],
        in[187:160], in[191:188],
        in[132:128], in[159:133],
        in[99:96],   in[127:100],
        in[65:64],   in[95:66],
        in[62:32],   in[63:63],
        in[31:0]
    };
endmodule

// ---------------------------------------------------------------------------
// Pi step: lane transposition.
// ---------------------------------------------------------------------------
module keccak_pi (
    input  wire [799:0] in,
    output wire [799:0] out
);
    genvar x, y;
    generate
        for (x = 0; x < 5; x = x+1) begin : outer
            for (y = 0; y < 5; y = y+1) begin : inner
                assign out[`IDX32(`LANE(0*x+1*y, 2*x+3*y))] = in[`IDX32(`LANE(x, y))];
            end
        end
    endgenerate
endmodule

// ---------------------------------------------------------------------------
// Chi step: non-linear mixing within each row.
// ---------------------------------------------------------------------------
module keccak_chi (
    input  wire [799:0] in,
    output wire [799:0] out
);
    genvar i;
    generate
        for (i = 0; i < 25; i = i+1) begin : chi_gen
            localparam i1 = i - (i%5) + ((i+1)%5);
            localparam i2 = i - (i%5) + ((i+2)%5);
            assign out[`IDX32(i)] = in[`IDX32(i)] ^ ((~in[`IDX32(i1)]) & in[`IDX32(i2)]);
        end
    endgenerate
endmodule

// ---------------------------------------------------------------------------
// Iota step: XOR lane [0,0] with the expanded round key.
// ---------------------------------------------------------------------------
module keccak_iota (
    input  wire [799:0] in,
    input  wire [7:0]   roundkey,
    output wire [799:0] out
);
    wire [31:0] expanded;
    keccak_key_expand re (roundkey, expanded);
    assign out = {in[799:32], in[31:0] ^ expanded};
endmodule

// ---------------------------------------------------------------------------
// Pipeline register: holds state + round key for one cycle.
// ---------------------------------------------------------------------------
module keccak_buffer (
    input  wire         clk,
    input  wire [799:0] statein,
    input  wire [7:0]   keyin,
    output reg  [799:0] stateout,
    output reg  [7:0]   keyout
);
    always @(posedge clk) begin
        stateout <= statein;
        keyout   <= keyin;
    end
endmodule

// ---------------------------------------------------------------------------
// One complete Keccak round: theta → [buffer] → rho → pi → chi → iota.
// Two-cycle latency (buffer splits theta from the rest).
// Interface: 808-bit bundle = {8-bit roundkey, 800-bit state}.
// ---------------------------------------------------------------------------
module keccak_round (
    input  wire         clk,
    input  wire [807:0] in,
    output wire [807:0] out
);
    wire [799:0] mid [6:0];
    wire [7:0]   rkey [2:0];

    assign mid[0]  = in[799:0];
    assign rkey[0] = in[807:800];

    keccak_theta  theta  (mid[0], mid[1]);
    keccak_buffer buffer (clk, mid[1], rkey[0], mid[2], rkey[1]);
    keccak_rho    rho    (mid[2], mid[3]);
    keccak_pi     pi     (mid[3], mid[4]);
    keccak_chi    chi    (mid[4], mid[5]);
    keccak_iota   iota   (mid[5], rkey[1], mid[6]);
    keccak_next_round nr (rkey[1], rkey[2]);

    assign out = {rkey[2], mid[6]};
endmodule

// ---------------------------------------------------------------------------
// Padding: append Keccak multi-rate pad to WIDTH-bit input → 808-bit bundle.
// Initial round key 0x35 corresponds to 12 rounds of Keccak-800.
// ---------------------------------------------------------------------------
module keccak_padding #(parameter WIDTH = 640) (
    input  wire [WIDTH-1:0] in,
    output wire [807:0]     out
);
    assign out = {8'h35, {(799-WIDTH){1'b0}}, 1'b1, in};
endmodule

// ---------------------------------------------------------------------------
// Top-level hasher: fully pipelined, one result per THROUGHPUT clocks.
//
// Ports:
//   in    [WIDTH-1:0]  - input data (odo_encrypt output)
//   read               - strobe: assert for one cycle when 'in' is valid
//   out   [255:0]      - 256-bit hash result
//   write              - asserted for one cycle when 'out' is valid
//
// The 'write' pulse arrives exactly LATENCY clocks after the corresponding 'read'.
// ---------------------------------------------------------------------------
module keccak_hasher #(
    parameter WIDTH      = 640,
    parameter THROUGHPUT = 1
)(
    input  wire             clk,
    input  wire [WIDTH-1:0] in,
    input  wire             read,
    output reg  [255:0]     out,
    output wire             write
);
    localparam ROUNDS      = 12;
    localparam UNROLLING   = (ROUNDS - 1) / THROUGHPUT + 1;
    localparam EXTRA_DELAY =
        (THROUGHPUT == 3)  ? 2 :
        (THROUGHPUT == 10) ? 3 :
        (THROUGHPUT <  12) ? 1 :
        ((THROUGHPUT % 6) == 0) ? 3 :
        ((THROUGHPUT % 6) == 3) ? 2 : 1;
    localparam LATENCY = 2*ROUNDS + ((ROUNDS-1) / UNROLLING) * EXTRA_DELAY + 1;

    reg  [807:0] state [0:UNROLLING+EXTRA_DELAY-1];
    wire [807:0] nxt   [0:UNROLLING+EXTRA_DELAY-1];

    wire [807:0] padded;
    keccak_padding #(.WIDTH(WIDTH)) padder (in, padded);

    genvar i;
    generate
        for (i = 0; i < UNROLLING; i = i+1) begin : round_pipe
            keccak_round kr (clk, state[i], nxt[i]);
        end
        for (i = 0; i < EXTRA_DELAY; i = i+1) begin : delay_pipe
            assign nxt[i + UNROLLING] = state[i + UNROLLING];
        end
        for (i = 1; i < UNROLLING + EXTRA_DELAY; i = i+1) begin : shift_pipe
            always @(posedge clk)
                state[i] <= nxt[i-1];
        end
    endgenerate

    /* Valid shift register: tracks when a result is ready. */
    reg [LATENCY-1:0] progress;
    initial progress = {LATENCY{1'b0}};
    assign write = progress[LATENCY-1];

    generate
        for (i = 1; i < LATENCY; i = i+1) begin : valid_pipe
            always @(posedge clk)
                progress[i] <= progress[i-1];
        end
    endgenerate

    always @(posedge clk) begin
        if (THROUGHPUT == 1 || read)
            state[0] <= padded;
        else
            state[0] <= nxt[UNROLLING + EXTRA_DELAY - 1];

        progress[0] <= read;
        out <= nxt[(ROUNDS-1) % UNROLLING][255:0];
    end
endmodule
