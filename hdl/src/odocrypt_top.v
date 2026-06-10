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

    // Epoch table wires from odocrypt_epoch_tables
    wire [239:0]  et_sb1_addr, et_sb1_q;
    wire [99:0]   et_sb2_addr_a, et_sb2_addr_b, et_sb2_q_a, et_sb2_q_b;
    wire [38399:0] et_pmask;
    wire [299:0]   et_prot;
    wire [35:0]    et_rot;
    wire [839:0]   et_rk;
    wire           et_tables_valid;
    wire           et_wr_busy;

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

    // Latch the start request so it survives until the core is idle.
    // Clears once core_busy goes high (core has accepted the start).
    always @(posedge clk or negedge reset_n) begin
        if (!reset_n)
            start_latch <= 1'b0;
        else if (avs_write && (avs_address == ADDR_CONTROL) &&
                 avs_writedata[0] && avs_writedata[2])
            start_latch <= 1'b1;
        else if (core_busy)
            start_latch <= 1'b0;
    end

    assign core_start_pulse = start_latch && !core_busy;

    // -------------------------------------------------------------------------
    // Epoch table storage
    // -------------------------------------------------------------------------
    wire [12:0] et_wr_addr_out;

    odocrypt_epoch_tables epoch_tables_inst (
        .clk          (clk),
        .reset_n      (reset_n),
        .wr_en        (et_wr_en),
        .wr_data      (avs_writedata),
        .wr_reset     (et_wr_reset),
        .commit       (et_commit),
        .wr_busy      (et_wr_busy),
        .sb1_addr     (et_sb1_addr),
        .sb1_q        (et_sb1_q),
        .sb2_addr_a   (et_sb2_addr_a),
        .sb2_addr_b   (et_sb2_addr_b),
        .sb2_q_a      (et_sb2_q_a),
        .sb2_q_b      (et_sb2_q_b),
        .pmask_out    (et_pmask),
        .prot_out     (et_prot),
        .rot_out      (et_rot),
        .rk_out       (et_rk),
        .tables_valid (et_tables_valid),
        .wr_addr_out  (et_wr_addr_out)
    );

    // -------------------------------------------------------------------------
    // Core instance
    // -------------------------------------------------------------------------
    odocrypt_core core_inst (
        .clk          (clk),
        .reset_n      (core_reset_n),
        .start        (core_start_pulse),
        .nonce_start  (nonce_start_reg),
        .nonce_end    (nonce_end_reg),
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
        .busy         (core_busy),
        .found        (core_found),
        .found_nonce  (core_found_nonce),
        .hash_out     (core_hash),
        .hash_valid   (core_hash_valid)
    );

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
            // Default: hold hash_reg value (updated conditionally below)
            for (i = 0; i < 8; i = i + 1)
                hash_reg[32*i +: 32] <= hash_reg[32*i +: 32];

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

            // count completed hash evaluations (one per valid pipeline output)
            if (core_hash_valid) begin
                {perf_hashes_hi, perf_hashes_lo} <= {perf_hashes_hi, perf_hashes_lo} + 64'h1;
            end

            if (core_hash_valid) begin
                for (i = 0; i < 8; i = i + 1)
                    hash_reg[32*i +: 32] <= core_hash[32*i +: 32];
            end

            // Latch on the rising edge of core_found only. Latching on level
            // would re-arm immediately after CTRL_CLEAR_FOUND while the core
            // still holds found high, double-counting shares.
            core_found_d <= core_found;
            if (core_found && !core_found_d) begin
                found_latched   <= 1'b1;
                found_nonce_reg <= core_found_nonce;
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
            ADDR_STATUS:        avs_readdata = {27'h0, et_tables_valid, 1'b1 /*EPOCH_LOCK*/, 1'b1 /*CORE_READY*/, found_latched, core_busy};
            ADDR_VERSION:       avs_readdata = version_reg;
            ADDR_EPOCH:         avs_readdata = epoch_reg;
            ADDR_NONCE_START:   avs_readdata = nonce_start_reg;
            ADDR_NONCE_END:     avs_readdata = nonce_end_reg;
            ADDR_NONCE_FOUND:   avs_readdata = found_nonce_reg;
            ADDR_CORE_FOUND:    avs_readdata = 32'h0000_0000;
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
