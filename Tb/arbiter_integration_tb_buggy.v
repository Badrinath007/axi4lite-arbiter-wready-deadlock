// ============================================================
// arbiter_integration_tb.v
// Concurrent integration test: drives dma_master (4-beat burst)
// and cpu_master (2-beat burst) at overlapping times through
// mem_arbiter into shared_spmem. This is the working "before"
// baseline -- confirms correct fixed-priority arbitration with
// no deliberate bug yet.
// ============================================================

`timescale 1ns / 1ps

module arbiter_integration_tb;

    localparam ADDR_WIDTH     = 32;
    localparam MEM_ADDR_WIDTH = 8;
    localparam DATA_WIDTH     = 32;

    reg clk;
    reg rst_n;

    // ---- DMA master signals ----
    reg  dma_start;
    wire dma_done, dma_error;
    wire [ADDR_WIDTH-1:0] dma_awaddr;
    wire dma_awvalid, dma_awready;
    wire [DATA_WIDTH-1:0] dma_wdata;
    wire [(DATA_WIDTH/8)-1:0] dma_wstrb;
    wire dma_wvalid, dma_wready;
    wire [1:0] dma_bresp;
    wire dma_bvalid, dma_bready;

    // ---- CPU master signals ----
    reg  cpu_start;
    wire cpu_done, cpu_error;
    wire [ADDR_WIDTH-1:0] cpu_awaddr;
    wire cpu_awvalid, cpu_awready;
    wire [DATA_WIDTH-1:0] cpu_wdata;
    wire [(DATA_WIDTH/8)-1:0] cpu_wstrb;
    wire cpu_wvalid, cpu_wready;
    wire [1:0] cpu_bresp;
    wire cpu_bvalid, cpu_bready;

    // ---- Shared memory port (arbiter side) ----
    wire                      arb_mem_en, arb_mem_we;
    wire [MEM_ADDR_WIDTH-1:0] arb_mem_addr;
    wire [DATA_WIDTH-1:0]     arb_mem_wdata;

    // ---- Testbench read-back checker override signals ----
    reg                       chk_en;
    reg                       chk_we;
    reg  [MEM_ADDR_WIDTH-1:0] chk_addr;

    // Muxed signals actually driving shared_spmem: checker wins
    // whenever it's active (chk_en), otherwise arbiter drives it.
    // Checker is only ever used after both masters report done
    // and mem_busy is low, so there's no real contention between
    // the two sources in practice.
    wire                      mem_en   = chk_en   ? 1'b1      : arb_mem_en;
    wire                      mem_we   = chk_en   ? chk_we    : arb_mem_we;
    wire [MEM_ADDR_WIDTH-1:0] mem_addr = chk_en   ? chk_addr  : arb_mem_addr;
    wire [DATA_WIDTH-1:0]     mem_wdata = arb_mem_wdata; // write-only from arbiter; checker never writes

    wire [DATA_WIDTH-1:0]     mem_rdata;
    wire                      mem_rvalid, mem_busy;

    integer errors = 0;

    // -----------------------------
    // DUTs
    // -----------------------------
    dma_master #(
        .ADDR_WIDTH(ADDR_WIDTH), .DATA_WIDTH(DATA_WIDTH),
        .BASE_ADDR(32'h0000_0010), .ADDR_STEP(32'h0000_0004), .BURST_LEN(4)
    ) u_dma (
        .clk(clk), .rst_n(rst_n),
        .start(dma_start), .done(dma_done), .error(dma_error),
        .m_awaddr(dma_awaddr), .m_awvalid(dma_awvalid), .m_awready(dma_awready),
        .m_wdata(dma_wdata), .m_wstrb(dma_wstrb), .m_wvalid(dma_wvalid), .m_wready(dma_wready),
        .m_bresp(dma_bresp), .m_bvalid(dma_bvalid), .m_bready(dma_bready)
    );

    cpu_master #(
        .ADDR_WIDTH(ADDR_WIDTH), .DATA_WIDTH(DATA_WIDTH),
        .BASE_ADDR(32'h0000_0040), .ADDR_STEP(32'h0000_0004), .BURST_LEN(2)
    ) u_cpu (
        .clk(clk), .rst_n(rst_n),
        .start(cpu_start), .done(cpu_done), .error(cpu_error),
        .m_awaddr(cpu_awaddr), .m_awvalid(cpu_awvalid), .m_awready(cpu_awready),
        .m_wdata(cpu_wdata), .m_wstrb(cpu_wstrb), .m_wvalid(cpu_wvalid), .m_wready(cpu_wready),
        .m_bresp(cpu_bresp), .m_bvalid(cpu_bvalid), .m_bready(cpu_bready)
    );

    mem_arbiter_buggy #(
        .ADDR_WIDTH(ADDR_WIDTH), .MEM_ADDR_WIDTH(MEM_ADDR_WIDTH), .DATA_WIDTH(DATA_WIDTH)
    ) u_arb (
        .clk(clk), .rst_n(rst_n),
        .dma_awaddr(dma_awaddr), .dma_awvalid(dma_awvalid), .dma_awready(dma_awready),
        .dma_wdata(dma_wdata), .dma_wvalid(dma_wvalid), .dma_wready(dma_wready),
        .dma_bresp(dma_bresp), .dma_bvalid(dma_bvalid), .dma_bready(dma_bready),
        .cpu_awaddr(cpu_awaddr), .cpu_awvalid(cpu_awvalid), .cpu_awready(cpu_awready),
        .cpu_wdata(cpu_wdata), .cpu_wvalid(cpu_wvalid), .cpu_wready(cpu_wready),
        .cpu_bresp(cpu_bresp), .cpu_bvalid(cpu_bvalid), .cpu_bready(cpu_bready),
        .mem_en(arb_mem_en), .mem_we(arb_mem_we), .mem_addr(arb_mem_addr), .mem_wdata(arb_mem_wdata),
        .mem_rdata(mem_rdata), .mem_rvalid(mem_rvalid), .mem_busy(mem_busy)
    );

    shared_spmem #(
        .ADDR_WIDTH(MEM_ADDR_WIDTH), .DATA_WIDTH(DATA_WIDTH), .ACCESS_DELAY(3)
    ) u_mem (
        .clk(clk), .rst_n(rst_n),
        .mem_en(mem_en), .mem_we(mem_we), .mem_addr(mem_addr), .mem_wdata(mem_wdata),
        .mem_rdata(mem_rdata), .mem_rvalid(mem_rvalid), .mem_busy(mem_busy)
    );

    // -----------------------------
    // Clock
    // -----------------------------
    initial clk = 1'b0;
    always #5 clk = ~clk;

    // -----------------------------
    // Stimulus: start both masters with a slight stagger so their
    // requests genuinely overlap and force the arbiter to choose.
    // -----------------------------
    initial begin
        rst_n     = 1'b0;
        dma_start = 1'b0;
        cpu_start = 1'b0;
        chk_en    = 1'b0;
        chk_we    = 1'b0;
        chk_addr  = {MEM_ADDR_WIDTH{1'b0}};
        #23;
        rst_n = 1'b1;

        @(posedge clk);
        dma_start = 1'b1;

        // Stagger CPU start by 2 cycles so both are pending near-simultaneously
        #20;
        cpu_start = 1'b1;

	fork
    	begin
        	wait (dma_done == 1'b1 && cpu_done == 1'b1);
        	disable watchdog;
    	end
    	begin : watchdog
		#5000;
        	$display("HUNG: simulation stuck waiting on dma_done/cpu_done at time %0t", $time);
        	$finish;
    	end
	join

        // Wait for both to finish
        wait (dma_done == 1'b1 && cpu_done == 1'b1);
        @(posedge clk);
        dma_start = 1'b0;
        cpu_start = 1'b0;

        #40;

        if (dma_error) begin
            $display("FAIL: dma_master reported error");
            errors = errors + 1;
        end
        if (cpu_error) begin
            $display("FAIL: cpu_master reported error");
            errors = errors + 1;
        end

        // Read back and verify DMA's 4 beats: base 0x10, step 4, pattern 0xA0+i
        verify_mem(8'h10, 32'h000000A0);
        verify_mem(8'h14, 32'h000000A1);
        verify_mem(8'h18, 32'h000000A2);
        verify_mem(8'h1C, 32'h000000A3);

        // Read back and verify CPU's 2 beats: base 0x40, step 4, pattern 0xC0+i
        verify_mem(8'h40, 32'h000000C0);
        verify_mem(8'h44, 32'h000000C1);

        #20;
        if (errors == 0)
            $display("PASS: arbiter_integration_tb completed, 0 errors");
        else
            $display("FAIL: arbiter_integration_tb completed with %0d error(s)", errors);

        $finish;
    end

    // Direct memory read-back check, bypassing the arbiter/masters.
    // Drives shared_spmem's port via the chk_* override signals
    // (muxed in above) instead of force/release -- avoids
    // QuestaSim's restriction on force targeting a signal indexed
    // by an automatic task argument.
    task verify_mem(input [MEM_ADDR_WIDTH-1:0] addr, input [DATA_WIDTH-1:0] expected);
        begin
            wait (mem_busy == 1'b0);
            @(negedge clk);
            chk_en   = 1'b1;
            chk_we   = 1'b0;
            chk_addr = addr;
            @(negedge clk);
            chk_en   = 1'b0;
            wait (u_mem.mem_rvalid == 1'b1);
            @(negedge clk);
            if (u_mem.mem_rdata !== expected) begin
                $display("[%0t] FAIL: addr 0x%0h = 0x%h, expected 0x%h", $time, addr, u_mem.mem_rdata, expected);
                errors = errors + 1;
            end else begin
                $display("[%0t] PASS: addr 0x%0h = 0x%h", $time, addr, u_mem.mem_rdata);
            end
            wait (mem_busy == 1'b0);
        end
    endtask

    initial begin
        $dumpfile("arbiter_integration_tb.vcd");
        $dumpvars(0, arbiter_integration_tb);
    end

endmodule