`timescale 1ns / 1ps
// FPGA self-reload ("IPROG") through the ICAPE3 configuration port.
//
// When arm_toggle changes (it comes from the host clock domain), the module
// waits DELAY_CYCLES and then writes the UG570 IPROG sequence into ICAPE3.
// The FPGA then reconfigures itself from flash address 0 (WBSTAR = 0).
// The delay gives the host time to detach the PCIe device before the link drops.
module iprog #(
    parameter DELAY_CYCLES = 100_000_000  // 1 s at 100 MHz
) (
    input  wire clk,                       // <= 200 MHz (ICAP limit)
    input  wire rst,
    input  wire arm_toggle,                // asynchronous, toggles once per request
    output reg  armed = 1'b0
);
    wire arm_s;
    reg  arm_d = 1'b0;
    sync_bits #(.W(1)) u_sync (.clk(clk), .d(arm_toggle), .q(arm_s));

    // UG570, "IPROG Using ICAPE3": dummy, sync, noop, WBSTAR=0, CMD=IPROG, noop
    function [31:0] seq(input [2:0] i);
        case (i)
            3'd0: seq = 32'hFFFF_FFFF;
            3'd1: seq = 32'hAA99_5566;
            3'd2: seq = 32'h2000_0000;
            3'd3: seq = 32'h3002_0001;
            3'd4: seq = 32'h0000_0000;
            3'd5: seq = 32'h3000_8001;
            3'd6: seq = 32'h0000_000F;
            default: seq = 32'h2000_0000;
        endcase
    endfunction

    // ICAP data pins are bit-swapped within each byte.
    function [31:0] bitswap(input [31:0] w);
        integer b, j;
        begin
            for (b = 0; b < 4; b = b + 1)
                for (j = 0; j < 8; j = j + 1)
                    bitswap[b*8 + j] = w[b*8 + 7 - j];
        end
    endfunction

    reg [26:0] cnt   = 0;
    reg [3:0]  idx   = 0;
    reg        csib  = 1'b1;
    reg [31:0] icap_i = 32'hFFFF_FFFF;
    wire       avail;

    always @(posedge clk) begin
        arm_d <= arm_s;
        csib  <= 1'b1;
        if (rst) begin
            armed <= 1'b0;
        end else if (!armed) begin
            if (arm_s != arm_d) begin
                armed <= 1'b1;
                cnt   <= DELAY_CYCLES;
                idx   <= 0;
            end
        end else if (cnt != 0) begin
            cnt <= cnt - 1;
        end else if (idx < 8 && avail) begin
            csib   <= 1'b0;
            icap_i <= bitswap(seq(idx[2:0]));
            idx    <= idx + 1;
        end
        // After the sequence the FPGA reconfigures; nothing more to do.
    end

`ifdef SIM
    assign avail = 1'b1;
`else
    ICAPE3 #(
        .ICAP_AUTO_SWITCH("DISABLE")
    ) u_icap (
        .AVAIL   (avail),
        .O       (),
        .PRDONE  (),
        .PRERROR (),
        .CLK     (clk),
        .CSIB    (csib),
        .I       (icap_i),
        .RDWRB   (1'b0)
    );
`endif
endmodule
