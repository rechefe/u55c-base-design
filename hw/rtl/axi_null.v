`timescale 1ns / 1ps
// Terminates the XDMA DMA master port (AXI4 full), which this design does not use.
// Writes are accepted and discarded; reads return zeros with the correct burst
// length, so an accidental DMA transfer completes instead of hanging the host.
module axi_null #(
    parameter DW = 512,
    parameter IW = 4
) (
    input  wire          clk,
    input  wire          resetn,
    input  wire [IW-1:0] awid,
    input  wire          awvalid,
    output reg           awready = 1'b0,
    input  wire          wvalid,
    input  wire          wlast,
    output reg           wready = 1'b0,
    output reg  [IW-1:0] bid = {IW{1'b0}},
    output wire [1:0]    bresp,
    output reg           bvalid = 1'b0,
    input  wire          bready,
    input  wire [IW-1:0] arid,
    input  wire [7:0]    arlen,
    input  wire          arvalid,
    output reg           arready = 1'b0,
    output reg  [IW-1:0] rid = {IW{1'b0}},
    output wire [DW-1:0] rdata,
    output wire [1:0]    rresp,
    output reg           rlast = 1'b0,
    output reg           rvalid = 1'b0,
    input  wire          rready
);
    assign bresp = 2'b00;
    assign rresp = 2'b00;
    assign rdata = {DW{1'b0}};

    // write channel: AW -> W beats until wlast -> B
    reg [1:0] ws = 2'd0;
    always @(posedge clk) begin
        awready <= 1'b0;
        if (!resetn) begin
            ws <= 0; wready <= 1'b0; bvalid <= 1'b0;
        end else case (ws)
            0: if (awvalid && !awready) begin awready <= 1'b1; bid <= awid; wready <= 1'b1; ws <= 1; end
            1: if (wvalid && wlast) begin wready <= 1'b0; bvalid <= 1'b1; ws <= 2; end
            default: if (bready) begin bvalid <= 1'b0; ws <= 0; end
        endcase
    end

    // read channel: AR handshake, then arlen+1 beats of zeros
    reg [8:0] left = 9'd0;
    reg [1:0] rs   = 2'd0;                // 0 idle, 1 accepted, 2 sending
    always @(posedge clk) begin
        arready <= 1'b0;
        if (!resetn) begin
            rs <= 2'd0; rvalid <= 1'b0; rlast <= 1'b0;
        end else case (rs)
            2'd0: if (arvalid && !arready) begin
                      arready <= 1'b1;
                      rid     <= arid;
                      left    <= {1'b0, arlen};
                      rs      <= 2'd1;
                  end
            2'd1: begin
                      rvalid <= 1'b1;
                      rlast  <= (left == 9'd0);
                      rs     <= 2'd2;
                  end
            default: if (rready) begin
                      if (rlast) begin
                          rvalid <= 1'b0;
                          rlast  <= 1'b0;
                          rs     <= 2'd0;
                      end else begin
                          left  <= left - 1;
                          rlast <= (left == 9'd1);
                      end
                  end
        endcase
    end
endmodule
