module cdc_found (
    input  wire        clk_hash,
    input  wire        clk_hps,
    input  wire        found_hash,
    input  wire [31:0] nonce_hash,

    output reg         found_hps,
    output reg [31:0]  nonce_hps
);

    wire found_sync;
    cdc_sync sync_found (.clk_dst(clk_hps), .in_src(found_hash), .out_dst(found_sync));

    reg found_d;
    always @(posedge clk_hps) begin
        found_d   <= found_sync;
        if (found_sync & ~found_d)
            nonce_hps <= nonce_hash;
        found_hps <= found_sync;
    end

endmodule
