`timescale 1ns / 1ps
// Minimal 8N1 UART transmitter and receiver.

module uart_tx #(
    parameter CLKS_PER_BIT = 868          // 100 MHz / 115200
) (
    input  wire       clk,
    input  wire       rst,
    input  wire       valid,              // pulse with data when ready=1
    input  wire [7:0] data,
    output wire       ready,
    output reg        txd = 1'b1
);
    reg [9:0]  shreg = 10'h3FF;
    reg [3:0]  bits  = 4'd0;              // bits left to send
    reg [15:0] cnt   = 16'd0;

    assign ready = (bits == 0);

    always @(posedge clk) begin
        if (rst) begin
            bits <= 0;
            txd  <= 1'b1;
        end else if (bits == 0) begin
            if (valid) begin
                shreg <= {1'b1, data, 1'b0};  // stop, data (LSB first), start
                bits  <= 4'd10;
                cnt   <= 0;
            end
        end else if (cnt == 0) begin
            txd   <= shreg[0];
            shreg <= {1'b1, shreg[9:1]};
            cnt   <= CLKS_PER_BIT - 1;
        end else begin
            cnt <= cnt - 1;
            if (cnt == 1) bits <= bits - 1;
        end
    end
endmodule

module uart_rx #(
    parameter CLKS_PER_BIT = 868
) (
    input  wire       clk,
    input  wire       rst,
    input  wire       rxd,
    output reg        valid = 1'b0,       // one-cycle pulse
    output reg  [7:0] data  = 8'd0
);
    wire rx;
    sync_bits #(.W(1), .INIT(1)) u_sync (.clk(clk), .d(rxd), .q(rx));

    reg [1:0]  state = 2'd0;              // 0 idle, 1 start, 2 data, 3 stop
    reg [15:0] cnt   = 16'd0;
    reg [2:0]  bitn  = 3'd0;

    always @(posedge clk) begin
        valid <= 1'b0;
        if (rst) begin
            state <= 0;
        end else case (state)
            0: if (!rx) begin state <= 1; cnt <= CLKS_PER_BIT/2; end
            1: if (cnt == 0) begin
                   if (!rx) begin state <= 2; cnt <= CLKS_PER_BIT - 1; bitn <= 0; end
                   else state <= 0;       // glitch
               end else cnt <= cnt - 1;
            2: if (cnt == 0) begin
                   data <= {rx, data[7:1]};
                   cnt  <= CLKS_PER_BIT - 1;
                   if (bitn == 7) state <= 3;
                   bitn <= bitn + 1;
               end else cnt <= cnt - 1;
            3: if (cnt == 0) begin
                   state <= 0;
                   valid <= rx;           // drop frames with a bad stop bit
               end else cnt <= cnt - 1;
        endcase
    end
endmodule

// Small synchronous FIFO (first-word-fall-through) in distributed RAM.
module sync_fifo #(
    parameter W  = 8,
    parameter LG = 8                      // depth = 2**LG
) (
    input  wire         clk,
    input  wire         rst,
    input  wire         wr,
    input  wire [W-1:0] wdata,
    input  wire         rd,
    output wire [W-1:0] rdata,
    output wire         empty,
    output wire         full
);
    (* ram_style = "distributed" *) reg [W-1:0] mem [0:(1<<LG)-1];
    reg [LG:0] wp = 0, rp = 0;

    assign empty = (wp == rp);
    assign full  = (wp[LG] != rp[LG]) && (wp[LG-1:0] == rp[LG-1:0]);
    assign rdata = mem[rp[LG-1:0]];

    always @(posedge clk) begin
        if (rst) begin
            wp <= 0;
            rp <= 0;
        end else begin
            if (wr && !full) begin
                mem[wp[LG-1:0]] <= wdata;
                wp <= wp + 1;
            end
            if (rd && !empty) rp <= rp + 1;
        end
    end
endmodule
