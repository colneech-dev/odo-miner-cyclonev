module cdc_sync (
    input  wire clk_dst,
    input  wire in_src,
    output reg  out_dst
);
    reg s1;
    always @(posedge clk_dst) begin
        s1      <= in_src;
        out_dst <= s1;
    end
endmodule
