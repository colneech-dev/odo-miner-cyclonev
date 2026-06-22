// pwm_fan.v
// Single-register Avalon-MM PWM generator for fan speed control.
// 11-bit free-running counter off clk (~55 MHz fabric clock) gives a
// ~26.9 kHz carrier (55e6/2048), comfortably above the 21-28 kHz 4-pin
// PWM-fan convention. 8-bit duty register (0-255) compares against the
// counter's top 8 bits for 256 speed steps.
//
// Register map (byte address, 32-bit access):
//   0x00  DUTY  [7:0] - 0 = off, 255 = full speed. Read returns last write.

module pwm_fan (
    input  wire        clk,
    input  wire        reset_n,

    input  wire [7:0]  avs_address,
    input  wire        avs_read,
    input  wire        avs_write,
    input  wire [31:0] avs_writedata,
    output reg  [31:0] avs_readdata,
    output wire        avs_waitrequest,

    output wire         pwm_out
);

    localparam ADDR_DUTY = 8'h00;

    assign avs_waitrequest = 1'b0;   // single-cycle register access

    reg [7:0] duty;
    reg [10:0] cnt;

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            duty <= 8'h0;
        end else if (avs_write && avs_address == ADDR_DUTY) begin
            duty <= avs_writedata[7:0];
        end
    end

    always @(*) begin
        avs_readdata = 32'h0;
        if (avs_read && avs_address == ADDR_DUTY)
            avs_readdata = {24'h0, duty};
    end

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n)
            cnt <= 11'h0;
        else
            cnt <= cnt + 11'h1;
    end

    assign pwm_out = (cnt[10:3] < duty) ? 1'b1 : 1'b0;

endmodule
