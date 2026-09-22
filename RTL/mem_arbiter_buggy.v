// ============================================================
// mem_arbiter_buggy.v
// DELIBERATELY REVERTED copy of mem_arbiter.v, module renamed
// to mem_arbiter_buggy so it can coexist with the fixed
// mem_arbiter.v in the same project.
//
// This restores the ORIGINAL bug: wready is asserted for only
// one cycle (during S_AW), instead of being held until wvalid
// arrives during S_W. Use this ONLY to capture the "before"
// waveform showing the real deadlock as portfolio evidence --
// it is expected to hang when run with the concurrent
// integration testbench (rename the instantiated module in a
// copy of arbiter_integration_tb.v to mem_arbiter_buggy to use
// it, then Break the sim and dump the waveform once it's stuck).
// ============================================================

module mem_arbiter_buggy #(
    parameter ADDR_WIDTH = 32,
    parameter MEM_ADDR_WIDTH = 8,
    parameter DATA_WIDTH = 32
)(
    input  wire                     clk,
    input  wire                     rst_n,

    input  wire [ADDR_WIDTH-1:0]    dma_awaddr,
    input  wire                     dma_awvalid,
    output reg                      dma_awready,
    input  wire [DATA_WIDTH-1:0]    dma_wdata,
    input  wire                     dma_wvalid,
    output reg                      dma_wready,
    output reg  [1:0]               dma_bresp,
    output reg                      dma_bvalid,
    input  wire                     dma_bready,

    input  wire [ADDR_WIDTH-1:0]    cpu_awaddr,
    input  wire                     cpu_awvalid,
    output reg                      cpu_awready,
    input  wire [DATA_WIDTH-1:0]    cpu_wdata,
    input  wire                     cpu_wvalid,
    output reg                      cpu_wready,
    output reg  [1:0]               cpu_bresp,
    output reg                      cpu_bvalid,
    input  wire                     cpu_bready,

    output reg                      mem_en,
    output reg                      mem_we,
    output reg  [MEM_ADDR_WIDTH-1:0] mem_addr,
    output reg  [DATA_WIDTH-1:0]    mem_wdata,
    input  wire [DATA_WIDTH-1:0]    mem_rdata,
    input  wire                     mem_rvalid,
    input  wire                     mem_busy
);

    localparam OKAY = 2'b00;

    localparam S_IDLE   = 3'd0,
               S_AW      = 3'd1,
               S_W       = 3'd2,
               S_ISSUE   = 3'd3,
               S_WAIT    = 3'd4,
               S_B       = 3'd5;

    reg [2:0] state;
    reg       grant;

    reg [ADDR_WIDTH-1:0] cur_awaddr;
    reg [DATA_WIDTH-1:0] cur_wdata;

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
            dma_awready <= 1'b0;
            dma_wready  <= 1'b0;   // <-- BUG: default-deasserted every cycle,
            cpu_awready <= 1'b0;   //     only overridden for ONE cycle below
            cpu_wready  <= 1'b0;
            mem_en      <= 1'b0;

            case (state)
                S_IDLE: begin
                    dma_bvalid <= 1'b0;
                    cpu_bvalid <= 1'b0;

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

                // ---- BUG REINTRODUCED HERE ----
                // wready is pulsed for exactly this one cycle (S_AW),
                // then falls back to the default 0 above as soon as
                // the FSM moves to S_W -- before the granted master
                // has had a chance to reach ITS OWN S_W state and
                // check for wready. This is the original deadlock.
                S_AW: begin
                    if (grant == 1'b0) begin
                        cur_awaddr <= dma_awaddr;
                        dma_wready <= 1'b1; // one-cycle pulse -- BUG
                    end else begin
                        cur_awaddr <= cpu_awaddr;
                        cpu_wready <= 1'b1; // one-cycle pulse -- BUG
                    end
                    state <= S_W;
                end

                S_W: begin
                    // wready is NOT reasserted here -- already dropped
                    // back to 0 by the default assignment above.
                    if (grant == 1'b0) begin
                        if (dma_wvalid) begin
                            cur_wdata <= dma_wdata;
                            state     <= S_ISSUE;
                        end
                        // else: stuck here forever, dma_wready is 0
                        // and dma_master is waiting for it to be 1
                    end else begin
                        if (cpu_wvalid) begin
                            cur_wdata <= cpu_wdata;
                            state     <= S_ISSUE;
                        end
                    end
                end

                S_ISSUE: begin
                    if (!mem_busy) begin
                        mem_en    <= 1'b1;
                        mem_we    <= 1'b1;
                        mem_addr  <= cur_awaddr[MEM_ADDR_WIDTH-1:0];
                        mem_wdata <= cur_wdata;
                        state     <= S_WAIT;
                    end
                end

                S_WAIT: begin
                    if (!mem_busy) begin
                        state <= S_B;
                    end
                end

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