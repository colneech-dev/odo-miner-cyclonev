// pwm_fan.v
// Single-register Avalon-MM PWM generator for fan speed control.
// 11-bit free-running counter off clk (~55 MHz fabric clock) gives a
// ~26.9 kHz carrier (55e6/2048), comfortably above the 21-28 kHz 4-pin
// PWM-fan convention. 8-bit duty register (0-255) compares against the
// counter's top 8 bits for 256 speed steps.
//
// Register map (byte address, 32-bit access):
//   0x00  DUTY  [7:0] - 0 = off, 255 = full speed. Read returns last write.
//
// Resets to FULL SPEED (255), not off. The miner core free-runs with no
// software start/stop (see pipelined_miner_top.v) -- it begins hashing at
// full throughput the instant reset_n releases, well before Linux has
// booted far enough to run the thermal daemon and take over fan control
// (hps/thermal.c's own thermal_init() explicitly zeroes the fan too, but
// only once it starts, and even then the first real DS18B20 reading has a
// 750ms conversion delay). Defaulting to off left a real fan-less window
// from FPGA configuration through however long boot happens to take that
// run, with the core already at full heat output -- an intermittent,
// boot-time-dependent brownout/reset-loop risk, not tied to any specific
// epoch's bitstream. Software still explicitly manages the fan curve once
// the daemon is up; this only covers the gap before that.

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
            duty <= 8'hFF;   // full speed until software takes over -- see header comment
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
