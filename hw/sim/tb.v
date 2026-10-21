`timescale 1ns / 1ps
// Testbench for u55c_core: acts as the host on the BAR0 AXI-Lite window
// (what XDMA does on the real card) and runs the real demo firmware.
//
//   make sim     (from the repository root)
//
// Checks: ID registers, console log + input over SHM, UART TX/RX, mailbox
// RPC, CPU hold/load/run over PCIe, trap reporting, flash-controller
// forwarding, and the reload (IPROG) arming path.
module tb;
    // ------------------------------------------------------------ clocks/resets
    reg clk100 = 0, aclk = 0;
    always #5 clk100 = ~clk100;          // 100 MHz
    always #2 aclk   = ~aclk;            // 250 MHz
    reg rst100 = 1, aresetn = 0;

    localparam CPB = 10;                 // UART clocks per bit in simulation

    // ------------------------------------------------------------ DUT
    reg  [31:0] awaddr = 0, wdata = 0, araddr = 0;
    reg  [3:0]  wstrb = 0;
    reg         awvalid = 0, wvalid = 0, bready = 0, arvalid = 0, rready = 0;
    wire        awready, wready, bvalid, arready, rvalid;
    wire [1:0]  bresp, rresp;
    wire [31:0] rdata;

    wire [6:0]  q_awaddr, q_araddr;
    wire [31:0] q_wdata;
    wire [3:0]  q_wstrb;
    wire        q_awvalid, q_wvalid, q_bready, q_arvalid, q_rready;
    reg         q_awready = 0, q_wready = 0, q_bvalid = 0, q_arready = 0, q_rvalid = 0;
    reg  [31:0] q_rdata = 0;

    wire [1:0]  uart_txd;
    reg         uart_rx0 = 1;
    wire [5:0]  led;

    u55c_core #(.BUILD_TIME(32'h1234_5678), .BAUD(100_000_000 / CPB), .RELOAD_DELAY(1000)) dut (
        .clk100(clk100), .rst100(rst100), .mmcm_locked(1'b1),
        .axi_aclk(aclk), .axi_aresetn(aresetn),
        .s_awaddr(awaddr), .s_awvalid(awvalid), .s_awready(awready),
        .s_wdata(wdata), .s_wstrb(wstrb), .s_wvalid(wvalid), .s_wready(wready),
        .s_bresp(bresp), .s_bvalid(bvalid), .s_bready(bready),
        .s_araddr(araddr), .s_arvalid(arvalid), .s_arready(arready),
        .s_rdata(rdata), .s_rresp(rresp), .s_rvalid(rvalid), .s_rready(rready),
        .q_awaddr(q_awaddr), .q_awvalid(q_awvalid), .q_awready(q_awready),
        .q_wdata(q_wdata), .q_wstrb(q_wstrb), .q_wvalid(q_wvalid), .q_wready(q_wready),
        .q_bresp(2'b00), .q_bvalid(q_bvalid), .q_bready(q_bready),
        .q_araddr(q_araddr), .q_arvalid(q_arvalid), .q_arready(q_arready),
        .q_rdata(q_rdata), .q_rresp(2'b00), .q_rvalid(q_rvalid), .q_rready(q_rready),
        .uart_txd(uart_txd), .uart_rxd({1'b1, uart_rx0}), .led(led));

    // ------------------------------------------------------------ flash-controller stub
    reg [6:0]  q_last_waddr = 0;
    reg [31:0] q_last_wdata = 0;
    always @(posedge aclk) begin
        q_awready <= 0; q_wready <= 0; q_arready <= 0;
        if (q_awvalid && q_wvalid && !q_awready && !q_bvalid) begin
            q_awready <= 1; q_wready <= 1;
            q_last_waddr <= q_awaddr; q_last_wdata <= q_wdata;
            q_bvalid <= 1;
        end else if (q_bvalid && q_bready) q_bvalid <= 0;
        if (q_arvalid && !q_arready && !q_rvalid) begin
            q_arready <= 1;
            q_rdata   <= 32'hA5A5_0000 | q_araddr;
            q_rvalid  <= 1;
        end else if (q_rvalid && q_rready) q_rvalid <= 0;
    end

    // ------------------------------------------------------------ AXI-Lite host tasks
    task axi_write(input [31:0] a, input [31:0] d, input [3:0] s);
        begin
            @(posedge aclk);
            awaddr <= a; wdata <= d; wstrb <= s; awvalid <= 1; wvalid <= 1; bready <= 1;
            @(posedge aclk);
            while (!(awready && wready)) @(posedge aclk);
            awvalid <= 0; wvalid <= 0;
            while (!bvalid) @(posedge aclk);
            @(posedge aclk);
            bready <= 0;
        end
    endtask

    task wr32(input [31:0] a, input [31:0] d);
        axi_write(a, d, 4'hF);
    endtask

    task rd32(input [31:0] a, output [31:0] d);
        begin
            @(posedge aclk);
            araddr <= a; arvalid <= 1; rready <= 1;
            @(posedge aclk);
            while (!arready) @(posedge aclk);
            arvalid <= 0;
            while (!rvalid) @(posedge aclk);
            d = rdata;
            @(posedge aclk);
            rready <= 0;
        end
    endtask

    integer errors = 0;
    task check(input [31:0] got, input [31:0] exp, input [8*40-1:0] what);
        if (got !== exp) begin
            $display("FAIL: %0s: got 0x%08x, expected 0x%08x", what, got, exp);
            errors = errors + 1;
        end else
            $display("ok:   %0s = 0x%08x", what, got);
    endtask

    // ------------------------------------------------------------ console over SHM (like u55c console)
    localparam SHM = 32'h10000;
    reg [31:0] log_rd = 0;
    reg [8*48-1:0] tail = 0;             // last 48 characters of the log
    reg [31:0] v;

    task poll_log;
        reg [31:0] wr, w;
        begin
            rd32(SHM + 32'h20, wr);
            if (wr < log_rd) log_rd = 0;     // firmware restarted
            while (log_rd != wr) begin
                rd32(SHM + 32'h2000 + ((log_rd % 8192) & ~3), w);
                v = (w >> (8 * (log_rd % 4))) & 8'hFF;
                if (v != 8'h0D) begin $write("%c", v[7:0]); tail = {tail[8*47-1:0], v[7:0]}; end
                log_rd = log_rd + 1;
            end
            wr32(SHM + 32'h24, log_rd);
        end
    endtask

    // wait until the log ends with the first n characters of s (s right-aligned)
    task wait_log(input [8*48-1:0] s, input integer n, input integer timeout_us);
        integer t;
        reg [8*48-1:0] mask;
        begin
            mask = (n >= 48) ? {8*48{1'b1}} : ((384'd1 << (8 * n)) - 1);
            t = 0;
            poll_log;
            while (((tail & mask) !== (s & mask)) && t < timeout_us) begin
                #1000;
                t = t + 1;
                poll_log;
            end
            if ((tail & mask) !== (s & mask)) begin
                $display("\nFAIL: timeout waiting for log text");
                errors = errors + 1;
            end
        end
    endtask

    // host -> firmware input ring (read-modify-write of 32-bit words)
    reg [31:0] in_wr = 0;
    task send_str(input [8*48-1:0] s, input integer n);
        integer i;
        reg [31:0] w, a;
        reg [7:0]  c;
        begin
            rd32(SHM + 32'h28, in_wr);
            for (i = n - 1; i >= 0; i = i - 1) begin
                c = s[8*i +: 8];
                a = SHM + 32'h1000 + ((in_wr % 4096) & ~3);
                axi_write(a, {4{c}}, 4'b0001 << (in_wr % 4));
                in_wr = in_wr + 1;
            end
            wr32(SHM + 32'h28, in_wr);
        end
    endtask

    // ------------------------------------------------------------ UART: monitor TX, drive RX
    wire       mon_v;
    wire [7:0] mon_d;
    uart_rx #(.CLKS_PER_BIT(CPB)) u_mon (.clk(clk100), .rst(1'b0), .rxd(uart_txd[0]), .valid(mon_v), .data(mon_d));
    integer uart_chars = 0;
    always @(posedge clk100) if (mon_v) uart_chars = uart_chars + 1;

    task uart_send(input [7:0] c);
        integer i;
        begin
            uart_rx0 = 0; repeat (CPB) @(posedge clk100);
            for (i = 0; i < 8; i = i + 1) begin uart_rx0 = c[i]; repeat (CPB) @(posedge clk100); end
            uart_rx0 = 1; repeat (2 * CPB) @(posedge clk100);
        end
    endtask

    task uart_send_str(input [8*48-1:0] s, input integer n);
        integer i;
        for (i = n - 1; i >= 0; i = i - 1) uart_send(s[8*i +: 8]);
    endtask

    // ------------------------------------------------------------ firmware image for the load test
    reg [31:0] fw [0:65535];
    integer fw_words;
    reg [8*256-1:0] fw_file;

    // ------------------------------------------------------------ test sequence
    reg [31:0] r, r2;
    integer i;
    initial begin
        if (!$value$plusargs("fw=%s", fw_file)) begin
            $display("usage: +fw=<demo.hex>");
            $finish;
        end
        for (i = 0; i < 65536; i = i + 1) fw[i] = 32'hxxxxxxxx;
        $readmemh(fw_file, fw);
        fw_words = 0;
        while (fw_words < 65536 && fw[fw_words] !== 32'hxxxxxxxx) fw_words = fw_words + 1;
        // preload, as the bitstream does
        for (i = 0; i < fw_words; i = i + 1) dut.u_ram.mem[i] = fw[i];

        #100; rst100 = 0; aresetn = 1;
        #200;

        $display("--- ID registers");
        rd32(32'h000, r); check(r, 32'h55C0_F00D, "MAGIC");
        rd32(32'h004, r); check(r, 32'h0001_0000, "VERSION");
        rd32(32'h008, r); check(r, 32'h1234_5678, "BUILD_TIME");
        wr32(32'h00C, 32'hDEAD_BEEF);
        rd32(32'h00C, r); check(r, 32'hDEAD_BEEF, "SCRATCH");
        rd32(32'h040, r); check(r, 32'h0004_0000, "RAM_SIZE");
        rd32(32'h444, r); check(r, 32'h0, "unmapped register");

        $display("--- firmware banner over the PCIe log");
        wait_log("type 'help' and press Enter\n> ", 30, 2000);
        rd32(SHM + 32'h30, r); check(r, 32'hC0DE_0001, "FW_MAGIC");
        rd32(SHM + 32'h34, r); check(r, 1, "FW_BOOTS");
        rd32(32'h014, r); check(r & 32'h7, 32'h4, "CPU_STATUS (running, clk ok)");
        $display("    UART TX characters so far: %0d", uart_chars);
        if (uart_chars < 30) begin $display("FAIL: UART output missing"); errors = errors + 1; end

        $display("--- console input over PCIe");
        send_str("help\015", 5);
        wait_log("trap reporting)\n> ", 18, 2000);

        $display("--- console input over UART");
        uart_send_str("echo hi-uart\015", 13);
        wait_log("hi-uart\n> ", 10, 2000);

        $display("--- mailbox RPC");
        wr32(SHM + 32'h04, 41); wr32(SHM + 32'h00, 1);
        r = 1; i = 0;
        while (r != 0 && i < 1000) begin rd32(SHM + 32'h00, r); i = i + 1; end
        rd32(SHM + 32'h04, r); check(r, 42, "MBOX ping(41)");
        wr32(SHM + 32'h04, 5); wr32(SHM + 32'h08, 7); wr32(SHM + 32'h00, 2);
        r = 1; i = 0;
        while (r != 0 && i < 1000) begin rd32(SHM + 32'h00, r); i = i + 1; end
        rd32(SHM + 32'h04, r); check(r, 12, "MBOX add(5,7)");

        $display("--- uptime counter");
        rd32(32'h020, r); rd32(32'h024, r2);
        #2000;
        rd32(32'h020, v);
        if (v - r < 150 || v - r > 300) begin $display("FAIL: uptime delta %0d", v - r); errors = errors + 1; end
        else $display("ok:   uptime advanced %0d ticks in 2 us", v - r);

        $display("--- hold CPU, load firmware over PCIe, run");
        wr32(32'h010, 1);
        #200;
        rd32(32'h014, r); check(r & 32'h1, 1, "CPU_STATUS.IN_RESET");
        for (i = 0; i < 64; i = i + 1) wr32(32'h80000 + 4 * i, 32'h0);    // scribble
        for (i = 0; i < fw_words; i = i + 1) wr32(32'h80000 + 4 * i, fw[i]);
        rd32(32'h80000, r); check(r, fw[0], "RAM[0] readback");
        rd32(32'h80000 + 4 * (fw_words - 1), r); check(r, fw[fw_words - 1], "RAM[last] readback");
        axi_write(32'h80001, 32'h0000_AB00, 4'b0010);                     // byte write
        rd32(32'h80000, r); check(r, {fw[0][31:16], 8'hAB, fw[0][7:0]}, "RAM byte-strobe write");
        wr32(32'h80000, fw[0]);
        wr32(32'h010, 0);
        wait_log("boot #2, CPU clock 100000000 Hz", 31, 3000);
        wait_log("type 'help' and press Enter\n> ", 30, 2000);

        $display("--- trap reporting");
        send_str("trap\015", 5);
        wait_log("will show TRAP\n", 15, 2000);
        #2000;
        rd32(32'h014, r); check(r & 32'h3, 32'h2, "CPU_STATUS.TRAP");
        rd32(32'h018, r); $display("    CPU_PC at trap = 0x%08x", r);

        $display("--- flash controller window (BAR0 + 0x40000)");
        wr32(32'h40060, 32'h0000_0186);
        check({25'd0, q_last_waddr}, 32'h60, "QSPI write address");
        check(q_last_wdata, 32'h0000_0186, "QSPI write data");
        rd32(32'h40064, r); check(r, 32'hA5A5_0064, "QSPI read forwarded");

        $display("--- FPGA reload arming");
        rd32(32'h030, r); check(r, 0, "RELOAD idle");
        wr32(32'h030, 32'h1234_5678);                                     // wrong key: ignored
        #200; rd32(32'h030, r); check(r, 0, "RELOAD wrong key ignored");
        wr32(32'h030, 32'h5245_4C44);
        #300; rd32(32'h030, r); check(r, 1, "RELOAD armed");
        #20000;
        check({28'd0, dut.u_iprog.idx}, 8, "ICAP sequence words written");

        if (errors == 0) $display("\nTB PASS");
        else             $display("\nTB FAIL: %0d error(s)", errors);
        $finish;
    end

    initial begin
        #50_000_000;
        $display("TB FAIL: global timeout");
        $finish;
    end
endmodule
