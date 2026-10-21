`timescale 1ns / 1ps
// True dual-port RAM, 32-bit words with byte write enables, one clock per port.
// Port A is used by the host (PCIe clock), port B by the CPU (100 MHz).
// Both ports are read-first with one cycle of read latency.
// Follows the UG901 byte-write TDP template so Vivado infers block RAM.
module tdp_ram #(
    parameter AW        = 16,      // word address bits (16 -> 64K words = 256 KB)
    parameter INIT_FILE = ""       // optional $readmemh file (one 32-bit word per line)
) (
    input  wire          clka,
    input  wire          ena,
    input  wire [3:0]    wea,
    input  wire [AW-1:0] addra,
    input  wire [31:0]   dina,
    output reg  [31:0]   douta,

    input  wire          clkb,
    input  wire          enb,
    input  wire [3:0]    web,
    input  wire [AW-1:0] addrb,
    input  wire [31:0]   dinb,
    output reg  [31:0]   doutb
);
    (* ram_style = "block" *) reg [31:0] mem [0:(1<<AW)-1];

    integer k;
    initial begin
        for (k = 0; k < (1<<AW); k = k + 1) mem[k] = 32'h0;
        if (INIT_FILE != "") $readmemh(INIT_FILE, mem);
    end

    always @(posedge clka) if (ena) douta <= mem[addra];
    always @(posedge clkb) if (enb) doutb <= mem[addrb];

    genvar i;
    generate
        for (i = 0; i < 4; i = i + 1) begin : g_col
            always @(posedge clka) if (ena && wea[i]) mem[addra][i*8 +: 8] <= dina[i*8 +: 8];
            always @(posedge clkb) if (enb && web[i]) mem[addrb][i*8 +: 8] <= dinb[i*8 +: 8];
        end
    endgenerate
endmodule
