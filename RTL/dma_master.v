// ============================================================
// dma_master.v
// Simple AXI4-Lite bus-master (write-only), fixed-length burst.
// Issues 4 sequential write transactions to consecutive addresses
// starting at BASE_ADDR, incrementing by ADDR_STEP each beat.
//
// Intended use: contend with an existing AXI4-Lite slave-side
// access path for a shared single-port memory, arbitrated by an
// external arbiter (added in a later step). Not a full DMA engine
// (no descriptors, no interrupts, no read channel) -- scoped for
// an arbitration/deadlock study.
// ============================================================

module dma_master #(
    parameter ADDR_WIDTH = 32,
    parameter DATA_WIDTH = 32,
    parameter BASE_ADDR  = 32'h0000_1000,
    parameter ADDR_STEP  = 32'h0000_0004,
    parameter BURST_LEN  = 4
)(
    input  wire                     clk,
    input  wire                     rst_n,

    // Control
    input  wire                     start,
    output reg                      done,
    output reg                      error,      // set if any BRESP != OKAY

    // AXI4-Lite write address channel
    output reg  [ADDR_WIDTH-1:0]    m_awaddr,
    output reg                      m_awvalid,
    input  wire                     m_awready,

    // AXI4-Lite write data channel
    output reg  [DATA_WIDTH-1:0]    m_wdata,
    output reg  [(DATA_WIDTH/8)-1:0] m_wstrb,
    output reg                      m_wvalid,
    input  wire                     m_wready,

    // AXI4-Lite write response channel
    input  wire [1:0]               m_bresp,
    input  wire                     m_bvalid,
    output reg                      m_bready
);

    localparam OKAY = 2'b00;

    // FSM states
    localparam S_IDLE   = 3'd0,
               S_AW      = 3'd1,
               S_W       = 3'd2,
               S_B       = 3'd3,
               S_NEXT    = 3'd4,
               S_DONE    = 3'd5;

    reg [2:0]  state;
    reg [$clog2(BURST_LEN+1)-1:0] beat_cnt;
    reg [ADDR_WIDTH-1:0] cur_addr;
    reg [DATA_WIDTH-1:0] wdata_pattern;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state         <= S_IDLE;
            beat_cnt      <= 0;
            cur_addr      <= BASE_ADDR;
            wdata_pattern <= {DATA_WIDTH{1'b0}};
            m_awaddr      <= {ADDR_WIDTH{1'b0}};
            m_awvalid     <= 1'b0;
            m_wdata       <= {DATA_WIDTH{1'b0}};
            m_wstrb       <= {(DATA_WIDTH/8){1'b1}};
            m_wvalid      <= 1'b0;
            m_bready      <= 1'b0;
            done          <= 1'b0;
            error         <= 1'b0;
        end else begin
            case (state)
                // ---------------------------------------------
                S_IDLE: begin
                    done  <= 1'b0;
                    error <= 1'b0;
                    if (start) begin
                        cur_addr      <= BASE_ADDR;
                        wdata_pattern <= {{(DATA_WIDTH-8){1'b0}}, 8'hA0}; // simple pattern, increments per beat
                        beat_cnt      <= 0;
                        state         <= S_AW;
                    end
                end

                // ---------------------------------------------
                // Address write: assert AWVALID/AWADDR, wait for AWREADY
                S_AW: begin
                    m_awaddr  <= cur_addr;
                    m_awvalid <= 1'b1;
                    if (m_awvalid && m_awready) begin
                        m_awvalid <= 1'b0;
                        state     <= S_W;
                    end
                end

                // ---------------------------------------------
                // Write data: assert WVALID/WDATA, wait for WREADY
                S_W: begin
                    m_wdata  <= wdata_pattern + beat_cnt;
                    m_wstrb  <= {(DATA_WIDTH/8){1'b1}};
                    m_wvalid <= 1'b1;
                    if (m_wvalid && m_wready) begin
                        m_wvalid <= 1'b0;
                        m_bready <= 1'b1;
                        state    <= S_B;
                    end
                end

                // ---------------------------------------------
                // Write response: wait for BVALID, check BRESP
                S_B: begin
                    if (m_bvalid && m_bready) begin
                        m_bready <= 1'b0;
                        if (m_bresp != OKAY)
                            error <= 1'b1;
                        state <= S_NEXT;
                    end
                end

                // ---------------------------------------------
                // Advance to next beat or finish
                S_NEXT: begin
                    if (beat_cnt == BURST_LEN - 1) begin
                        state <= S_DONE;
                    end else begin
                        beat_cnt <= beat_cnt + 1'b1;
                        cur_addr <= cur_addr + ADDR_STEP;
                        state    <= S_AW;
                    end
                end

                // ---------------------------------------------
                S_DONE: begin
                    done <= 1'b1;
                    if (!start) begin
                        // wait for start to deassert before re-arming,
                        // avoids re-triggering on a held start signal
                        state <= S_IDLE;
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule