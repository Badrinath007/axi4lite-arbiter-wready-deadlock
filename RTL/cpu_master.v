// ============================================================
// cpu_master.v
// Second AXI4-Lite bus-master (write-only), same style as
// dma_master.v but a shorter, 2-beat burst so its waveform
// activity is easy to visually distinguish from the DMA
// master's 4-beat burst during contention analysis.
//
// Represents a second, independent hardware requester
// contending with dma_master.v for shared_spmem.v through
// the arbiter (next module). Not a real CPU/software model --
// just a second real AXI4-Lite master, per the earlier
// decision to keep this as two symmetric hardware masters
// rather than modeling an actual processor.
// ============================================================

module cpu_master #(
    parameter ADDR_WIDTH = 32,
    parameter DATA_WIDTH = 32,
    parameter BASE_ADDR  = 32'h0000_2000,
    parameter ADDR_STEP  = 32'h0000_0004,
    parameter BURST_LEN  = 2
)(
    input  wire                     clk,
    input  wire                     rst_n,

    input  wire                     start,
    output reg                      done,
    output reg                      error,

    output reg  [ADDR_WIDTH-1:0]    m_awaddr,
    output reg                      m_awvalid,
    input  wire                     m_awready,

    output reg  [DATA_WIDTH-1:0]    m_wdata,
    output reg  [(DATA_WIDTH/8)-1:0] m_wstrb,
    output reg                      m_wvalid,
    input  wire                     m_wready,

    input  wire [1:0]               m_bresp,
    input  wire                     m_bvalid,
    output reg                      m_bready
);

    localparam OKAY = 2'b00;

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
                S_IDLE: begin
                    done  <= 1'b0;
                    error <= 1'b0;
                    if (start) begin
                        cur_addr      <= BASE_ADDR;
                        wdata_pattern <= {{(DATA_WIDTH-8){1'b0}}, 8'hC0};
                        beat_cnt      <= 0;
                        state         <= S_AW;
                    end
                end

                S_AW: begin
                    m_awaddr  <= cur_addr;
                    m_awvalid <= 1'b1;
                    if (m_awvalid && m_awready) begin
                        m_awvalid <= 1'b0;
                        state     <= S_W;
                    end
                end

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

                S_B: begin
                    if (m_bvalid && m_bready) begin
                        m_bready <= 1'b0;
                        if (m_bresp != OKAY)
                            error <= 1'b1;
                        state <= S_NEXT;
                    end
                end

                S_NEXT: begin
                    if (beat_cnt == BURST_LEN - 1) begin
                        state <= S_DONE;
                    end else begin
                        beat_cnt <= beat_cnt + 1'b1;
                        cur_addr <= cur_addr + ADDR_STEP;
                        state    <= S_AW;
                    end
                end

                S_DONE: begin
                    done <= 1'b1;
                    if (!start) begin
                        state <= S_IDLE;
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule