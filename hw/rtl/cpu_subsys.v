`timescale 1ns / 1ps
// PicoRV32 CPU subsystem, 100 MHz clock domain.
//
// CPU address map (see docs/GUIDE.md):
//   0x0000_0000  RAM, 256 KB (port B of the shared program RAM)
//   0x1000_0000  SHM, 16 KB  (port B of the host-shared console/mailbox RAM)
//   0x2000_0000  IO registers:
//       0x00 UART_DATA   W: queue a byte for TX   R: bit31 = valid, [7:0] = RX byte (pops)
//       0x04 UART_STAT   bit0 TX FIFO full, bit1 RX byte available, bit2 TX idle
//       0x08 TIME_LO     free-running 100 MHz counter, low word
//       0x0C TIME_HI     high word
//       0x10 LED         [5:0] drive the six QSFP LEDs
//       0x14 CLK_HZ      constant 100_000_000
//       0xF0 SIM_EXIT    simulation only: ends the simulation
module cpu_subsys #(
    parameter CLK_HZ = 100_000_000,
    parameter BAUD   = 115_200
) (
    input  wire        clk,
    input  wire        rst,           // whole subsystem reset (clock not locked)
    input  wire        cpu_hold,      // host-requested CPU reset (already synchronized)

    // program RAM, port B
    output wire        ram_en,
    output wire [3:0]  ram_we,
    output wire [15:0] ram_addr,
    output wire [31:0] ram_wdata,
    input  wire [31:0] ram_rdata,

    // shared RAM, port B
    output wire        shm_en,
    output wire [3:0]  shm_we,
    output wire [11:0] shm_addr,
    output wire [31:0] shm_wdata,
    input  wire [31:0] shm_rdata,

    output wire [1:0]  uart_txd,
    input  wire [1:0]  uart_rxd,
    output reg  [5:0]  led = 6'd0,

    // status, exported to the host
    output wire        cpu_in_reset,
    output wire        cpu_trap,
    output reg  [31:0] cpu_pc = 32'd0,  // address of the most recent instruction fetch
    output reg  [63:0] time_cnt = 64'd0
);
    wire cpu_resetn = !(rst || cpu_hold);
    assign cpu_in_reset = !cpu_resetn;

    // ---------------------------------------------------------------- CPU
    wire        mem_valid, mem_instr;
    reg         mem_ready = 1'b0;
    wire [31:0] mem_addr, mem_wdata;
    wire [3:0]  mem_wstrb;
    wire [31:0] mem_rdata;

    picorv32 #(
        .ENABLE_COUNTERS (1),
        .ENABLE_REGS_16_31(1),
        .BARREL_SHIFTER  (1),
        .COMPRESSED_ISA  (1),
        .ENABLE_MUL      (0),
        .ENABLE_FAST_MUL (1),
        .ENABLE_DIV      (1),
        .ENABLE_IRQ      (0),
        .CATCH_MISALIGN  (1),
        .CATCH_ILLINSN   (1),
        .PROGADDR_RESET  (32'h0000_0000),
        .STACKADDR       (32'h0004_0000)
    ) u_cpu (
        .clk       (clk),
        .resetn    (cpu_resetn),
        .trap      (cpu_trap),
        .mem_valid (mem_valid),
        .mem_instr (mem_instr),
        .mem_ready (mem_ready),
        .mem_addr  (mem_addr),
        .mem_wdata (mem_wdata),
        .mem_wstrb (mem_wstrb),
        .mem_rdata (mem_rdata),
        .mem_la_read(), .mem_la_write(), .mem_la_addr(), .mem_la_wdata(), .mem_la_wstrb(),
        .pcpi_valid(), .pcpi_insn(), .pcpi_rs1(), .pcpi_rs2(),
        .pcpi_wr(1'b0), .pcpi_rd(32'd0), .pcpi_wait(1'b0), .pcpi_ready(1'b0),
        .irq(32'd0), .eoi(),
        .trace_valid(), .trace_data()
    );

    // ---------------------------------------------------------------- bus
    // Every access takes one wait state: the request is seen in cycle N,
    // memories/registers respond in cycle N+1 together with mem_ready.
    wire start   = mem_valid && !mem_ready;
    wire sel_ram = (mem_addr[31:28] == 4'h0);
    wire sel_shm = (mem_addr[31:28] == 4'h1);
    wire sel_io  = (mem_addr[31:28] == 4'h2);
    wire is_wr   = |mem_wstrb;

    assign ram_en    = start && sel_ram;
    assign ram_we    = mem_wstrb;
    assign ram_addr  = mem_addr[17:2];
    assign ram_wdata = mem_wdata;

    assign shm_en    = start && sel_shm;
    assign shm_we    = mem_wstrb;
    assign shm_addr  = mem_addr[13:2];
    assign shm_wdata = mem_wdata;

    reg [1:0]  rsel = 2'd0;               // 0 ram, 1 shm, 2 io, 3 none
    reg [31:0] io_rdata = 32'd0;
    assign mem_rdata = (rsel == 2'd0) ? ram_rdata :
                       (rsel == 2'd1) ? shm_rdata : io_rdata;

    // ---------------------------------------------------------------- UART
    wire       tx_full, tx_empty, tx_ready;
    wire [7:0] tx_byte;
    wire       tx_txd;
    wire       tx_push = start && sel_io && is_wr && (mem_addr[7:0] == 8'h00);
    wire       tx_pop  = tx_ready && !tx_empty;

    sync_fifo #(.W(8), .LG(8)) u_txf (
        .clk(clk), .rst(rst), .wr(tx_push), .wdata(mem_wdata[7:0]),
        .rd(tx_pop), .rdata(tx_byte), .empty(tx_empty), .full(tx_full));

    uart_tx #(.CLKS_PER_BIT(CLK_HZ/BAUD)) u_tx (
        .clk(clk), .rst(rst), .valid(tx_pop), .data(tx_byte), .ready(tx_ready), .txd(tx_txd));
    assign uart_txd = {tx_txd, tx_txd};    // same stream on both FPGA UARTs

    wire       rx0_v, rx1_v;
    wire [7:0] rx0_d, rx1_d;
    uart_rx #(.CLKS_PER_BIT(CLK_HZ/BAUD)) u_rx0 (
        .clk(clk), .rst(rst), .rxd(uart_rxd[0]), .valid(rx0_v), .data(rx0_d));
    uart_rx #(.CLKS_PER_BIT(CLK_HZ/BAUD)) u_rx1 (
        .clk(clk), .rst(rst), .rxd(uart_rxd[1]), .valid(rx1_v), .data(rx1_d));

    wire       rx_empty, rx_full;
    wire [7:0] rx_byte;
    wire       rx_pop = start && sel_io && !is_wr && (mem_addr[7:0] == 8'h00);
    sync_fifo #(.W(8), .LG(6)) u_rxf (
        .clk(clk), .rst(rst), .wr(rx0_v | rx1_v), .wdata(rx0_v ? rx0_d : rx1_d),
        .rd(rx_pop), .rdata(rx_byte), .empty(rx_empty), .full(rx_full));

    // ---------------------------------------------------------------- IO regs
    always @(posedge clk) begin
        if (rst) time_cnt <= 64'd0;
        else     time_cnt <= time_cnt + 64'd1;
    end

    always @(posedge clk) begin
        mem_ready <= 1'b0;
        if (!cpu_resetn) begin
            rsel <= 2'd3;
        end else if (start) begin
            mem_ready <= 1'b1;
            rsel      <= sel_ram ? 2'd0 : sel_shm ? 2'd1 : 2'd2;
            if (mem_instr) cpu_pc <= mem_addr;
            io_rdata  <= 32'd0;
            if (sel_io) begin
                case (mem_addr[7:0])
                    8'h00: if (!is_wr) io_rdata <= rx_empty ? 32'd0 : {1'b1, 23'd0, rx_byte};
                    8'h04: io_rdata <= {29'd0, (tx_empty && tx_ready), !rx_empty, tx_full};
                    8'h08: io_rdata <= time_cnt[31:0];
                    8'h0C: io_rdata <= time_cnt[63:32];
                    8'h10: begin
                               io_rdata <= {26'd0, led};
                               if (is_wr) led <= mem_wdata[5:0];
                           end
                    8'h14: io_rdata <= CLK_HZ;
`ifdef SIM
                    8'hF0: if (is_wr) begin
                               $display("SIM_EXIT code=%0d", mem_wdata);
                               $finish;
                           end
`endif
                    default: ;
                endcase
            end
        end
    end
endmodule
