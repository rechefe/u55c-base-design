`timescale 1ns / 1ps
// Clock-domain-crossing helpers. The two clocks are declared asynchronous
// in the XDC, so these structures carry all crossings between them.

// Two-flop synchronizer for single bits or bits that change independently.
module sync_bits #(
    parameter W    = 1,
    parameter INIT = 0
) (
    input  wire         clk,
    input  wire [W-1:0] d,
    output wire [W-1:0] q
);
    (* ASYNC_REG = "TRUE" *) reg [W-1:0] s1 = INIT[W-1:0];
    (* ASYNC_REG = "TRUE" *) reg [W-1:0] s2 = INIT[W-1:0];
    always @(posedge clk) begin
        s1 <= d;
        s2 <= s1;
    end
    assign q = s2;
endmodule

// Continuously copies a multi-bit value from src_clk to dst_clk using a
// toggle handshake. The destination always sees a coherent (untorn) value
// that lags the source by a few clock cycles. If src_clk stops, dst_data
// simply keeps its last value.
module cdc_snapshot #(
    parameter W = 32
) (
    input  wire         src_clk,
    input  wire [W-1:0] src_data,
    input  wire         dst_clk,
    output reg  [W-1:0] dst_data = {W{1'b0}}
);
    reg         req  = 1'b0;          // dst domain
    reg         ack  = 1'b0;          // src domain
    reg [W-1:0] hold = {W{1'b0}};     // src domain, stable while dst copies it

    wire req_s, ack_s;
    sync_bits #(.W(1)) u_req (.clk(src_clk), .d(req), .q(req_s));
    sync_bits #(.W(1)) u_ack (.clk(dst_clk), .d(ack), .q(ack_s));

    always @(posedge src_clk) begin
        if (req_s != ack) begin
            hold <= src_data;
            ack  <= req_s;
        end
    end

    always @(posedge dst_clk) begin
        if (ack_s == req) begin
            dst_data <= hold;
            req      <= ~req;
        end
    end
endmodule
