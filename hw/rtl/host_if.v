`timescale 1ns / 1ps
// Host register window: AXI4-Lite slave on the XDMA "PCIe to AXI-Lite master"
// (BAR0, 1 MB), running on the PCIe user clock.
//
// BAR0 map (see docs/GUIDE.md for the full register description):
//   0x00000 - 0x00FFF  control/status registers (this module)
//   0x10000 - 0x13FFF  SHM: 16 KB shared RAM (mailboxes + console rings)
//   0x40000 - 0x4007F  AXI Quad SPI flash controller (xbflash2 default offset)
//   0x80000 - 0xBFFFF  CPU program RAM, 256 KB
// Everything else reads as 0 and ignores writes.
//
// One transaction at a time: simple, and plenty fast for MMIO.
module host_if #(
    parameter [31:0] BUILD_TIME = 32'd0,
    parameter [31:0] VERSION    = 32'h0001_0000
) (
    input  wire        clk,
    input  wire        resetn,

    // AXI4-Lite slave (from XDMA m_axil)
    input  wire [31:0] s_awaddr,
    input  wire        s_awvalid,
    output reg         s_awready = 1'b0,
    input  wire [31:0] s_wdata,
    input  wire [3:0]  s_wstrb,
    input  wire        s_wvalid,
    output reg         s_wready = 1'b0,
    output reg  [1:0]  s_bresp = 2'b00,
    output reg         s_bvalid = 1'b0,
    input  wire        s_bready,
    input  wire [31:0] s_araddr,
    input  wire        s_arvalid,
    output reg         s_arready = 1'b0,
    output reg  [31:0] s_rdata = 32'd0,
    output reg  [1:0]  s_rresp = 2'b00,
    output reg         s_rvalid = 1'b0,
    input  wire        s_rready,

    // AXI4-Lite master to the AXI Quad SPI core
    output reg  [6:0]  q_awaddr = 7'd0,
    output reg         q_awvalid = 1'b0,
    input  wire        q_awready,
    output reg  [31:0] q_wdata = 32'd0,
    output reg  [3:0]  q_wstrb = 4'd0,
    output reg         q_wvalid = 1'b0,
    input  wire        q_wready,
    input  wire [1:0]  q_bresp,
    input  wire        q_bvalid,
    output reg         q_bready = 1'b0,
    output reg  [6:0]  q_araddr = 7'd0,
    output reg         q_arvalid = 1'b0,
    input  wire        q_arready,
    input  wire [31:0] q_rdata,
    input  wire [1:0]  q_rresp,
    input  wire        q_rvalid,
    output reg         q_rready = 1'b0,

    // program RAM, port A
    output reg         ram_en = 1'b0,
    output reg  [3:0]  ram_we = 4'd0,
    output reg  [15:0] ram_addr = 16'd0,
    output reg  [31:0] ram_wdata = 32'd0,
    input  wire [31:0] ram_rdata,

    // shared RAM, port A
    output reg         shm_en = 1'b0,
    output reg  [3:0]  shm_we = 4'd0,
    output reg  [11:0] shm_addr = 12'd0,
    output reg  [31:0] shm_wdata = 32'd0,
    input  wire [31:0] shm_rdata,

    // control / status (status inputs are already in this clock domain)
    output reg         cpu_hold = 1'b0,
    output reg         reload_toggle = 1'b0,
    input  wire        st_cpu_in_reset,
    input  wire        st_cpu_trap,
    input  wire        st_clk_locked,
    input  wire        st_reload_armed,
    input  wire [31:0] st_cpu_pc,
    input  wire [63:0] st_uptime
);
    localparam [31:0] MAGIC      = 32'h55C0_F00D;
    localparam [31:0] RELOAD_KEY = 32'h5245_4C44;   // "RELD"

    localparam S_IDLE = 3'd0, S_WR = 3'd1, S_WRESP = 3'd2, S_RD = 3'd3, S_RRESP = 3'd4;
    reg [2:0]  state = S_IDLE;
    reg [19:0] addr  = 20'd0;
    reg [31:0] wdata = 32'd0;
    reg [3:0]  wstrb = 4'd0;
    reg [1:0]  step  = 2'd0;
    reg [31:0] scratch = 32'd0;
    reg [31:0] uptime_hi_latch = 32'd0;

    wire rg_ctrl = (addr[19:16] == 4'h0);
    wire rg_shm  = (addr[19:16] == 4'h1);
    wire rg_qspi = (addr[19:18] == 2'b01);
    wire rg_ram  = (addr[19:18] == 2'b10);

    always @(posedge clk) begin
        s_awready <= 1'b0;
        s_wready  <= 1'b0;
        s_arready <= 1'b0;
        ram_en    <= 1'b0;
        ram_we    <= 4'd0;
        shm_en    <= 1'b0;
        shm_we    <= 4'd0;

        if (!resetn) begin
            state     <= S_IDLE;
            s_bvalid  <= 1'b0;
            s_rvalid  <= 1'b0;
            q_awvalid <= 1'b0;
            q_wvalid  <= 1'b0;
            q_bready  <= 1'b0;
            q_arvalid <= 1'b0;
            q_rready  <= 1'b0;
            cpu_hold  <= 1'b0;
        end else case (state)
        S_IDLE: begin
            if (s_awvalid && s_wvalid) begin
                s_awready <= 1'b1;
                s_wready  <= 1'b1;
                addr      <= s_awaddr[19:0];
                wdata     <= s_wdata;
                wstrb     <= s_wstrb;
                step      <= 2'd0;
                state     <= S_WR;
            end else if (s_arvalid) begin
                s_arready <= 1'b1;
                addr      <= s_araddr[19:0];
                step      <= 2'd0;
                state     <= S_RD;
            end
        end

        S_WR: begin
            s_bresp <= 2'b00;
            if (rg_qspi) begin
                // issue AW and W together, then wait for B
                case (step)
                    2'd0: begin
                        q_awaddr  <= addr[6:0];
                        q_wdata   <= wdata;
                        q_wstrb   <= wstrb;
                        q_awvalid <= 1'b1;
                        q_wvalid  <= 1'b1;
                        q_bready  <= 1'b1;
                        step      <= 2'd1;
                    end
                    default: begin
                        if (q_awvalid && q_awready) q_awvalid <= 1'b0;
                        if (q_wvalid  && q_wready)  q_wvalid  <= 1'b0;
                        if (q_bvalid) begin
                            q_bready <= 1'b0;
                            s_bresp  <= q_bresp;
                            s_bvalid <= 1'b1;
                            state    <= S_WRESP;
                        end
                    end
                endcase
            end else begin
                if (rg_ram) begin
                    ram_en    <= 1'b1;
                    ram_we    <= wstrb;
                    ram_addr  <= addr[17:2];
                    ram_wdata <= wdata;
                end else if (rg_shm) begin
                    shm_en    <= 1'b1;
                    shm_we    <= wstrb;
                    shm_addr  <= addr[13:2];
                    shm_wdata <= wdata;
                end else if (rg_ctrl) begin
                    case (addr[11:0])
                        12'h00C: scratch  <= wdata;
                        12'h010: cpu_hold <= wdata[0];
                        12'h030: if (wdata == RELOAD_KEY) reload_toggle <= ~reload_toggle;
                        default: ;
                    endcase
                end
                s_bvalid <= 1'b1;
                state    <= S_WRESP;
            end
        end

        S_WRESP: begin
            if (s_bready) begin
                s_bvalid <= 1'b0;
                state    <= S_IDLE;
            end
        end

        S_RD: begin
            s_rresp <= 2'b00;
            if (rg_qspi) begin
                case (step)
                    2'd0: begin
                        q_araddr  <= addr[6:0];
                        q_arvalid <= 1'b1;
                        q_rready  <= 1'b1;
                        step      <= 2'd1;
                    end
                    default: begin
                        if (q_arvalid && q_arready) q_arvalid <= 1'b0;
                        if (q_rvalid) begin
                            q_rready <= 1'b0;
                            s_rdata  <= q_rdata;
                            s_rresp  <= q_rresp;
                            s_rvalid <= 1'b1;
                            state    <= S_RRESP;
                        end
                    end
                endcase
            end else if (rg_ram || rg_shm) begin
                // step 0: enable; step 1: RAM output valid; step 2: capture
                case (step)
                    2'd0: begin
                        ram_en   <= rg_ram;
                        ram_addr <= addr[17:2];
                        shm_en   <= rg_shm;
                        shm_addr <= addr[13:2];
                        step     <= 2'd1;
                    end
                    2'd1: step <= 2'd2;
                    default: begin
                        s_rdata  <= rg_ram ? ram_rdata : shm_rdata;
                        s_rvalid <= 1'b1;
                        state    <= S_RRESP;
                    end
                endcase
            end else begin
                s_rdata <= 32'd0;
                if (rg_ctrl) case (addr[11:0])
                    12'h000: s_rdata <= MAGIC;
                    12'h004: s_rdata <= VERSION;
                    12'h008: s_rdata <= BUILD_TIME;
                    12'h00C: s_rdata <= scratch;
                    12'h010: s_rdata <= {31'd0, cpu_hold};
                    12'h014: s_rdata <= {28'd0, st_reload_armed, st_clk_locked, st_cpu_trap, st_cpu_in_reset};
                    12'h018: s_rdata <= st_cpu_pc;
                    12'h020: begin
                                 s_rdata         <= st_uptime[31:0];
                                 uptime_hi_latch <= st_uptime[63:32];
                             end
                    12'h024: s_rdata <= uptime_hi_latch;
                    12'h028: s_rdata <= 32'd100_000_000;
                    12'h030: s_rdata <= {31'd0, st_reload_armed};
                    12'h040: s_rdata <= 32'h0004_0000;   // program RAM size
                    12'h044: s_rdata <= 32'h0000_4000;   // SHM size
                    default: ;
                endcase
                s_rvalid <= 1'b1;
                state    <= S_RRESP;
            end
        end

        S_RRESP: begin
            if (s_rready) begin
                s_rvalid <= 1'b0;
                state    <= S_IDLE;
            end
        end

        default: state <= S_IDLE;
        endcase
    end
endmodule
