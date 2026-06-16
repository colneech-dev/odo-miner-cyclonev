// odocrypt_top.v
// Avalon-MM slave wrapper for the Cyclone V SoC HPS-to-FPGA lightweight bridge.
// This module exposes a register interface compatible with hps/hps_regs.h.

module odocrypt_top (
    input  wire         clk,
    input  wire         reset_n,

    // Avalon-MM Lite slave interface
    input  wire [7:0]   avs_address,
    input  wire         avs_read,
    input  wire         avs_write,
    input  wire [31:0]  avs_writedata,
    output reg  [31:0]  avs_readdata,
    output wire         avs_waitrequest
);

    // -------------------------------------------------------------------------
    // Local register file
    // -------------------------------------------------------------------------
    reg [31:0] control_reg;
    reg [31:0] epoch_reg;
    reg [31:0] nonce_start_reg;
    reg [31:0] nonce_end_reg;
    reg [255:0] target_reg;  // 8 x 32-bit packed
    reg [639:0] header_reg;  // 20 x 32-bit words packed as 640 bits

    reg        found_latched;
    reg [1:0]  found_core_id;  // which core won (0/1/2), reported on ADDR_CORE_FOUND
    reg [31:0] found_nonce_reg;
    reg [255:0] hash_reg;  // 8 x 32-bit packed

    wire [255:0] target_256;
    wire [31:0] epoch_value;

    reg [31:0] perf_hashes_lo;
    reg [31:0] perf_hashes_hi;
    reg [31:0] perf_shares;
    reg [31:0] perf_uptime;

    wire [31:0] version_reg;

    // -------------------------------------------------------------------------
    // Control bit definitions
    // -------------------------------------------------------------------------
    localparam CTRL_START        = 1 << 0;
    localparam CTRL_RESET        = 1 << 1;
    localparam CTRL_ENABLE       = 1 << 2;
    localparam CTRL_CLEAR_FOUND  = 1 << 3;

    // Status bits
    localparam STAT_BUSY          = 1 << 0;
    localparam STAT_FOUND         = 1 << 1;
    localparam STAT_CORE_READY    = 1 << 2;
    localparam STAT_EPOCH_LOCK    = 1 << 3;
    localparam STAT_TABLES_VALID  = 1 << 4;

    // Avalon register addresses
    localparam ADDR_CONTROL        = 8'h00;
    localparam ADDR_STATUS         = 8'h04;
    localparam ADDR_VERSION        = 8'h08;
    localparam ADDR_EPOCH          = 8'h0C;
    localparam ADDR_NONCE_START    = 8'h10;
    localparam ADDR_NONCE_END      = 8'h14;
    localparam ADDR_NONCE_FOUND    = 8'h18;
    localparam ADDR_CORE_FOUND     = 8'h1C;
    localparam ADDR_TARGET_BASE    = 8'h20;
    localparam ADDR_HEADER_BASE    = 8'h40;
    localparam ADDR_HASH_BASE      = 8'h90;
    localparam ADDR_PERF_HASHES_LO = 8'hB0;
    localparam ADDR_PERF_HASHES_HI = 8'hB4;
    localparam ADDR_PERF_SHARES    = 8'hB8;
    localparam ADDR_PERF_UPTIME    = 8'hBC;
    // Epoch table streaming write registers
    localparam ADDR_EPOCH_WR_DATA  = 8'hC0;  // WO: write one word, auto-increments ptr
    localparam ADDR_EPOCH_WR_RESET = 8'hC4;  // WO: any write resets the write pointer to 0
    localparam ADDR_EPOCH_COMMIT   = 8'hC8;  // WO: any write commits loading → active buffer
    localparam ADDR_EPOCH_WR_ADDR  = 8'hCC;  // RO: current write address (debug)

    reg         start_latch;
    wire        core_start_pulse;
    wire        core_reset_n;
    wire        core_busy;
    wire        core_found;
    reg         core_found_d;
    wire [31:0] core_found_nonce;
    wire [255:0] core_hash;
    wire        core_hash_valid;

    wire        core1_busy;
    wire        core1_found;
    reg         core1_found_d;
    wire [31:0] core1_found_nonce;
    wire [255:0] core1_hash;
    wire        core1_hash_valid;

    wire        core2_busy;
    wire        core2_found;
    reg         core2_found_d;
    wire [31:0] core2_found_nonce;
    wire [255:0] core2_hash;
    wire        core2_hash_valid;

    // Shared Keccak handshake (one unit serves all three cores — arbiter below).
    wire         c0_kec_req,  c1_kec_req,  c2_kec_req;
    wire [639:0] c0_kec_in,   c1_kec_in,   c2_kec_in;
    wire         c0_kec_rvalid, c1_kec_rvalid, c2_kec_rvalid;
    wire [255:0] kec_result;            // shared 256-bit hash bus to all cores

    // Nonce range split into thirds: core0 [start, +t], core1 [+t, +2t],
    // core2 [+2t, end]. 1-nonce overlaps at the boundaries are harmless (the
    // found-latch picks the lowest-index core on ties).
    wire [31:0] nonce_third    = (nonce_end_reg - nonce_start_reg) / 3;
    wire [31:0] core0_nonce_end   = nonce_start_reg + nonce_third;
    wire [31:0] core1_nonce_start = core0_nonce_end;
    wire [31:0] core1_nonce_end   = nonce_start_reg + (nonce_third << 1);
    wire [31:0] core2_nonce_start = core1_nonce_end;

    // Shared FF tables (pmask/prot/rot/rk) broadcast from the single
    // odocrypt_epoch_tables instance to BOTH cores — they are identical for a
    // given epoch, so one copy saves ~3.8k ALMs versus the old two-table design.
    wire [38399:0] et_pmask;
    wire [299:0]   et_prot;
    wire [35:0]    et_rot;
    wire [839:0]   et_rk;
    wire           et_tables_valid;
    wire           et_wr_busy;

    // S-box write fan-out from the shared epoch_tables to each sbox_bank.
    wire           bank_active_bank, bank_load_bank;
    wire           bank_sb1_we;
    wire [5:0]     bank_sb1_wsel;
    wire [6:0]     bank_sb1_wentry;
    wire [5:0]     bank_sb1_wdata;
    wire           bank_sb2_we;
    wire [3:0]     bank_sb2_wsel;
    wire [10:0]    bank_sb2_wentry;
    wire [9:0]     bank_sb2_wdata;

    // Per-core S-box read ports (each core drives its own bank).
    wire [239:0]  et_sb1_addr, et_sb1_q;       // core 0 bank
    wire [99:0]   et_sb2_addr_a, et_sb2_addr_b, et_sb2_q_a, et_sb2_q_b;
    wire [239:0]  et1_sb1_addr, et1_sb1_q;      // core 1 bank
    wire [99:0]   et1_sb2_addr_a, et1_sb2_addr_b, et1_sb2_q_a, et1_sb2_q_b;
    wire [239:0]  et2_sb1_addr, et2_sb1_q;      // core 2 bank
    wire [99:0]   et2_sb2_addr_a, et2_sb2_addr_b, et2_sb2_q_a, et2_sb2_q_b;

    // Epoch table write strobes (combinatorial from Avalon write decode)
    reg  et_wr_en;
    reg  et_wr_reset;
    reg  et_commit;

    // Stall stream writes while the table loader is unpacking the previous
    // word (multi-entry S-box words take up to 4 cycles to store).
    assign avs_waitrequest = avs_write && (avs_address == ADDR_EPOCH_WR_DATA)
                                       && et_wr_busy;
    assign core_reset_n = reset_n & ~control_reg[1];
    assign epoch_value = epoch_reg;
    assign version_reg = 32'h0001_0000;  // Version 1.0
    assign target_256 = { target_reg[255:224], target_reg[223:192], target_reg[191:160], target_reg[159:128],
                         target_reg[127:96], target_reg[95:64], target_reg[63:32], target_reg[31:0] };

    // Latch the start request so it survives until either core is idle.
    // Clears once any core goes busy (both cores start simultaneously).
    always @(posedge clk or negedge reset_n) begin
        if (!reset_n)
            start_latch <= 1'b0;
        else if (avs_write && (avs_address == ADDR_CONTROL) &&
                 avs_writedata[0] && avs_writedata[2])
            start_latch <= 1'b1;
        else if (core_busy || core1_busy || core2_busy)
            start_latch <= 1'b0;
    end

    assign core_start_pulse = start_latch && !(core_busy || core1_busy || core2_busy);

    // -------------------------------------------------------------------------
    // Epoch table storage
    // -------------------------------------------------------------------------
    wire [12:0] et_wr_addr_out;

    // Single shared owner of the write stream + FF tables. Drives the S-box
    // write strobes out to both sbox_bank instances below.
    odocrypt_epoch_tables epoch_tables_inst (
        .clk              (clk),
        .reset_n          (reset_n),
        .wr_en            (et_wr_en),
        .wr_data          (avs_writedata),
        .wr_reset         (et_wr_reset),
        .commit           (et_commit),
        .wr_busy          (et_wr_busy),
        .bank_active_bank (bank_active_bank),
        .bank_load_bank   (bank_load_bank),
        .bank_sb1_we      (bank_sb1_we),
        .bank_sb1_wsel    (bank_sb1_wsel),
        .bank_sb1_wentry  (bank_sb1_wentry),
        .bank_sb1_wdata   (bank_sb1_wdata),
        .bank_sb2_we      (bank_sb2_we),
        .bank_sb2_wsel    (bank_sb2_wsel),
        .bank_sb2_wentry  (bank_sb2_wentry),
        .bank_sb2_wdata   (bank_sb2_wdata),
        .pmask_out        (et_pmask),
        .prot_out         (et_prot),
        .rot_out          (et_rot),
        .rk_out           (et_rk),
        .tables_valid     (et_tables_valid),
        .wr_addr_out      (et_wr_addr_out)
    );

    // Per-core S-box block-RAM banks. Both receive the identical write stream
    // (lockstep with the shared write pointer) so they hold identical S-boxes;
    // each serves its own core's read ports. ~0 ALMs each (pure M10K).
    odocrypt_sbox_bank sbox_bank0 (
        .clk          (clk),
        .active_bank  (bank_active_bank),
        .load_bank    (bank_load_bank),
        .sb1_we       (bank_sb1_we),
        .sb1_wsel     (bank_sb1_wsel),
        .sb1_wentry   (bank_sb1_wentry),
        .sb1_wdata    (bank_sb1_wdata),
        .sb2_we       (bank_sb2_we),
        .sb2_wsel     (bank_sb2_wsel),
        .sb2_wentry   (bank_sb2_wentry),
        .sb2_wdata    (bank_sb2_wdata),
        .sb1_addr     (et_sb1_addr),
        .sb1_q        (et_sb1_q),
        .sb2_addr_a   (et_sb2_addr_a),
        .sb2_addr_b   (et_sb2_addr_b),
        .sb2_q_a      (et_sb2_q_a),
        .sb2_q_b      (et_sb2_q_b)
    );

    odocrypt_sbox_bank sbox_bank1 (
        .clk          (clk),
        .active_bank  (bank_active_bank),
        .load_bank    (bank_load_bank),
        .sb1_we       (bank_sb1_we),
        .sb1_wsel     (bank_sb1_wsel),
        .sb1_wentry   (bank_sb1_wentry),
        .sb1_wdata    (bank_sb1_wdata),
        .sb2_we       (bank_sb2_we),
        .sb2_wsel     (bank_sb2_wsel),
        .sb2_wentry   (bank_sb2_wentry),
        .sb2_wdata    (bank_sb2_wdata),
        .sb1_addr     (et1_sb1_addr),
        .sb1_q        (et1_sb1_q),
        .sb2_addr_a   (et1_sb2_addr_a),
        .sb2_addr_b   (et1_sb2_addr_b),
        .sb2_q_a      (et1_sb2_q_a),
        .sb2_q_b      (et1_sb2_q_b)
    );

    odocrypt_sbox_bank sbox_bank2 (
        .clk          (clk),
        .active_bank  (bank_active_bank),
        .load_bank    (bank_load_bank),
        .sb1_we       (bank_sb1_we),
        .sb1_wsel     (bank_sb1_wsel),
        .sb1_wentry   (bank_sb1_wentry),
        .sb1_wdata    (bank_sb1_wdata),
        .sb2_we       (bank_sb2_we),
        .sb2_wsel     (bank_sb2_wsel),
        .sb2_wentry   (bank_sb2_wentry),
        .sb2_wdata    (bank_sb2_wdata),
        .sb1_addr     (et2_sb1_addr),
        .sb1_q        (et2_sb1_q),
        .sb2_addr_a   (et2_sb2_addr_a),
        .sb2_addr_b   (et2_sb2_addr_b),
        .sb2_q_a      (et2_sb2_q_a),
        .sb2_q_b      (et2_sb2_q_b)
    );

    // -------------------------------------------------------------------------
    // Core 0 — lower third of nonce range
    // -------------------------------------------------------------------------
    odocrypt_core core_inst (
        .clk          (clk),
        .reset_n      (core_reset_n),
        .start        (core_start_pulse),
        .nonce_start  (nonce_start_reg),
        .nonce_end    (core0_nonce_end),
        .header_words (header_reg),
        .target       (target_256),
        .epoch        (epoch_value),
        .sb1_addr     (et_sb1_addr),
        .sb1_q        (et_sb1_q),
        .sb2_addr_a   (et_sb2_addr_a),
        .sb2_addr_b   (et_sb2_addr_b),
        .sb2_q_a      (et_sb2_q_a),
        .sb2_q_b      (et_sb2_q_b),
        .pmask_flat   (et_pmask),
        .prot_flat    (et_prot),
        .rot_flat     (et_rot),
        .rk_flat      (et_rk),
        .tables_valid (et_tables_valid),
        .kec_req          (c0_kec_req),
        .kec_in           (c0_kec_in),
        .kec_result       (kec_result),
        .kec_result_valid (c0_kec_rvalid),
        .busy         (core_busy),
        .found        (core_found),
        .found_nonce  (core_found_nonce),
        .hash_out     (core_hash),
        .hash_valid   (core_hash_valid)
    );

    // Core 1 — middle third of nonce range
    odocrypt_core core_inst1 (
        .clk          (clk),
        .reset_n      (core_reset_n),
        .start        (core_start_pulse),
        .nonce_start  (core1_nonce_start),
        .nonce_end    (core1_nonce_end),
        .header_words (header_reg),
        .target       (target_256),
        .epoch        (epoch_value),
        .sb1_addr     (et1_sb1_addr),
        .sb1_q        (et1_sb1_q),
        .sb2_addr_a   (et1_sb2_addr_a),
        .sb2_addr_b   (et1_sb2_addr_b),
        .sb2_q_a      (et1_sb2_q_a),
        .sb2_q_b      (et1_sb2_q_b),
        .pmask_flat   (et_pmask),
        .prot_flat    (et_prot),
        .rot_flat     (et_rot),
        .rk_flat      (et_rk),
        .tables_valid (et_tables_valid),
        .kec_req          (c1_kec_req),
        .kec_in           (c1_kec_in),
        .kec_result       (kec_result),
        .kec_result_valid (c1_kec_rvalid),
        .busy         (core1_busy),
        .found        (core1_found),
        .found_nonce  (core1_found_nonce),
        .hash_out     (core1_hash),
        .hash_valid   (core1_hash_valid)
    );

    // Core 2 — upper third of nonce range
    odocrypt_core core_inst2 (
        .clk          (clk),
        .reset_n      (core_reset_n),
        .start        (core_start_pulse),
        .nonce_start  (core2_nonce_start),
        .nonce_end    (nonce_end_reg),
        .header_words (header_reg),
        .target       (target_256),
        .epoch        (epoch_value),
        .sb1_addr     (et2_sb1_addr),
        .sb1_q        (et2_sb1_q),
        .sb2_addr_a   (et2_sb2_addr_a),
        .sb2_addr_b   (et2_sb2_addr_b),
        .sb2_q_a      (et2_sb2_q_a),
        .sb2_q_b      (et2_sb2_q_b),
        .pmask_flat   (et_pmask),
        .prot_flat    (et_prot),
        .rot_flat     (et_rot),
        .rk_flat      (et_rk),
        .tables_valid (et_tables_valid),
        .kec_req          (c2_kec_req),
        .kec_in           (c2_kec_in),
        .kec_result       (kec_result),
        .kec_result_valid (c2_kec_rvalid),
        .busy         (core2_busy),
        .found        (core2_found),
        .found_nonce  (core2_found_nonce),
        .hash_out     (core2_hash),
        .hash_valid   (core2_hash_valid)
    );

    // -------------------------------------------------------------------------
    // Shared Keccak-800 unit + arbiter.
    // Keccak occupies ~58 cycles of each core's ~1910-cycle hash (<1% duty per
    // core), so one unit comfortably serves all three (~9% combined demand). A
    // lowest-index-priority grant serializes the rare collisions (losers stall a
    // handful of cycles); because the cores run a data-independent, fixed-length
    // FSM they start in lockstep and self-skew by one Keccak latency after the
    // first collision, so the steady-state throughput penalty is negligible.
    // Saves the ~1.8k ALM duplicate Keccak each extra core would otherwise carry.
    // -------------------------------------------------------------------------
    localparam KEC_IDLE = 1'b0, KEC_BUSY = 1'b1;
    reg          kec_state;
    reg  [1:0]   kec_owner;        // 0/1/2 = which core owns the in-flight op
    reg          kec_read;
    reg  [639:0] kec_in_mux;
    wire [255:0] kec_out;
    wire         kec_write;

    keccak_hasher #(.WIDTH(640), .THROUGHPUT(12)) keccak_shared (
        .clk   (clk),
        .in    (kec_in_mux),
        .read  (kec_read),
        .out   (kec_out),
        .write (kec_write)
    );

    // Result bus is common; only the current owner sees a valid strobe.
    assign kec_result    = kec_out;
    assign c0_kec_rvalid = kec_write && (kec_state == KEC_BUSY) && (kec_owner == 2'd0);
    assign c1_kec_rvalid = kec_write && (kec_state == KEC_BUSY) && (kec_owner == 2'd1);
    assign c2_kec_rvalid = kec_write && (kec_state == KEC_BUSY) && (kec_owner == 2'd2);

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            kec_state  <= KEC_IDLE;
            kec_owner  <= 2'd0;
            kec_read   <= 1'b0;
            kec_in_mux <= 640'd0;
        end else begin
            kec_read <= 1'b0;     // read is a single-cycle strobe
            case (kec_state)
                KEC_IDLE: begin
                    // Lowest-index priority if more than one requests at once.
                    if (c0_kec_req) begin
                        kec_owner  <= 2'd0;
                        kec_in_mux <= c0_kec_in;
                        kec_read   <= 1'b1;
                        kec_state  <= KEC_BUSY;
                    end else if (c1_kec_req) begin
                        kec_owner  <= 2'd1;
                        kec_in_mux <= c1_kec_in;
                        kec_read   <= 1'b1;
                        kec_state  <= KEC_BUSY;
                    end else if (c2_kec_req) begin
                        kec_owner  <= 2'd2;
                        kec_in_mux <= c2_kec_in;
                        kec_read   <= 1'b1;
                        kec_state  <= KEC_BUSY;
                    end
                end
                KEC_BUSY: begin
                    // One read in flight; release on its single write pulse.
                    if (kec_write)
                        kec_state <= KEC_IDLE;
                end
            endcase
        end
    end

    // -------------------------------------------------------------------------
    // Epoch write strobes: combinatorial decode from Avalon write
    // -------------------------------------------------------------------------
    always @(*) begin
        et_wr_en    = avs_write && (avs_address == ADDR_EPOCH_WR_DATA);
        et_wr_reset = avs_write && (avs_address == ADDR_EPOCH_WR_RESET);
        et_commit   = avs_write && (avs_address == ADDR_EPOCH_COMMIT);
    end

    // -------------------------------------------------------------------------
    // Register write logic
    // -------------------------------------------------------------------------
    integer i;
    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            control_reg      <= 32'h0000_0000;
            epoch_reg        <= 32'h0000_0000;
            nonce_start_reg  <= 32'h0000_0000;
            nonce_end_reg    <= 32'h0000_0000;
            found_latched    <= 1'b0;
            core_found_d     <= 1'b0;
            core1_found_d    <= 1'b0;
            core2_found_d    <= 1'b0;
            found_core_id    <= 2'd0;
            found_nonce_reg  <= 32'h0000_0000;
            perf_hashes_lo   <= 32'h0000_0000;
            perf_hashes_hi   <= 32'h0000_0000;
            perf_shares      <= 32'h0000_0000;
            perf_uptime      <= 32'h0000_0000;

            for (i = 0; i < 8; i = i + 1)
                target_reg[32*i +: 32] <= 32'h0000_0000;
            header_reg <= 640'h0;
            for (i = 0; i < 8; i = i + 1)
                hash_reg[32*i +: 32] <= 32'h0000_0000;
        end else begin
            // uptime increments every cycle while the design is powered
            perf_uptime <= perf_uptime + 1;

            if (avs_write) begin
                case (avs_address)
                    ADDR_CONTROL: begin
                        control_reg <= avs_writedata;
                        if (avs_writedata[3]) begin
                            found_latched   <= 1'b0;
                            found_nonce_reg <= 32'h0000_0000;
                        end
                    end
                    ADDR_EPOCH: epoch_reg <= avs_writedata;
                    ADDR_NONCE_START: nonce_start_reg <= avs_writedata;
                    ADDR_NONCE_END: nonce_end_reg <= avs_writedata;
                    ADDR_TARGET_BASE,
                    ADDR_TARGET_BASE + 8'h04,
                    ADDR_TARGET_BASE + 8'h08,
                    ADDR_TARGET_BASE + 8'h0C,
                    ADDR_TARGET_BASE + 8'h10,
                    ADDR_TARGET_BASE + 8'h14,
                    ADDR_TARGET_BASE + 8'h18,
                    ADDR_TARGET_BASE + 8'h1C: begin
                        target_reg[32*((avs_address - ADDR_TARGET_BASE) >> 2) +: 32] <= avs_writedata;
                    end
                    ADDR_HEADER_BASE,
                    ADDR_HEADER_BASE + 8'h04,
                    ADDR_HEADER_BASE + 8'h08,
                    ADDR_HEADER_BASE + 8'h0C,
                    ADDR_HEADER_BASE + 8'h10,
                    ADDR_HEADER_BASE + 8'h14,
                    ADDR_HEADER_BASE + 8'h18,
                    ADDR_HEADER_BASE + 8'h1C,
                    ADDR_HEADER_BASE + 8'h20,
                    ADDR_HEADER_BASE + 8'h24,
                    ADDR_HEADER_BASE + 8'h28,
                    ADDR_HEADER_BASE + 8'h2C,
                    ADDR_HEADER_BASE + 8'h30,
                    ADDR_HEADER_BASE + 8'h34,
                    ADDR_HEADER_BASE + 8'h38,
                    ADDR_HEADER_BASE + 8'h3C,
                    ADDR_HEADER_BASE + 8'h40,
                    ADDR_HEADER_BASE + 8'h44,
                    ADDR_HEADER_BASE + 8'h48,
                    ADDR_HEADER_BASE + 8'h4C: begin
                        header_reg[32*((avs_address - ADDR_HEADER_BASE) >> 2) +: 32] <= avs_writedata;
                    end
                    default: ;
                endcase
            end

            // Continuously capture the most-recently computed hash for Pass-A
            // testability (target=0 means no found signal, but we still want
            // hash_reg to reflect the computed value).  The found-latch blocks
            // below overwrite with the correct hash when a nonce is found.
            if (core_hash_valid) begin
                for (i = 0; i < 8; i = i + 1)
                    hash_reg[32*i +: 32] <= core_hash[32*i +: 32];
            end else if (core1_hash_valid) begin
                for (i = 0; i < 8; i = i + 1)
                    hash_reg[32*i +: 32] <= core1_hash[32*i +: 32];
            end else if (core2_hash_valid) begin
                for (i = 0; i < 8; i = i + 1)
                    hash_reg[32*i +: 32] <= core2_hash[32*i +: 32];
            end

            // Count completed hash evaluations from all three cores
            if (core_hash_valid || core1_hash_valid || core2_hash_valid) begin
                {perf_hashes_hi, perf_hashes_lo} <=
                    {perf_hashes_hi, perf_hashes_lo}
                    + {{63{1'b0}}, core_hash_valid}
                    + {{63{1'b0}}, core1_hash_valid}
                    + {{63{1'b0}}, core2_hash_valid};
            end

            // Latch on the rising edge of any core's found signal.
            // Lowest-index core wins if more than one asserts the same cycle.
            core_found_d  <= core_found;
            core1_found_d <= core1_found;
            core2_found_d <= core2_found;
            if (core_found && !core_found_d && !found_latched) begin
                found_latched   <= 1'b1;
                found_core_id   <= 2'd0;
                found_nonce_reg <= core_found_nonce;
                for (i = 0; i < 8; i = i + 1)
                    hash_reg[32*i +: 32] <= core_hash[32*i +: 32];
                perf_shares     <= perf_shares + 1;
            end else if (core1_found && !core1_found_d && !found_latched) begin
                found_latched   <= 1'b1;
                found_core_id   <= 2'd1;
                found_nonce_reg <= core1_found_nonce;
                for (i = 0; i < 8; i = i + 1)
                    hash_reg[32*i +: 32] <= core1_hash[32*i +: 32];
                perf_shares     <= perf_shares + 1;
            end else if (core2_found && !core2_found_d && !found_latched) begin
                found_latched   <= 1'b1;
                found_core_id   <= 2'd2;
                found_nonce_reg <= core2_found_nonce;
                for (i = 0; i < 8; i = i + 1)
                    hash_reg[32*i +: 32] <= core2_hash[32*i +: 32];
                perf_shares     <= perf_shares + 1;
            end
        end
    end

    // -------------------------------------------------------------------------
    // Register read logic
    // -------------------------------------------------------------------------
    always @(*) begin
        avs_readdata = 32'h0000_0000;
        case (avs_address)
            ADDR_CONTROL:       avs_readdata = control_reg;
            ADDR_STATUS:        avs_readdata = {27'h0, et_tables_valid, 1'b1 /*EPOCH_LOCK*/, 1'b1 /*CORE_READY*/, found_latched, (core_busy || core1_busy || core2_busy)};
            ADDR_VERSION:       avs_readdata = version_reg;
            ADDR_EPOCH:         avs_readdata = epoch_reg;
            ADDR_NONCE_START:   avs_readdata = nonce_start_reg;
            ADDR_NONCE_END:     avs_readdata = nonce_end_reg;
            ADDR_NONCE_FOUND:   avs_readdata = found_nonce_reg;
            ADDR_CORE_FOUND:    avs_readdata = {30'h0, found_core_id};
            ADDR_TARGET_BASE,
            ADDR_TARGET_BASE + 8'h04,
            ADDR_TARGET_BASE + 8'h08,
            ADDR_TARGET_BASE + 8'h0C,
            ADDR_TARGET_BASE + 8'h10,
            ADDR_TARGET_BASE + 8'h14,
            ADDR_TARGET_BASE + 8'h18,
            ADDR_TARGET_BASE + 8'h1C: begin
                avs_readdata = target_reg[32*((avs_address - ADDR_TARGET_BASE) >> 2) +: 32];
            end
            ADDR_HEADER_BASE,
            ADDR_HEADER_BASE + 8'h04,
            ADDR_HEADER_BASE + 8'h08,
            ADDR_HEADER_BASE + 8'h0C,
            ADDR_HEADER_BASE + 8'h10,
            ADDR_HEADER_BASE + 8'h14,
            ADDR_HEADER_BASE + 8'h18,
            ADDR_HEADER_BASE + 8'h1C,
            ADDR_HEADER_BASE + 8'h20,
            ADDR_HEADER_BASE + 8'h24,
            ADDR_HEADER_BASE + 8'h28,
            ADDR_HEADER_BASE + 8'h2C,
            ADDR_HEADER_BASE + 8'h30,
            ADDR_HEADER_BASE + 8'h34,
            ADDR_HEADER_BASE + 8'h38,
            ADDR_HEADER_BASE + 8'h3C,
            ADDR_HEADER_BASE + 8'h40,
            ADDR_HEADER_BASE + 8'h44,
            ADDR_HEADER_BASE + 8'h48,
            ADDR_HEADER_BASE + 8'h4C: begin
                avs_readdata = header_reg[32*((avs_address - ADDR_HEADER_BASE) >> 2) +: 32];
            end
            ADDR_HASH_BASE,
            ADDR_HASH_BASE + 8'h04,
            ADDR_HASH_BASE + 8'h08,
            ADDR_HASH_BASE + 8'h0C,
            ADDR_HASH_BASE + 8'h10,
            ADDR_HASH_BASE + 8'h14,
            ADDR_HASH_BASE + 8'h18,
            ADDR_HASH_BASE + 8'h1C: begin
                avs_readdata = hash_reg[32*((avs_address - ADDR_HASH_BASE) >> 2) +: 32];
            end
            ADDR_PERF_HASHES_LO: avs_readdata = perf_hashes_lo;
            ADDR_PERF_HASHES_HI: avs_readdata = perf_hashes_hi;
            ADDR_PERF_SHARES:    avs_readdata = perf_shares;
            ADDR_PERF_UPTIME:    avs_readdata = perf_uptime;
            ADDR_EPOCH_WR_DATA:  avs_readdata = 32'h0000_0000;  // WO
            ADDR_EPOCH_WR_RESET: avs_readdata = 32'h0000_0000;  // WO
            ADDR_EPOCH_COMMIT:   avs_readdata = 32'h0000_0000;  // WO
            ADDR_EPOCH_WR_ADDR:  avs_readdata = {19'd0, et_wr_addr_out};
            default: avs_readdata = 32'h0000_0000;
        endcase
    end

endmodule
