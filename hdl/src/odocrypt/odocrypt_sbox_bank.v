// odocrypt_sbox_bank.v
//
// Per-core S-box block-RAM bank for the multi-core OdoCrypt engine.
//
// The OdoCrypt epoch tables split into two parts with very different cost:
//   - FF tables (pmask/prot/rot/rk): ~3.8k ALMs of registers, IDENTICAL for
//     every core in a given epoch.  These stay in odocrypt_epoch_tables and
//     are broadcast (one copy) to all cores.
//   - S-box RAMs: pure M10K block RAM (~0 ALMs), but each core needs its own
//     read ports every cycle, so the storage must be duplicated per core.
//
// This module is that duplicated storage.  It contains only the 40 small +
// 10 large S-box RAMs and their read ports.  The write strobes (sb1_we,
// sb1_wsel, ...) and the bank-select registers (active_bank/load_bank) are
// driven by the single shared odocrypt_epoch_tables instance, which owns the
// write pointer and unpacker FSM.  Every bank receives the identical write
// stream and therefore holds identical S-box contents — exactly what the old
// monolithic two-table design produced, but without paying for two copies of
// the FF tables.
//
// All RAM-inference pragmas and the separate-always-block read/write idiom are
// carried over verbatim from odocrypt_epoch_tables; see the comments there for
// why they are load-bearing (cross-port RDW ordering forces register inference
// instead of M10K if violated).

module odocrypt_sbox_bank (
    input  wire        clk,

    // Shared write interface from odocrypt_epoch_tables (epoch load only;
    // the core is held in reset while these are active, so the loader write
    // port never collides with a core read).
    input  wire        active_bank,
    input  wire        load_bank,

    input  wire        sb1_we,
    input  wire [5:0]  sb1_wsel,    // which small sbox (0..39)
    input  wire [6:0]  sb1_wentry,  // entry index within small sbox (0..63)
    input  wire [5:0]  sb1_wdata,

    input  wire        sb2_we,
    input  wire [3:0]  sb2_wsel,    // which large sbox (0..9)
    input  wire [10:0] sb2_wentry,  // entry index within large sbox (0..1023)
    input  wire [9:0]  sb2_wdata,

    // Small S-box read ports (40 × 6-bit), 1-cycle latency
    input  wire [239:0] sb1_addr,
    output wire [239:0] sb1_q,

    // Large S-box read ports (10 × 10-bit, two ports), 1-cycle latency
    input  wire [99:0]  sb2_addr_a,
    input  wire [99:0]  sb2_addr_b,
    output wire [99:0]  sb2_q_a,
    output wire [99:0]  sb2_q_b
);

    genvar gi;

    // -------------------------------------------------------------------------
    // Small S-box RAMs: 40 × (2 banks × 64 entries × 6 bit)
    // Simple dual port: 1 write (loader), 1 read (core). Inferred MLAB/M10K.
    // -------------------------------------------------------------------------
    generate
        for (gi = 0; gi < 40; gi = gi + 1) begin : sb1_ram
            // The write and the read MUST live in separate always blocks:
            // an unconditional read in the write block implies strict
            // old-data read-during-write ordering, which the RAM hardware
            // cannot honor — Quartus then silently implements the array as
            // ~770 registers + a 128:1 read mux (≈510 ALMs) per S-box.
            // Cross-port RDW never actually occurs here (the core is held
            // in reset during table loads), so no_rw_check is safe.
            (* ramstyle = "M10K, no_rw_check" *) reg [5:0] mem [0:127];
            reg [5:0] q;
            wire we = sb1_we && (sb1_wsel == gi);
            always @(posedge clk) begin
                if (we)
                    mem[{load_bank, sb1_wentry[5:0]}] <= sb1_wdata;
            end
            always @(posedge clk) begin
                q <= mem[{active_bank, sb1_addr[6*gi +: 6]}];
            end
            assign sb1_q[6*gi +: 6] = q;
        end
    endgenerate

    // -------------------------------------------------------------------------
    // Large S-box RAMs: 10 × (2 banks × 1024 entries × 10 bit)
    // True dual port: port A = loader write / core read a, port B = core read b.
    // While loading, the core is held in reset, so port A never collides.
    // -------------------------------------------------------------------------
    generate
        for (gi = 0; gi < 10; gi = gi + 1) begin : sb2_ram
            reg [9:0] mem [0:2047];
            reg [9:0] q_a, q_b;
            wire we = sb2_we && (sb2_wsel == gi);
            wire [10:0] addr_a = we ? {load_bank, sb2_wentry[9:0]}
                                    : {active_bank, sb2_addr_a[10*gi +: 10]};
            always @(posedge clk) begin
                if (we)
                    mem[addr_a] <= sb2_wdata;
                else
                    q_a <= mem[addr_a];
            end
            always @(posedge clk) begin
                q_b <= mem[{active_bank, sb2_addr_b[10*gi +: 10]}];
            end
            assign sb2_q_a[10*gi +: 10] = q_a;
            assign sb2_q_b[10*gi +: 10] = q_b;
        end
    endgenerate

endmodule
