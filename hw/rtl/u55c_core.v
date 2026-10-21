`timescale 1ns / 1ps
// Everything except the Xilinx-specific clocking, PCIe and flash IP:
// program RAM, shared RAM, CPU subsystem, host register window, reload logic
// and the clock-domain crossings. Simulated by hw/sim/tb.v.
module u55c_core #(
    parameter [31:0] BUILD_TIME = 32'd0,
    parameter        FW_INIT    = "",
    parameter        BAUD       = 115_200,
    parameter        RELOAD_DELAY = 100_000_000   // 1 s between the reload request and IPROG
) (
    input  wire        clk100,
    input  wire        rst100,
    input  wire        mmcm_locked,
    input  wire        axi_aclk,
    input  wire        axi_aresetn,

    // BAR0 AXI4-Lite slave
    input  wire [31:0] s_awaddr,
    input  wire        s_awvalid,
    output wire        s_awready,
    input  wire [31:0] s_wdata,
    input  wire [3:0]  s_wstrb,
    input  wire        s_wvalid,
    output wire        s_wready,
    output wire [1:0]  s_bresp,
    output wire        s_bvalid,
    input  wire        s_bready,
    input  wire [31:0] s_araddr,
    input  wire        s_arvalid,
    output wire        s_arready,
    output wire [31:0] s_rdata,
    output wire [1:0]  s_rresp,
    output wire        s_rvalid,
    input  wire        s_rready,

    // AXI4-Lite master to the flash controller
    output wire [6:0]  q_awaddr,
    output wire        q_awvalid,
    input  wire        q_awready,
    output wire [31:0] q_wdata,
    output wire [3:0]  q_wstrb,
    output wire        q_wvalid,
    input  wire        q_wready,
    input  wire [1:0]  q_bresp,
    input  wire        q_bvalid,
    output wire        q_bready,
    output wire [6:0]  q_araddr,
    output wire        q_arvalid,
    input  wire        q_arready,
    input  wire [31:0] q_rdata,
    input  wire [1:0]  q_rresp,
    input  wire        q_rvalid,
    output wire        q_rready,

    output wire [1:0]  uart_txd,
    input  wire [1:0]  uart_rxd,
    output wire [5:0]  led
);
    // ------------------------------------------------------------ CPU + RAMs + host window
    wire        cpu_hold_pcie, reload_toggle;
    wire        cpu_in_reset, cpu_trap, reload_armed;
    wire [31:0] cpu_pc;
    wire [63:0] time_cnt;

    wire        a_ram_en, a_shm_en, b_ram_en, b_shm_en;
    wire [3:0]  a_ram_we, a_shm_we, b_ram_we, b_shm_we;
    wire [15:0] a_ram_addr, b_ram_addr;
    wire [11:0] a_shm_addr, b_shm_addr;
    wire [31:0] a_ram_wdata, a_ram_rdata, a_shm_wdata, a_shm_rdata;
    wire [31:0] b_ram_wdata, b_ram_rdata, b_shm_wdata, b_shm_rdata;

    tdp_ram #(.AW(16), .INIT_FILE(FW_INIT)) u_ram (
        .clka(axi_aclk), .ena(a_ram_en), .wea(a_ram_we), .addra(a_ram_addr),
        .dina(a_ram_wdata), .douta(a_ram_rdata),
        .clkb(clk100), .enb(b_ram_en), .web(b_ram_we), .addrb(b_ram_addr),
        .dinb(b_ram_wdata), .doutb(b_ram_rdata));

    tdp_ram #(.AW(12)) u_shm (
        .clka(axi_aclk), .ena(a_shm_en), .wea(a_shm_we), .addra(a_shm_addr),
        .dina(a_shm_wdata), .douta(a_shm_rdata),
        .clkb(clk100), .enb(b_shm_en), .web(b_shm_we), .addrb(b_shm_addr),
        .dinb(b_shm_wdata), .doutb(b_shm_rdata));

    wire cpu_hold_100;
    sync_bits #(.W(1)) u_hold_sync (.clk(clk100), .d(cpu_hold_pcie), .q(cpu_hold_100));

    cpu_subsys #(.BAUD(BAUD)) u_cpu (
        .clk(clk100), .rst(rst100), .cpu_hold(cpu_hold_100),
        .ram_en(b_ram_en), .ram_we(b_ram_we), .ram_addr(b_ram_addr),
        .ram_wdata(b_ram_wdata), .ram_rdata(b_ram_rdata),
        .shm_en(b_shm_en), .shm_we(b_shm_we), .shm_addr(b_shm_addr),
        .shm_wdata(b_shm_wdata), .shm_rdata(b_shm_rdata),
        .uart_txd(uart_txd), .uart_rxd(uart_rxd), .led(led),
        .cpu_in_reset(cpu_in_reset), .cpu_trap(cpu_trap), .cpu_pc(cpu_pc), .time_cnt(time_cnt));

    iprog #(.DELAY_CYCLES(RELOAD_DELAY)) u_iprog (.clk(clk100), .rst(rst100), .arm_toggle(reload_toggle), .armed(reload_armed));

    // status: 100 MHz domain -> PCIe domain
    wire [98:0] st_100 = {reload_armed, cpu_trap, cpu_in_reset, cpu_pc, time_cnt};
    wire [98:0] st_pcie;
    cdc_snapshot #(.W(99)) u_st_cdc (.src_clk(clk100), .src_data(st_100),
                                     .dst_clk(axi_aclk), .dst_data(st_pcie));
    wire locked_pcie;
    sync_bits #(.W(1)) u_lock_pcie (.clk(axi_aclk), .d(mmcm_locked), .q(locked_pcie));

    host_if #(.BUILD_TIME(BUILD_TIME)) u_host (
        .clk(axi_aclk), .resetn(axi_aresetn),
        .s_awaddr(s_awaddr), .s_awvalid(s_awvalid), .s_awready(s_awready),
        .s_wdata(s_wdata), .s_wstrb(s_wstrb), .s_wvalid(s_wvalid), .s_wready(s_wready),
        .s_bresp(s_bresp), .s_bvalid(s_bvalid), .s_bready(s_bready),
        .s_araddr(s_araddr), .s_arvalid(s_arvalid), .s_arready(s_arready),
        .s_rdata(s_rdata), .s_rresp(s_rresp), .s_rvalid(s_rvalid), .s_rready(s_rready),
        .q_awaddr(q_awaddr), .q_awvalid(q_awvalid), .q_awready(q_awready),
        .q_wdata(q_wdata), .q_wstrb(q_wstrb), .q_wvalid(q_wvalid), .q_wready(q_wready),
        .q_bresp(q_bresp), .q_bvalid(q_bvalid), .q_bready(q_bready),
        .q_araddr(q_araddr), .q_arvalid(q_arvalid), .q_arready(q_arready),
        .q_rdata(q_rdata), .q_rresp(q_rresp), .q_rvalid(q_rvalid), .q_rready(q_rready),
        .ram_en(a_ram_en), .ram_we(a_ram_we), .ram_addr(a_ram_addr),
        .ram_wdata(a_ram_wdata), .ram_rdata(a_ram_rdata),
        .shm_en(a_shm_en), .shm_we(a_shm_we), .shm_addr(a_shm_addr),
        .shm_wdata(a_shm_wdata), .shm_rdata(a_shm_rdata),
        .cpu_hold(cpu_hold_pcie), .reload_toggle(reload_toggle),
        .st_cpu_in_reset(st_pcie[96]), .st_cpu_trap(st_pcie[97]), .st_clk_locked(locked_pcie),
        .st_reload_armed(st_pcie[98]), .st_cpu_pc(st_pcie[95:64]), .st_uptime(st_pcie[63:0]));

endmodule
