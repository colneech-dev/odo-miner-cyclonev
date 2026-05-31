module cdc_bus #(
    parameter WIDTH = 32
)(
    input  wire             clk_src,
    input  wire             clk_dst,
    input  wire [WIDTH-1:0] data_src,
    input  wire             valid_src,
    output wire             ready_src,

    output reg  [WIDTH-1:0] data_dst,
    output reg              valid_dst,
    input  wire             ready_dst
);

    reg        valid_src_d;
    wire       pulse_src = valid_src & ~valid_src_d;

    always @(posedge clk_src)
        valid_src_d <= valid_src;

    wire pulse_dst;
    cdc_sync sync_pulse (.clk_dst(clk_dst), .in_src(pulse_src), .out_dst(pulse_dst));

    always @(posedge clk_dst) begin
        if (pulse_dst) begin
            data_dst  <= data_src;
            valid_dst <= 1'b1;
        end else if (ready_dst) begin
            valid_dst <= 1'b0;
        end
    end

    assign ready_src = ready_dst;

endmodule
