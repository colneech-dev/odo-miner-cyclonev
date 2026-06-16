// odocrypt_core.v — Sequential OdoCrypt hash engine (BRAM S-box edition)
//
// Implements the real OdoCrypt hash per upstream odocrypt.cpp:
//   1. Unpack 80-byte header into 10 × 64-bit words (little-endian), inject nonce
//   2. PreMix: XOR all words, fold, XOR back
//   3. 84 rounds: Pbox0 → Sbox → Pbox1 → Rotations → RoundKey
//   4. Keccak-800 (12 rounds) → 256-bit PoW hash. The Keccak unit is SHARED:
//      it lives in odocrypt_top and is arbitrated between cores (each core
//      needs it <1% of the time), reached via the kec_req/kec_result handshake.
//   5. Compare hash ≤ target (both little-endian uint256)
//
// The S-boxes live in block RAM inside odocrypt_epoch_tables and are read
// through synchronous ports (1-cycle latency):
//   - 40 small S-boxes, one port each: all 40 lookups issue in one cycle.
//   - 10 large S-boxes, two ports each: a word's 4 large lookups take 2
//     address cycles (chunks 0/1 then 2/3).
//
// Cycle budget per round:
//   Pbox0: 6 (one subround per cycle)
//   Sbox : 3 (address, capture 0/1 + address 2/3, capture 2/3)
//   Pbox1: 6
//   Mix  : 4 (rotate-copy init, then TWO global rotations per cycle ×3;
//             round key applied on the last cycle). Two banks of 10 barrel
//             rotators — the 6 mix rotations are independent, so doubling the
//             lanes halves the step count (was one bank ×6 cycles).
//   = 19 cycles/round; one hash ≈ 1 + 84*19 + ~58 (keccak, THROUGHPUT=12)
//   ≈ 1655 cycles ≈ 33 KH/s/core at 55 MHz. Raise the clock for more.
//
// State encoding: 640 bits = word[9]..word[0], word[i] = state[64*i +: 64]

module odocrypt_core (
    input  wire         clk,
    input  wire         reset_n,

    input  wire         start,
    input  wire [31:0]  nonce_start,
    input  wire [31:0]  nonce_end,
    input  wire [639:0] header_words,   // 20 x 32-bit words packed
    input  wire [255:0] target,
    input  wire [31:0]  epoch,          // informational; tables supersede it

    // Epoch table interface (odocrypt_epoch_tables)
    output wire [239:0] sb1_addr,      // 40 × 6-bit small S-box addresses
    input  wire [239:0] sb1_q,         // 40 × 6-bit results (1-cycle latency)
    output wire [99:0]  sb2_addr_a,    // 10 × 10-bit large S-box addresses
    output wire [99:0]  sb2_addr_b,
    input  wire [99:0]  sb2_q_a,
    input  wire [99:0]  sb2_q_b,
    input  wire [38399:0] pmask_flat,
    input  wire [299:0]   prot_flat,
    input  wire [35:0]    rot_flat,
    input  wire [839:0]   rk_flat,
    input  wire           tables_valid,

    // Shared Keccak interface. The Keccak-800 unit lives in odocrypt_top and is
    // arbitrated between cores (it runs <1% of the time per core). This core
    // presents its final odo_encrypt state and raises kec_req; the arbiter
    // returns the 256-bit PoW hash on kec_result with kec_result_valid pulsed.
    output wire         kec_req,         // request the shared Keccak (held until result)
    output wire [639:0] kec_in,          // = final odo_encrypt state to hash
    input  wire [255:0] kec_result,      // 256-bit hash from shared Keccak
    input  wire         kec_result_valid,// pulsed for this core when its hash is ready

    output wire         busy,
    output reg          found,
    output reg  [31:0]  found_nonce,
    output reg  [255:0] hash_out,
    output reg          hash_valid
);

    // -------------------------------------------------------------------------
    // FSM states
    // -------------------------------------------------------------------------
    localparam ST_IDLE     = 4'd0;
    localparam ST_PREMIX   = 4'd1;
    localparam ST_PBOX     = 4'd2;   // 6 subrounds of pbox[pb_sel]
    localparam ST_SB_ADDR  = 4'd3;
    localparam ST_SB_CAP1  = 4'd4;
    localparam ST_SB_CAP2  = 4'd5;
    localparam ST_MIX_INIT = 4'd6;
    localparam ST_MIX      = 4'd7;
    localparam ST_KEC_REQ  = 4'd8;   // raise kec_req to the shared Keccak arbiter
    localparam ST_KEC_WAIT = 4'd9;   // wait for kec_result_valid from the arbiter

    reg [3:0]   state;
    reg [31:0]  nonce_cur;
    reg [639:0] hash_state;
    reg [639:0] sbox_acc;     // assembled S-box output (small + large c0/c1)
    reg [639:0] mix_acc;      // rotation-mix accumulator
    reg [6:0]   round_idx;
    reg         pb_sel;       // 0 = pbox0, 1 = pbox1
    reg [2:0]   pb_sub;       // pbox subround 0..5
    reg [2:0]   mix_cnt;      // global rotation index, steps 0 -> 2 -> 4 (two/cycle)

    assign busy = (state != ST_IDLE);

    // -------------------------------------------------------------------------
    // Shared Keccak handshake. The Keccak-800 unit no longer lives here — one
    // shared instance in odocrypt_top serves both cores (it is busy <1% of the
    // time per core, so the duplicate ~1.8k-ALM units were pure waste). We
    // present the final state on kec_in and hold kec_req until the arbiter
    // returns the hash on kec_result with kec_result_valid pulsed.
    // -------------------------------------------------------------------------
    reg          kec_req_r;
    assign kec_req = kec_req_r;
    assign kec_in  = hash_state;

    // -------------------------------------------------------------------------
    // S-box address generation (combinational from hash_state)
    //   word w, chunk j: small sbox (4w+j) gets bits [16j   +: 6 ]
    //                    large sbox  w     gets bits [16j+6 +: 10]
    //   Large ports: chunks 0/1 during ST_SB_ADDR, chunks 2/3 during ST_SB_CAP1.
    // -------------------------------------------------------------------------
    genvar gw, gj;
    generate
        for (gw = 0; gw < 10; gw = gw + 1) begin : addr_gen
            for (gj = 0; gj < 4; gj = gj + 1) begin : chunk_gen
                assign sb1_addr[6*(4*gw+gj) +: 6] = hash_state[64*gw + 16*gj +: 6];
            end
            assign sb2_addr_a[10*gw +: 10] = (state == ST_SB_CAP1)
                ? hash_state[64*gw + 16*2 + 6 +: 10]   // chunk 2
                : hash_state[64*gw +          6 +: 10]; // chunk 0
            assign sb2_addr_b[10*gw +: 10] = (state == ST_SB_CAP1)
                ? hash_state[64*gw + 16*3 + 6 +: 10]   // chunk 3
                : hash_state[64*gw + 16   + 6 +: 10];  // chunk 1
        end
    endgenerate

    // -------------------------------------------------------------------------
    // Helper: unpack 80-byte header + inject nonce → 10 × 64-bit words (LE)
    // PreMix: total = XOR all words; total ^= total>>32; each word ^= total
    // -------------------------------------------------------------------------
    function [639:0] premix_state;
        input [639:0] hdr;  // 20 x 32-bit words packed
        input [31:0] nonce;
        reg [639:0] s;
        reg [63:0] total;
        integer fi;
        begin
            // Unpack: word[i] = {hdr[2i+1], hdr[2i]} little-endian
            for (fi = 0; fi < 9; fi = fi + 1)
                s[64*fi +: 64] = {hdr[32*(2*fi+1) +: 32], hdr[32*(2*fi) +: 32]};
            // Word 9: bytes 72-75 = header word 18, bytes 76-79 = nonce
            s[64*9 +: 64] = {nonce, hdr[32*18 +: 32]};

            // PreMix
            total = 64'd0;
            for (fi = 0; fi < 10; fi = fi + 1)
                total = total ^ s[64*fi +: 64];
            total = total ^ (total >> 32);
            for (fi = 0; fi < 10; fi = fi + 1)
                s[64*fi +: 64] = s[64*fi +: 64] ^ total;

            premix_state = s;
        end
    endfunction

    // -------------------------------------------------------------------------
    // Helper: barrel rotate left 64-bit
    // -------------------------------------------------------------------------
    function [63:0] rot64;
        input [63:0] x;
        input [5:0]  r;
        begin
            rot64 = (r == 0) ? x : ((x << r) | (x >> (64 - r)));
        end
    endfunction

    // -------------------------------------------------------------------------
    // Helper: masked swaps on adjacent pairs (one pbox subround component)
    // -------------------------------------------------------------------------
    function [639:0] masked_swaps;
        input [639:0] s;
        input [319:0] mask_flat;  // 5 × 64-bit
        reg [63:0] a, b, swp;
        integer fi;
        begin
            for (fi = 0; fi < 5; fi = fi + 1) begin
                a   = s[64*(2*fi)   +: 64];
                b   = s[64*(2*fi+1) +: 64];
                swp = mask_flat[64*fi +: 64] & (a ^ b);
                s[64*(2*fi)   +: 64] = a ^ swp;
                s[64*(2*fi+1) +: 64] = b ^ swp;
            end
            masked_swaps = s;
        end
    endfunction

    // -------------------------------------------------------------------------
    // Helper: word shuffle with stride 3 (PBOX_M=3, STATE_SIZE=10)
    //   out[3*i % 10] = in[i]
    // -------------------------------------------------------------------------
    function [639:0] word_shuffle;
        input [639:0] s;
        reg [639:0] t;
        begin
            t[64*0 +: 64] = s[64*0 +: 64];
            t[64*3 +: 64] = s[64*1 +: 64];
            t[64*6 +: 64] = s[64*2 +: 64];
            t[64*9 +: 64] = s[64*3 +: 64];
            t[64*2 +: 64] = s[64*4 +: 64];
            t[64*5 +: 64] = s[64*5 +: 64];
            t[64*8 +: 64] = s[64*6 +: 64];
            t[64*1 +: 64] = s[64*7 +: 64];
            t[64*4 +: 64] = s[64*8 +: 64];
            t[64*7 +: 64] = s[64*9 +: 64];
            word_shuffle = t;
        end
    endfunction

    // -------------------------------------------------------------------------
    // Helper: rotate even-indexed words (pbox subround rotation step)
    // -------------------------------------------------------------------------
    function [639:0] pbox_rotations;
        input [639:0] s;
        input [29:0]  rots;  // 5 × 6-bit
        integer fi;
        begin
            for (fi = 0; fi < 5; fi = fi + 1)
                s[64*(2*fi) +: 64] = rot64(s[64*(2*fi) +: 64], rots[6*fi +: 6]);
            pbox_rotations = s;
        end
    endfunction

    // -------------------------------------------------------------------------
    // One pbox subround. Subrounds 0..4: swap → shuffle → rotate.
    // Subround 5: final masked swap only.
    //   pmask_flat layout: 320 bits per (pbox, subround), pbox0 then pbox1
    //   prot_flat  layout: 30 bits per (pbox, subround 0..4)
    // -------------------------------------------------------------------------
    function [639:0] pbox_subround;
        input [639:0] s;
        input         sel;       // which pbox
        input [2:0]   sub;       // subround 0..5
        reg [319:0] mask;
        reg [29:0]  rots;
        begin
            mask = pmask_flat[320*({3'd0, sel}*6 + {1'b0, sub}) +: 320];
            if (sub == 3'd5) begin
                pbox_subround = masked_swaps(s, mask);
            end else begin
                rots = prot_flat[30*({3'd0, sel}*5 + {1'b0, sub}) +: 30];
                pbox_subround = pbox_rotations(word_shuffle(masked_swaps(s, mask)), rots);
            end
        end
    endfunction

    // -------------------------------------------------------------------------
    // Rotation-mix helpers. The 6 mix rotations all read the SAME post-pbox
    // state and XOR into the accumulator, so they are independent and parallel.
    // We do TWO per cycle (two banks of 10 barrel rotators, was one bank ×6
    // cycles): 6 steps → 3 cycles. Width-not-depth (one extra XOR level), so
    // Fmax is unaffected; the cost is the second rotator bank.
    //   init : acc = state array rotated left by one position
    //   step : acc[w] ^= rot64(state[w], rot[mix_cnt]) ^ rot64(state[w], rot[mix_cnt+1])
    // -------------------------------------------------------------------------
    function [639:0] mix_init;
        input [639:0] s;
        integer fw;
        begin
            for (fw = 0; fw < 9; fw = fw + 1)
                mix_init[64*fw +: 64] = s[64*(fw+1) +: 64];
            mix_init[64*9 +: 64] = s[64*0 +: 64];
        end
    endfunction

    function [639:0] mix_step2;
        input [639:0] acc;
        input [639:0] s;
        input [5:0]   r_a;
        input [5:0]   r_b;
        integer fw;
        begin
            for (fw = 0; fw < 10; fw = fw + 1)
                mix_step2[64*fw +: 64] = acc[64*fw +: 64]
                                       ^ rot64(s[64*fw +: 64], r_a)
                                       ^ rot64(s[64*fw +: 64], r_b);
        end
    endfunction

    // -------------------------------------------------------------------------
    // Helper: apply round key (XOR state[i] LSB with bit i of round_key)
    // -------------------------------------------------------------------------
    function [639:0] apply_round_key;
        input [639:0] s;
        input [9:0]   rk;
        integer fi;
        begin
            for (fi = 0; fi < 10; fi = fi + 1)
                s[64*fi] = s[64*fi] ^ rk[fi];
            apply_round_key = s;
        end
    endfunction

    // -------------------------------------------------------------------------
    // S-box capture merge: final state from acc + large chunks 2/3
    // -------------------------------------------------------------------------
    function [639:0] merge_sbox_final;
        input [639:0] acc;
        input [99:0]  qa;   // large chunk 2 per word
        input [99:0]  qb;   // large chunk 3 per word
        integer fw;
        begin
            merge_sbox_final = acc;
            for (fw = 0; fw < 10; fw = fw + 1) begin
                merge_sbox_final[64*fw + 16*2 + 6 +: 10] = qa[10*fw +: 10];
                merge_sbox_final[64*fw + 16*3 + 6 +: 10] = qb[10*fw +: 10];
            end
        end
    endfunction

    // -------------------------------------------------------------------------
    // Shared datapaths (continuous, so each exists exactly once regardless of
    // how many FSM branches consume them)
    // -------------------------------------------------------------------------
    wire [639:0] mix_stepped = mix_step2(mix_acc, hash_state,
                                         rot_flat[6*mix_cnt        +: 6],
                                         rot_flat[6*(mix_cnt+3'd1) +: 6]);
    wire [639:0] pbox_next   = pbox_subround(hash_state, pb_sel, pb_sub);

    // -------------------------------------------------------------------------
    // Sequential FSM
    // -------------------------------------------------------------------------
    integer w, j;

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            state       <= ST_IDLE;
            nonce_cur   <= 32'd0;
            hash_state  <= 640'd0;
            sbox_acc    <= 640'd0;
            mix_acc     <= 640'd0;
            round_idx   <= 7'd0;
            pb_sel      <= 1'b0;
            pb_sub      <= 3'd0;
            mix_cnt     <= 3'd0;
            kec_req_r   <= 1'b0;
            found       <= 1'b0;
            found_nonce <= 32'd0;
            hash_out    <= 256'd0;
            hash_valid  <= 1'b0;
        end else begin
            hash_valid <= 1'b0;

            case (state)
                ST_IDLE: begin
                    if (start && tables_valid) begin
                        nonce_cur <= nonce_start;
                        found     <= 1'b0;
                        state     <= ST_PREMIX;
                    end
                end

                ST_PREMIX: begin
                    hash_state <= premix_state(header_words, nonce_cur);
                    round_idx  <= 7'd0;
                    pb_sel     <= 1'b0;
                    pb_sub     <= 3'd0;
                    state      <= ST_PBOX;
                end

                ST_PBOX: begin
                    hash_state <= pbox_next;
                    if (pb_sub == 3'd5) begin
                        pb_sub <= 3'd0;
                        state  <= pb_sel ? ST_MIX_INIT : ST_SB_ADDR;
                    end else begin
                        pb_sub <= pb_sub + 3'd1;
                    end
                end

                ST_SB_ADDR: begin
                    // Addresses for small (all) and large chunks 0/1 are on
                    // the RAM ports this cycle; results register at the edge.
                    state <= ST_SB_CAP1;
                end

                ST_SB_CAP1: begin
                    // Capture small results and large chunks 0/1.
                    // Large chunk 2/3 addresses are on the ports this cycle.
                    for (w = 0; w < 10; w = w + 1) begin
                        for (j = 0; j < 4; j = j + 1)
                            sbox_acc[64*w + 16*j +: 6] <= sb1_q[6*(4*w+j) +: 6];
                        sbox_acc[64*w +        6 +: 10] <= sb2_q_a[10*w +: 10];
                        sbox_acc[64*w + 16   + 6 +: 10] <= sb2_q_b[10*w +: 10];
                    end
                    state <= ST_SB_CAP2;
                end

                ST_SB_CAP2: begin
                    // Merge large chunks 2/3 and move on to pbox1
                    hash_state <= merge_sbox_final(sbox_acc, sb2_q_a, sb2_q_b);
                    pb_sel     <= 1'b1;
                    pb_sub     <= 3'd0;
                    state      <= ST_PBOX;
                end

                ST_MIX_INIT: begin
                    mix_acc <= mix_init(hash_state);
                    mix_cnt <= 3'd0;
                    state   <= ST_MIX;
                end

                ST_MIX: begin
                    // Two rotations per cycle: mix_cnt steps 0 -> 2 -> 4.
                    if (mix_cnt == 3'd4) begin
                        // last rotation pair (4,5) + round key, commit the round
                        hash_state <= apply_round_key(mix_stepped,
                                                      rk_flat[10*round_idx +: 10]);
                        pb_sel <= 1'b0;
                        pb_sub <= 3'd0;
                        if (round_idx == 7'd83) begin
                            state <= ST_KEC_REQ;
                        end else begin
                            round_idx <= round_idx + 7'd1;
                            state     <= ST_PBOX;
                        end
                    end else begin
                        mix_acc <= mix_stepped;
                        mix_cnt <= mix_cnt + 3'd2;
                    end
                end

                ST_KEC_REQ: begin
                    // Raise the request; hold it until the arbiter answers.
                    // hash_state holds the final odo_encrypt output (kec_in).
                    kec_req_r <= 1'b1;
                    state     <= ST_KEC_WAIT;
                end

                ST_KEC_WAIT: begin
                    // The arbiter pulses kec_result_valid for exactly one cycle
                    // with kec_result valid; capture and compare in that cycle,
                    // then drop the request.
                    if (kec_result_valid) begin
                        kec_req_r  <= 1'b0;
                        hash_out   <= kec_result;
                        hash_valid <= 1'b1;
                        if (!found && (kec_result <= target)) begin
                            found       <= 1'b1;
                            found_nonce <= nonce_cur;
                            state       <= ST_IDLE;   // stop on first find
                        end else if (nonce_cur == nonce_end) begin
                            state <= ST_IDLE;         // range exhausted
                        end else begin
                            nonce_cur <= nonce_cur + 32'd1;
                            state     <= ST_PREMIX;
                        end
                    end
                end

                default: state <= ST_IDLE;
            endcase
        end
    end

endmodule
