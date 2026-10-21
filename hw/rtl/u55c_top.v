`timescale 1ns / 1ps
// Top level for the Alveo U55C RISC-V image.
//
//  PCIe Gen3 x16 (XDMA) --BAR0 AXI-Lite--> host_if --+--> control/status regs
//                                                    +--> SHM (port A)     <--> CPU (port B)
//                                                    +--> program RAM (A)  <--> CPU (port B)
//                                                    +--> AXI Quad SPI --> STARTUPE3 --> config flash
//  161 MHz QSFP refclk -> MMCM -> 100 MHz CPU clock, 50 MHz SPI clock
//  ICAPE3 IPROG: host-triggered reload of the FPGA from flash
// build_params.vh is written by hw/scripts/build.tcl: it defines U55C_BUILD_TIME
// (Unix time of the build) and U55C_FW_INIT (firmware hex preloaded into RAM).
`include "build_params.vh"

module u55c_top #(
    parameter [31:0] BUILD_TIME = `U55C_BUILD_TIME,
    parameter        FW_INIT    = `U55C_FW_INIT
) (
    // PCIe
    input  wire [15:0] pcie_rx_p,
    input  wire [15:0] pcie_rx_n,
    output wire [15:0] pcie_tx_p,
    output wire [15:0] pcie_tx_n,
    input  wire        pcie_refclk_p,
    input  wire        pcie_refclk_n,
    input  wire        pcie_perst_n,

    // 161.1328125 MHz reference from the on-board SI5394 (QSFP0 refclk)
    input  wire        clk161_p,
    input  wire        clk161_n,

    // FPGA UARTs on the FT4232H behind the micro-USB maintenance port
    output wire [1:0]  uart_txd,
    input  wire [1:0]  uart_rxd,

    output wire [5:0]  led,
    output wire        hbm_cattrip     // must be driven low when HBM is unused
);
    assign hbm_cattrip = 1'b0;

    // ------------------------------------------------------------ clocks
    wire clk161_gt, clk161_odiv2, clk161;
    IBUFDS_GTE4 #(.REFCLK_HROW_CK_SEL(2'b00)) u_clk161_ibuf (
        .I(clk161_p), .IB(clk161_n), .CEB(1'b0), .O(clk161_gt), .ODIV2(clk161_odiv2));
    BUFG_GT u_clk161_bufg (
        .I(clk161_odiv2), .CE(1'b1), .CEMASK(1'b0), .CLR(1'b0), .CLRMASK(1'b0),
        .DIV(3'd0), .O(clk161));

    // 161.1328125 * 64 / 11 = 937.5 MHz VCO; /9.375 = 100 MHz; /19 = 49.3 MHz
    wire mmcm_fb, mmcm_locked, clk100_mmcm, clk50_mmcm, clk100, clk50;

    // MMCM reset: a pulse after configuration, and again whenever the MMCM has
    // been unlocked for ~6.5 ms (e.g. the reference started late or glitched).
    wire       locked161;
    reg [19:0] lock_wd   = 20'd0;
    reg [4:0]  mmcm_rcnt = 5'd31;
    wire       mmcm_rst  = (mmcm_rcnt != 0);
    sync_bits #(.W(1)) u_lock161 (.clk(clk161), .d(mmcm_locked), .q(locked161));
    always @(posedge clk161) begin
        if (mmcm_rst) begin
            mmcm_rcnt <= mmcm_rcnt - 1;
            lock_wd   <= 0;
        end else if (locked161) begin
            lock_wd   <= 0;
        end else if (&lock_wd) begin
            mmcm_rcnt <= 5'd31;
        end else begin
            lock_wd   <= lock_wd + 1;
        end
    end
    MMCME4_BASE #(
        .CLKIN1_PERIOD   (6.206),
        .DIVCLK_DIVIDE   (11),
        .CLKFBOUT_MULT_F (64.0),
        .CLKOUT0_DIVIDE_F(9.375),
        .CLKOUT1_DIVIDE  (19)
    ) u_mmcm (
        .CLKIN1(clk161), .CLKFBIN(mmcm_fb), .CLKFBOUT(mmcm_fb), .CLKFBOUTB(),
        .CLKOUT0(clk100_mmcm), .CLKOUT0B(), .CLKOUT1(clk50_mmcm), .CLKOUT1B(),
        .CLKOUT2(), .CLKOUT2B(), .CLKOUT3(), .CLKOUT3B(), .CLKOUT4(), .CLKOUT5(), .CLKOUT6(),
        .LOCKED(mmcm_locked), .PWRDWN(1'b0), .RST(mmcm_rst));
    BUFG u_clk100_bufg (.I(clk100_mmcm), .O(clk100));
    BUFG u_clk50_bufg  (.I(clk50_mmcm),  .O(clk50));

    // synchronous reset for the 100 MHz domain, released some cycles after lock
    wire locked100;
    sync_bits #(.W(1)) u_lock_sync (.clk(clk100), .d(mmcm_locked), .q(locked100));
    reg [7:0] rst_cnt = 8'd0;
    reg       rst100  = 1'b1;
    always @(posedge clk100) begin
        if (!locked100) begin
            rst_cnt <= 0;
            rst100  <= 1'b1;
        end else if (rst_cnt != 8'hFF) begin
            rst_cnt <= rst_cnt + 1;
        end else begin
            rst100 <= 1'b0;
        end
    end

    // ------------------------------------------------------------ PCIe (XDMA)
    wire sys_clk, sys_clk_gt, sys_rst_n;
    IBUFDS_GTE4 #(.REFCLK_HROW_CK_SEL(2'b00)) u_pcie_refclk_ibuf (
        .I(pcie_refclk_p), .IB(pcie_refclk_n), .CEB(1'b0), .O(sys_clk_gt), .ODIV2(sys_clk));
    IBUF u_perst_ibuf (.I(pcie_perst_n), .O(sys_rst_n));

    wire        axi_aclk, axi_aresetn;
    wire [31:0] axil_awaddr, axil_wdata, axil_araddr, axil_rdata;
    wire [3:0]  axil_wstrb;
    wire [1:0]  axil_bresp, axil_rresp;
    wire        axil_awvalid, axil_awready, axil_wvalid, axil_wready, axil_bvalid, axil_bready;
    wire        axil_arvalid, axil_arready, axil_rvalid, axil_rready;

    wire [3:0]   m_awid, m_arid, m_bid, m_rid;
    wire [63:0]  m_awaddr, m_araddr;
    wire [7:0]   m_awlen, m_arlen;
    wire [511:0] m_rdata;
    wire [1:0]   m_bresp, m_rresp;
    wire         m_awvalid, m_awready, m_wvalid, m_wready, m_wlast, m_bvalid, m_bready;
    wire         m_arvalid, m_arready, m_rvalid, m_rready, m_rlast;

    xdma_0 u_xdma (
        .sys_clk(sys_clk), .sys_clk_gt(sys_clk_gt), .sys_rst_n(sys_rst_n),
        .user_lnk_up(),
        .pci_exp_txp(pcie_tx_p), .pci_exp_txn(pcie_tx_n),
        .pci_exp_rxp(pcie_rx_p), .pci_exp_rxn(pcie_rx_n),
        .axi_aclk(axi_aclk), .axi_aresetn(axi_aresetn),
        .usr_irq_req(1'b0), .usr_irq_ack(),
        .msi_enable(), .msi_vector_width(),

        // DMA master: unused, terminated by axi_null
        .m_axi_awready(m_awready), .m_axi_wready(m_wready), .m_axi_bid(m_bid),
        .m_axi_bresp(m_bresp), .m_axi_bvalid(m_bvalid), .m_axi_arready(m_arready),
        .m_axi_rid(m_rid), .m_axi_rdata(m_rdata), .m_axi_rresp(m_rresp),
        .m_axi_rlast(m_rlast), .m_axi_rvalid(m_rvalid),
        .m_axi_awid(m_awid), .m_axi_awaddr(m_awaddr), .m_axi_awlen(m_awlen),
        .m_axi_awsize(), .m_axi_awburst(), .m_axi_awprot(), .m_axi_awvalid(m_awvalid),
        .m_axi_awlock(), .m_axi_awcache(), .m_axi_wdata(), .m_axi_wstrb(),
        .m_axi_wlast(m_wlast), .m_axi_wvalid(m_wvalid), .m_axi_bready(m_bready),
        .m_axi_arid(m_arid), .m_axi_araddr(m_araddr), .m_axi_arlen(m_arlen),
        .m_axi_arsize(), .m_axi_arburst(), .m_axi_arprot(), .m_axi_arvalid(m_arvalid),
        .m_axi_arlock(), .m_axi_arcache(), .m_axi_rready(m_rready),

        // BAR0 register window
        .m_axil_awaddr(axil_awaddr), .m_axil_awprot(), .m_axil_awvalid(axil_awvalid),
        .m_axil_awready(axil_awready), .m_axil_wdata(axil_wdata), .m_axil_wstrb(axil_wstrb),
        .m_axil_wvalid(axil_wvalid), .m_axil_wready(axil_wready), .m_axil_bvalid(axil_bvalid),
        .m_axil_bresp(axil_bresp), .m_axil_bready(axil_bready), .m_axil_araddr(axil_araddr),
        .m_axil_arprot(), .m_axil_arvalid(axil_arvalid), .m_axil_arready(axil_arready),
        .m_axil_rdata(axil_rdata), .m_axil_rresp(axil_rresp), .m_axil_rvalid(axil_rvalid),
        .m_axil_rready(axil_rready),

        .cfg_mgmt_addr(19'd0), .cfg_mgmt_write(1'b0), .cfg_mgmt_write_data(32'd0),
        .cfg_mgmt_byte_enable(4'd0), .cfg_mgmt_read(1'b0), .cfg_mgmt_read_data(),
        .cfg_mgmt_read_write_done()
    );

    axi_null #(.DW(512), .IW(4)) u_axi_null (
        .clk(axi_aclk), .resetn(axi_aresetn),
        .awid(m_awid), .awvalid(m_awvalid), .awready(m_awready),
        .wvalid(m_wvalid), .wlast(m_wlast), .wready(m_wready),
        .bid(m_bid), .bresp(m_bresp), .bvalid(m_bvalid), .bready(m_bready),
        .arid(m_arid), .arlen(m_arlen), .arvalid(m_arvalid), .arready(m_arready),
        .rid(m_rid), .rdata(m_rdata), .rresp(m_rresp), .rlast(m_rlast),
        .rvalid(m_rvalid), .rready(m_rready));

    // ------------------------------------------------------------ CPU, RAMs, host window
    wire [6:0]  q_awaddr, q_araddr;
    wire [31:0] q_wdata, q_rdata;
    wire [3:0]  q_wstrb;
    wire [1:0]  q_bresp, q_rresp;
    wire        q_awvalid, q_awready, q_wvalid, q_wready, q_bvalid, q_bready;
    wire        q_arvalid, q_arready, q_rvalid, q_rready;

    u55c_core #(.BUILD_TIME(BUILD_TIME), .FW_INIT(FW_INIT)) u_core (
        .clk100(clk100), .rst100(rst100), .mmcm_locked(mmcm_locked),
        .axi_aclk(axi_aclk), .axi_aresetn(axi_aresetn),
        .s_awaddr(axil_awaddr), .s_awvalid(axil_awvalid), .s_awready(axil_awready),
        .s_wdata(axil_wdata), .s_wstrb(axil_wstrb), .s_wvalid(axil_wvalid), .s_wready(axil_wready),
        .s_bresp(axil_bresp), .s_bvalid(axil_bvalid), .s_bready(axil_bready),
        .s_araddr(axil_araddr), .s_arvalid(axil_arvalid), .s_arready(axil_arready),
        .s_rdata(axil_rdata), .s_rresp(axil_rresp), .s_rvalid(axil_rvalid), .s_rready(axil_rready),
        .q_awaddr(q_awaddr), .q_awvalid(q_awvalid), .q_awready(q_awready),
        .q_wdata(q_wdata), .q_wstrb(q_wstrb), .q_wvalid(q_wvalid), .q_wready(q_wready),
        .q_bresp(q_bresp), .q_bvalid(q_bvalid), .q_bready(q_bready),
        .q_araddr(q_araddr), .q_arvalid(q_arvalid), .q_arready(q_arready),
        .q_rdata(q_rdata), .q_rresp(q_rresp), .q_rvalid(q_rvalid), .q_rready(q_rready),
        .uart_txd(uart_txd), .uart_rxd(uart_rxd), .led(led));

    // AXI Quad SPI (flash) on the PCIe clock; SPI clock 49 MHz -> SCK ~25 MHz
    qspi_0 u_qspi (
        .ext_spi_clk(clk50),
        .s_axi_aclk(axi_aclk), .s_axi_aresetn(axi_aresetn),
        .s_axi_awaddr(q_awaddr), .s_axi_awvalid(q_awvalid), .s_axi_awready(q_awready),
        .s_axi_wdata(q_wdata), .s_axi_wstrb(q_wstrb), .s_axi_wvalid(q_wvalid), .s_axi_wready(q_wready),
        .s_axi_bresp(q_bresp), .s_axi_bvalid(q_bvalid), .s_axi_bready(q_bready),
        .s_axi_araddr(q_araddr), .s_axi_arvalid(q_arvalid), .s_axi_arready(q_arready),
        .s_axi_rdata(q_rdata), .s_axi_rresp(q_rresp), .s_axi_rvalid(q_rvalid), .s_axi_rready(q_rready),
        .cfgclk(), .cfgmclk(), .eos(), .preq(),
        .gsr(1'b0), .gts(1'b0), .keyclearb(1'b1), .usrcclkts(1'b0),
        .usrdoneo(1'b1), .usrdonets(1'b1),
        .ip2intc_irpt());
endmodule
