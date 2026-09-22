// ============================================================
// mem_arbiter.v
// Fixed-priority arbiter (DMA wins ties) between two AXI4-Lite
// write masters (dma_master.v, cpu_master.v) and one shared
// single-port memory (shared_spmem.v).
//
// This first version is a CORRECT, working arbiter -- it
// properly respects mem_busy and only grants one master at a
// time. A deliberate flaw is introduced in a later, separate
// step to produce a real deadlock for the study; this module
// is the "before" baseline.
//
// AXI4-Lite side: each master gets its own AW/W/B channel set.
// Memory side: single shared mem_en/mem_we/mem_addr/mem_wdata
// port, per shared_spmem.v.
// ============================================================

module mem_arbiter #(
    parameter ADDR_WIDTH = 32,      // AXI-side address width (masters)
    parameter MEM_ADDR_WIDTH = 8,   // shared_spmem address width
    parameter DATA_WIDTH = 32
)(
    input  wire                     clk,
    input  wire                     rst_n,

    // ---- DMA master AXI4-Lite write side (slave role here) ----
    input  wire [ADDR_WIDTH-1:0]    dma_awaddr,
    input  wire                     dma_awvalid,
    output reg                      dma_awready,
    input  wire [DATA_WIDTH-1:0]    dma_wdata,
    input  wire                     dma_wvalid,
    output reg                      dma_wready,
    output reg  [1:0]               dma_bresp,
    output reg                      dma_bvalid,
    input  wire                     dma_bready,

    // ---- CPU master AXI4-Lite write side (slave role here) ----
    input  wire [ADDR_WIDTH-1:0]    cpu_awaddr,
    input  wire                     cpu_awvalid,
    output reg                      cpu_awready,
    input  wire [DATA_WIDTH-1:0]    cpu_wdata,
    input  wire                     cpu_wvalid,
    output reg                      cpu_wready,
    output reg  [1:0]               cpu_bresp,
    output reg                      cpu_bvalid,
    input  wire                     cpu_bready,

    // ---- Shared memory port (master role here) ----
    output reg                      mem_en,
    output reg                      mem_we,
    output reg  [MEM_ADDR_WIDTH-1:0] mem_addr,
    output reg  [DATA_WIDTH-1:0]    mem_wdata,
    input  wire [DATA_WIDTH-1:0]    mem_rdata,
    input  wire                     mem_rvalid,
    input  wire                     mem_busy
);

    localparam OKAY = 2'b00;

    // Per-master simple AXI4-Lite write FSM states (mirrored for each grantee)
    localparam S_IDLE   = 3'd0,
               S_AW      = 3'd1,
               S_W       = 3'd2,
               S_ISSUE   = 3'd3,  // drive mem_en for the granted access
               S_WAIT    = 3'd4,  // wait for mem_busy to clear (access in flight)
               S_B       = 3'd5;

    reg [2:0] state;
    reg       grant; // 0 = DMA, 1 = CPU -- which master currently owns the arbiter

    // Latched per-transaction fields for whichever master is granted
    reg [ADDR_WIDTH-1:0] cur_awaddr;
    reg [DATA_WIDTH-1:0] cur_wdata;

    // Fixed-priority request signal: DMA wins ties.
    wire dma_req = dma_awvalid;
    wire cpu_req = cpu_awvalid;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state       <= S_IDLE;
            grant       <= 1'b0;
            cur_awaddr  <= {ADDR_WIDTH{1'b0}};
            cur_wdata   <= {DATA_WIDTH{1'b0}};

            dma_awready <= 1'b0;
            dma_wready  <= 1'b0;
            dma_bvalid  <= 1'b0;
            dma_bresp   <= 2'b00;

            cpu_awready <= 1'b0;
            cpu_wready  <= 1'b0;
            cpu_bvalid  <= 1'b0;
            cpu_bresp   <= 2'b00;

            mem_en      <= 1'b0;
            mem_we      <= 1'b0;
            mem_addr    <= {MEM_ADDR_WIDTH{1'b0}};
            mem_wdata   <= {DATA_WIDTH{1'b0}};
        end else begin
            // Default: deassert single-cycle pulses each clock unless set below.
            dma_awready <= 1'b0;
            dma_wready  <= 1'b0;
            cpu_awready <= 1'b0;
            cpu_wready  <= 1'b0;
            mem_en      <= 1'b0;

            case (state)
                // -----------------------------------------
                S_IDLE: begin
                    dma_bvalid <= 1'b0;
                    cpu_bvalid <= 1'b0;

                    // Fixed priority: DMA wins ties.
                    if (dma_req) begin
                        grant       <= 1'b0;
                        dma_awready <= 1'b1;
                        state       <= S_AW;
                    end else if (cpu_req) begin
                        grant       <= 1'b1;
                        cpu_awready <= 1'b1;
                        state       <= S_AW;
                    end
                end

                // -----------------------------------------
                // AWREADY was pulsed last cycle; latch address now.
                S_AW: begin
                    if (grant == 1'b0) begin
                        cur_awaddr <= dma_awaddr;
                    end else begin
                        cur_awaddr <= cpu_awaddr;
                    end
                    state <= S_W;
                end

                // -----------------------------------------
                // Hold WREADY asserted (level-sensitive) until the
                // granted master actually asserts WVALID -- a master
                // may take one or more cycles after AWREADY to reach
                // its own write-data state, so WREADY must not be a
                // single unconditional pulse here.
                S_W: begin
                    if (grant == 1'b0) begin
                        dma_wready <= 1'b1;
                        if (dma_wvalid) begin
                            dma_wready <= 1'b0;
                            cur_wdata  <= dma_wdata;
                            state      <= S_ISSUE;
                        end
                    end else begin
                        cpu_wready <= 1'b1;
                        if (cpu_wvalid) begin
                            cpu_wready <= 1'b0;
                            cur_wdata  <= cpu_wdata;
                            state      <= S_ISSUE;
                        end
                    end
                end

                // -----------------------------------------
                // Issue the access to shared memory -- only if not busy.
                // Correct behavior: never assert mem_en while mem_busy is high.
                S_ISSUE: begin
                    if (!mem_busy) begin
                        mem_en    <= 1'b1;
                        mem_we    <= 1'b1; // write-only masters for now
                        mem_addr  <= cur_awaddr[MEM_ADDR_WIDTH-1:0];
                        mem_wdata <= cur_wdata;
                        state     <= S_WAIT;
                    end
                    // else: stay here, keep waiting for memory to be free
                end

                // -----------------------------------------
                // Wait for the access to complete (mem_busy deasserts).
                S_WAIT: begin
                    if (!mem_busy) begin
                        state <= S_B;
                    end
                end

                // -----------------------------------------
                // Return write response (BVALID) to the granted master.
                S_B: begin
                    if (grant == 1'b0) begin
                        dma_bvalid <= 1'b1;
                        dma_bresp  <= OKAY;
                        if (dma_bvalid && dma_bready) begin
                            dma_bvalid <= 1'b0;
                            state      <= S_IDLE;
                        end
                    end else begin
                        cpu_bvalid <= 1'b1;
                        cpu_bresp  <= OKAY;
                        if (cpu_bvalid && cpu_bready) begin
                            cpu_bvalid <= 1'b0;
                            state      <= S_IDLE;
                        end
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule