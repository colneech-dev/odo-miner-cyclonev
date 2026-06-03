// odocrypt_core.v — Sequential OdoCrypt hash engine
//
// Implements the real OdoCrypt hash per upstream odocrypt.cpp:
//   1. Unpack 80-byte header into 10 × 64-bit words (little-endian), inject nonce
//   2. PreMix: XOR all words, fold, XOR back
//   3. 84 rounds: Pbox0 → Sbox → Pbox1 → Rotations → RoundKey
//   4. Keccak-800 (12 rounds, 25-cycle latency) → 256-bit PoW hash
//   5. Compare hash ≤ target
//
// One hash takes: 1 (premix) + 84 (rounds) + 1 (kec feed) + 25 (kec wait) = 111 cycles.
// Multiple cores can be instantiated in odocrypt_array.v for higher throughput.
//
// Epoch tables are provided as flat packed input wires from odocrypt_epoch_tables.
// If tables_valid is low, the core will not start hashing.
//
// State encoding: 640 bits = word[9]..word[0], word[i] = state[64*i +: 64]

`define W(state, i) (state)[64*(i) +: 64]

module odocrypt_core (
    input  wire         clk,
    input  wire         reset_n,

    input  wire         start,
    input  wire [31:0]  nonce_start,
    input  wire [31:0]  nonce_end,
    input  wire [639:0] header_words,   // 20 x 32-bit words packed as single 640-bit value
    input  wire [255:0] target,
    input  wire [31:0]  epoch,         // kept for interface compat; tables supersede it

    // Epoch tables from odocrypt_epoch_tables
    input  wire [20479:0]  sbox1_flat,
    input  wire [163839:0] sbox2_flat,
    input  wire [38399:0]  pmask_flat,
    input  wire [299:0]    prot_flat,
    input  wire [35:0]     rot_flat,
    input  wire [839:0]    rk_flat,
    input  wire            tables_valid,

    output wire         busy,
    output reg          found,
    output reg  [31:0]  found_nonce,
    output reg  [255:0] hash_out,
    output reg          hash_valid
);

    // -------------------------------------------------------------------------
    // FSM states
    // -------------------------------------------------------------------------
    localparam ST_IDLE      = 3'd0;
    localparam ST_PREMIX    = 3'd1;
    localparam ST_ROUND     = 3'd2;
    localparam ST_KEC_FEED  = 3'd3;
    localparam ST_KEC_WAIT  = 3'd4;
    localparam ST_NEXT      = 3'd5;

    reg [2:0]  state;
    reg [31:0] nonce_cur;
    reg [639:0] hash_state;
    reg [6:0]  round_idx;
    reg [4:0]  kec_cnt;

    assign busy = (state != ST_IDLE);

    // -------------------------------------------------------------------------
    // Keccak-800 instance (WIDTH=640, THROUGHPUT=1, latency=25)
    // -------------------------------------------------------------------------
    reg          kec_read;
    wire [255:0] keccak_hash;
    wire         keccak_write;

    keccak_hasher #(.WIDTH(640), .THROUGHPUT(1)) keccak_inst (
        .clk   (clk),
        .in    (hash_state),
        .read  (kec_read),
        .out   (keccak_hash),
        .write (keccak_write)
    );

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
            // Word 9: bytes 72-75 = hdr[18], bytes 76-79 = nonce
            s[64*9 +: 64] = {nonce, hdr[18]};

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
    // Helper: apply masked swaps to adjacent pairs
    //   mask_flat[64*k +: 64] = mask for pair k
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
    //   Precomputed mapping: out[dest] = in[src]
    //   src→dest: 0→0,1→3,2→6,3→9,4→2,5→5,6→8,7→1,8→4,9→7
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
    // Helper: rotate even-indexed words
    //   rot_flat[6*k +: 6] = rotation amount for even word 2k
    // -------------------------------------------------------------------------
    function [639:0] pbox_rotations;
        input [639:0] s;
        input [29:0]  rot_flat;  // 5 × 6-bit
        integer fi;
        begin
            for (fi = 0; fi < 5; fi = fi + 1)
                s[64*(2*fi) +: 64] = rot64(s[64*(2*fi) +: 64], rot_flat[6*fi +: 6]);
            pbox_rotations = s;
        end
    endfunction

    // -------------------------------------------------------------------------
    // Helper: one Pbox application (6 subrounds)
    //   pmask_flat: 6 × 5 × 64-bit = 1920 bits  (subrounds × lanes × 64)
    //   prot_flat:  5 × 5 × 6-bit  = 150 bits   (5 subrounds with rotations × lanes)
    // -------------------------------------------------------------------------
    function [639:0] apply_pbox;
        input [639:0]  s;
        input [1919:0] pmask_flat;
        input [149:0]  prot_flat;
        integer fi;
        begin
            for (fi = 0; fi < 5; fi = fi + 1) begin
                s = masked_swaps(s, pmask_flat[320*fi +: 320]);
                s = word_shuffle(s);
                s = pbox_rotations(s, prot_flat[30*fi +: 30]);
            end
            // Final masked swap (subround 5, no rotation)
            s = masked_swaps(s, pmask_flat[320*5 +: 320]);
            apply_pbox = s;
        end
    endfunction

    // -------------------------------------------------------------------------
    // Helper: S-box substitution
    //   sbox1: 40 sboxes × 64 × 8-bit; index via sbox1_flat[8*(s*64+e) +: 8]
    //   sbox2: 10 sboxes × 1024 × 16-bit; index via sbox2_flat[16*(s*1024+e) +: 16]
    //   Per word: 4 iterations of (6-bit sbox1 + 10-bit sbox2)
    // -------------------------------------------------------------------------
    function [639:0] apply_sboxes;
        input [639:0]   s;
        input [20479:0] sb1;
        input [163839:0] sb2;
        reg [63:0] w, next_w;
        reg [5:0]  addr1;
        reg [9:0]  addr2;
        integer fw, fj, small_idx;
        begin
            small_idx = 0;
            for (fw = 0; fw < 10; fw = fw + 1) begin
                w      = s[64*fw +: 64];
                next_w = 64'd0;
                for (fj = 0; fj < 4; fj = fj + 1) begin
                    // 6-bit small sbox at bits [5:0] of current 16-bit chunk
                    addr1 = w[16*fj +: 6];
                    next_w[16*fj +: 6] = (sb1[8*(small_idx*64 + addr1) +: 8]) & 6'h3F;

                    // 10-bit large sbox at bits [15:6] of current 16-bit chunk
                    addr2 = w[16*fj+6 +: 10];
                    next_w[16*fj+6 +: 10] = (sb2[16*(fw*1024 + addr2) +: 16]) & 10'h3FF;

                    small_idx = small_idx + 1;
                end
                s[64*fw +: 64] = next_w;
            end
            apply_sboxes = s;
        end
    endfunction

    // -------------------------------------------------------------------------
    // Helper: apply rotations mixing step
    //   rotate array left by 1; each word ^= 6 rotations of the original word
    //   rot_flat[6*r +: 6] = rotation amount r
    // -------------------------------------------------------------------------
    function [639:0] apply_rotations;
        input [639:0] s;
        input [35:0]  rot_flat;
        reg [639:0] next_s;
        reg [63:0]  orig_w;
        integer fw, fr;
        begin
            // rotate array left by 1 position
            for (fw = 0; fw < 9; fw = fw + 1)
                next_s[64*fw +: 64] = s[64*(fw+1) +: 64];
            next_s[64*9 +: 64] = s[64*0 +: 64];

            // XOR each next_s[i] with 6 rotations of original s[i]
            for (fw = 0; fw < 10; fw = fw + 1) begin
                orig_w = s[64*fw +: 64];
                for (fr = 0; fr < 6; fr = fr + 1)
                    next_s[64*fw +: 64] = next_s[64*fw +: 64] ^ rot64(orig_w, rot_flat[6*fr +: 6]);
            end
            apply_rotations = next_s;
        end
    endfunction

    // -------------------------------------------------------------------------
    // Helper: apply round key (XOR state[i] with bit i of round_key)
    // -------------------------------------------------------------------------
    function [639:0] apply_round_key;
        input [639:0] s;
        input [9:0]   rk;
        integer fi;
        begin
            for (fi = 0; fi < 10; fi = fi + 1)
                s[64*fi +: 64] = s[64*fi +: 64] ^ {{63{1'b0}}, rk[fi]};
            apply_round_key = s;
        end
    endfunction

    // -------------------------------------------------------------------------
    // Full round: Pbox0 → Sbox → Pbox1 → Rotations → RoundKey
    //   pmask_flat layout: [0..1919]=pbox0 masks, [1920..3839]=pbox1 masks
    //   prot_flat  layout: [0..149]=pbox0 rots,   [150..299]=pbox1 rots
    // -------------------------------------------------------------------------
    function [639:0] apply_round;
        input [639:0]   s;
        input [9:0]     rk;
        input [20479:0] sb1;
        input [163839:0] sb2;
        input [38399:0] pmask_flat;
        input [299:0]   prot_flat;
        input [35:0]    rot_flat;
        begin
            s = apply_pbox(s, pmask_flat[1919:0],    prot_flat[149:0]);
            s = apply_sboxes(s, sb1, sb2);
            s = apply_pbox(s, pmask_flat[3839:1920],  prot_flat[299:150]);
            s = apply_rotations(s, rot_flat);
            s = apply_round_key(s, rk);
            apply_round = s;
        end
    endfunction

    // -------------------------------------------------------------------------
    // Sequential FSM
    // -------------------------------------------------------------------------
    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            state      <= ST_IDLE;
            nonce_cur  <= 32'd0;
            hash_state <= 640'd0;
            round_idx  <= 7'd0;
            kec_cnt    <= 5'd0;
            kec_read   <= 1'b0;
            found      <= 1'b0;
            found_nonce <= 32'd0;
            hash_out   <= 256'd0;
            hash_valid <= 1'b0;
        end else begin
            kec_read   <= 1'b0;
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
                    state      <= ST_ROUND;
                end

                ST_ROUND: begin
                    hash_state <= apply_round(
                        hash_state,
                        rk_flat[10*round_idx +: 10],
                        sbox1_flat, sbox2_flat,
                        pmask_flat, prot_flat, rot_flat
                    );
                    if (round_idx == 7'd83) begin
                        state <= ST_KEC_FEED;
                    end else begin
                        round_idx <= round_idx + 1;
                    end
                end

                ST_KEC_FEED: begin
                    kec_read <= 1'b1;          // feed odo_encrypt output to Keccak
                    kec_cnt  <= 5'd24;         // count down 24 more cycles (25 total)
                    state    <= ST_KEC_WAIT;
                end

                ST_KEC_WAIT: begin
                    if (kec_cnt == 5'd0) begin
                        state <= ST_NEXT;
                    end else begin
                        kec_cnt <= kec_cnt - 1;
                    end
                end

                ST_NEXT: begin
                    // keccak_write should be asserted this cycle
                    hash_out   <= keccak_hash;
                    hash_valid <= 1'b1;
                    if (!found && (keccak_hash <= target)) begin
                        found       <= 1'b1;
                        found_nonce <= nonce_cur;
                    end

                    if (nonce_cur == nonce_end || found) begin
                        state <= ST_IDLE;
                    end else begin
                        nonce_cur <= nonce_cur + 1;
                        state     <= ST_PREMIX;
                    end
                end

                default: state <= ST_IDLE;
            endcase
        end
    end

endmodule
