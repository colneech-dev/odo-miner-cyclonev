// axi_lite_to_avalon.v
// AXI Lite → Avalon-MM Lite bridge
// Properly handles address/data arriving at different times

module axi_lite_to_avalon (
    input  wire         clk,
    input  wire         reset_n,

    // AXI Lite Master
    input  wire [31:0]  AWADDR,
    input  wire         AWVALID,
    output wire         AWREADY,

    input  wire [31:0]  WDATA,
    input  wire [3:0]   WSTRB,
    input  wire         WVALID,
    output wire         WREADY,

    output wire [1:0]   BRESP,
    output wire         BVALID,
    input  wire         BREADY,

    input  wire [31:0]  ARADDR,
    input  wire         ARVALID,
    output wire         ARREADY,

    output wire [31:0]  RDATA,
    output wire [1:0]   RRESP,
    output wire         RVALID,
    input  wire         RREADY,

    // Avalon-MM Lite Slave
    output wire [7:0]   avs_address,
    output wire         avs_read,
    output wire         avs_write,
    output wire [31:0]  avs_writedata,
    input  wire [31:0]  avs_readdata,
    input  wire         avs_waitrequest
);

    // Write path: latch address and data separately
    reg [31:0] wr_addr_latched;
    reg [31:0] wr_data_latched;
    reg        wr_addr_valid;
    reg        wr_data_valid;
    reg        write_resp_valid;

    // Read path: latch data and valid
    reg [31:0] read_data_latched;
    reg        read_valid;

    // Write: Latch address when AWVALID
    always @(posedge clk or negedge reset_n) begin
        if (~reset_n) begin
            wr_addr_latched <= 32'h0;
            wr_addr_valid <= 1'b0;
        end else begin
            if (AWVALID && AWREADY) begin
                wr_addr_latched <= AWADDR;
                wr_addr_valid <= 1'b1;
            end else if (avs_write && ~avs_waitrequest) begin
                wr_addr_valid <= 1'b0;
            end
        end
    end

    // Write: Latch data when WVALID
    always @(posedge clk or negedge reset_n) begin
        if (~reset_n) begin
            wr_data_latched <= 32'h0;
            wr_data_valid <= 1'b0;
        end else begin
            if (WVALID && WREADY) begin
                wr_data_latched <= WDATA;
                wr_data_valid <= 1'b1;
            end else if (avs_write && ~avs_waitrequest) begin
                wr_data_valid <= 1'b0;
            end
        end
    end

    // Write: Issue when both address and data are ready
    assign avs_write     = wr_addr_valid && wr_data_valid && ~avs_waitrequest;
    assign avs_address   = wr_addr_latched[7:0];
    assign avs_writedata = wr_data_latched;

    // Write handshake: ready when slave is not waiting
    assign AWREADY = ~avs_waitrequest;
    assign WREADY  = ~avs_waitrequest;
    assign BRESP   = 2'b00;
    assign BVALID  = write_resp_valid;

    always @(posedge clk or negedge reset_n) begin
        if (~reset_n) begin
            write_resp_valid <= 1'b0;
        end else begin
            if (avs_write && ~avs_waitrequest) begin
                write_resp_valid <= 1'b1;
            end else if (BREADY && write_resp_valid) begin
                write_resp_valid <= 1'b0;
            end
        end
    end

    // Read path: Latch address and issue read
    reg        rd_valid;

    always @(posedge clk or negedge reset_n) begin
        if (~reset_n) begin
            rd_valid <= 1'b0;
        end else begin
            if (ARVALID && ARREADY) begin
                rd_valid <= 1'b1;
            end else if (avs_read && ~avs_waitrequest) begin
                rd_valid <= 1'b0;
            end
        end
    end

    assign avs_read    = rd_valid && ~avs_waitrequest;
    assign ARREADY     = ~avs_waitrequest;

    // Read: Latch slave readdata when read completes
    always @(posedge clk or negedge reset_n) begin
        if (~reset_n) begin
            read_data_latched <= 32'h0;
            read_valid <= 1'b0;
        end else begin
            if (avs_read && ~avs_waitrequest) begin
                read_data_latched <= avs_readdata;
                read_valid <= 1'b1;
            end else if (RREADY && read_valid) begin
                read_valid <= 1'b0;
            end
        end
    end

    assign RDATA = read_data_latched;
    assign RRESP = 2'b00;
    assign RVALID = read_valid;

endmodule
