// ============================================================
// shared_spmem.v (v2 -- backpressure-capable)
// Single-port shared memory slave with a fixed-delay busy
// window on every access, modeling a realistic slow shared
// resource. The arbiter must respect mem_busy correctly --
// granting a new access while busy, or mishandling a pending
// request across busy cycles, is exactly the class of bug
// that produces real contention deadlocks.
//
// No AXI handshake here -- the arbiter speaks AXI4-Lite to
// each master and translates to this plain access port.
// ============================================================

module shared_spmem #(
    parameter ADDR_WIDTH   = 8,     // 256 words
    parameter DATA_WIDTH   = 32,
    parameter ACCESS_DELAY = 3      // fixed cycles memory stays busy per access
)(
    input  wire                     clk,
    input  wire                     rst_n,

    // Single access port -- arbiter drives these
    input  wire                     mem_en,      // access request this cycle (only valid if !mem_busy)
    input  wire                     mem_we,      // 1 = write, 0 = read
    input  wire [ADDR_WIDTH-1:0]    mem_addr,
    input  wire [DATA_WIDTH-1:0]    mem_wdata,
    output reg  [DATA_WIDTH-1:0]    mem_rdata,
    output reg                      mem_rvalid,  // read data valid, pulses once when delay completes
    output wire                     mem_busy     // memory is servicing a prior access; do not assert mem_en
);

    reg [DATA_WIDTH-1:0] mem [0:(1<<ADDR_WIDTH)-1];

    localparam CNT_WIDTH = $clog2(ACCESS_DELAY+1);
    reg [CNT_WIDTH-1:0]  delay_cnt;
    reg                  busy_r;
    reg                  pending_we;
    reg [ADDR_WIDTH-1:0] pending_addr;
    reg [DATA_WIDTH-1:0] pending_wdata;

    assign mem_busy = busy_r;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            busy_r        <= 1'b0;
            delay_cnt     <= {CNT_WIDTH{1'b0}};
            mem_rdata     <= {DATA_WIDTH{1'b0}};
            mem_rvalid    <= 1'b0;
            pending_we    <= 1'b0;
            pending_addr  <= {ADDR_WIDTH{1'b0}};
            pending_wdata <= {DATA_WIDTH{1'b0}};
        end else begin
            mem_rvalid <= 1'b0;

            if (!busy_r) begin
                // Idle: accept a new access if requested.
                if (mem_en) begin
                    busy_r        <= 1'b1;
                    delay_cnt     <= ACCESS_DELAY[CNT_WIDTH-1:0];
                    pending_we    <= mem_we;
                    pending_addr  <= mem_addr;
                    pending_wdata <= mem_wdata;
                end
            end else begin
                // Busy: count down, ignore mem_en (arbiter must not assert it while busy).
                if (delay_cnt > 1) begin
                    delay_cnt <= delay_cnt - 1'b1;
                end else begin
                    // Delay complete this cycle -- perform the access.
                    if (pending_we) begin
                        mem[pending_addr] <= pending_wdata;
                    end else begin
                        mem_rdata  <= mem[pending_addr];
                        mem_rvalid <= 1'b1;
                    end
                    busy_r <= 1'b0;
                end
            end
        end
    end

endmodule