// ===========================================================================
// Day18 : Kogge-Stone Parallel Prefix-Sum (Inclusive Scan) Unit
// ===========================================================================
// A fully-pipelined, work-efficient-latency parallel prefix (scan) network.
// Scan is THE fundamental data-parallel primitive on GPUs (CUDA CUB
// DeviceScan / warp-level __shfl scan): given a vector [x0, x1, ... x(N-1)]
// it produces the running totals
//
//     inclusive :  y[i] = x0 + x1 + ... + xi
//     exclusive :  y[i] = x0 + x1 + ... + x(i-1)   (y0 = 0)
//
// This module implements the Kogge-Stone formulation: log2(N) stages, and at
// stage d every lane adds in the partial sum from the lane 2^d positions to
// its left (lanes with no such neighbour pass through unchanged).  Each stage
// is registered, so the network is a systolic pipeline that accepts one new
// N-element vector every cycle and emits a completed scan LOG2+1 cycles later
// -> 1-vector/cycle throughput at a fixed, data-independent latency.  There is
// no data-dependent branching and no variable bit-select anywhere: the shift
// distance 2^d is a compile-time constant per generate stage, so the design is
// purely structural and lint / synthesis friendly.
//
// Why architects care: scan underlies stream compaction, radix-sort digit
// histogramming, sparse-matrix row pointers, and — for HFT — running
// cumulative order-book depth / cumulative traded volume across price levels
// with deterministic, minimum latency.
//
// Parameters
//   LANES     : number of parallel elements N (must be a power of two)
//   WIDTH     : bit-width of each element (unsigned, wraps mod 2^WIDTH)
//   EXCLUSIVE : 0 = inclusive scan, 1 = exclusive scan
//
// Handshake: purely streaming.  Assert in_valid with in_data on a cycle; the
// corresponding out_data appears with out_valid asserted LATENCY cycles later.
// No back-pressure (a scan network never stalls) — consumers must keep up.
// ===========================================================================
`timescale 1ns/1ps

module prefix_scan #(
    parameter int LANES     = 8,
    parameter int WIDTH     = 16,
    parameter bit EXCLUSIVE = 1'b0
) (
    input  logic                         clk,
    input  logic                         rst_n,     // synchronous, active-low
    input  logic                         in_valid,
    input  logic [LANES*WIDTH-1:0]       in_data,   // lane i = bits [i*WIDTH +: WIDTH]
    output logic                         out_valid,
    output logic [LANES*WIDTH-1:0]       out_data
);

    // ---- derived constants -------------------------------------------------
    // LOG2 = ceil(log2(LANES)); for a power-of-two LANES this is exact.
    localparam int LOG2    = (LANES <= 1) ? 1 : $clog2(LANES);
    // Pipeline latency: 1 input-capture stage + LOG2 combine stages
    // + (EXCLUSIVE ? 1 shift stage : 0).
    localparam int LATENCY = 1 + LOG2 + (EXCLUSIVE ? 1 : 0);

    // Unpack helper view: stage_data[s] holds the LANES words after stage s.
    // s = 0 is the registered input; s = 1..LOG2 are the combine stages.
    logic [WIDTH-1:0] stage_data [0:LOG2][0:LANES-1];
    logic             stage_vld  [0:LOG2];

    // ---- stage 0 : register the incoming vector ----------------------------
    genvar gi, gs;
    generate
        for (gi = 0; gi < LANES; gi++) begin : g_in
            always_ff @(posedge clk) begin
                if (!rst_n)
                    stage_data[0][gi] <= '0;
                else
                    stage_data[0][gi] <= in_data[gi*WIDTH +: WIDTH];
            end
        end
    endgenerate

    always_ff @(posedge clk) begin
        if (!rst_n) stage_vld[0] <= 1'b0;
        else        stage_vld[0] <= in_valid;
    end

    // ---- stages 1..LOG2 : Kogge-Stone combine ------------------------------
    // At stage s the offset is 2^(s-1).  Lane i receives
    //   lane i (previous stage)  +  lane (i - offset) (previous stage)
    // when i >= offset, else it passes through unchanged.  All offsets are
    // elaboration-time constants -> no variable bit-selects.
    generate
        for (gs = 1; gs <= LOG2; gs++) begin : g_stage
            localparam int OFFSET = (1 << (gs-1));
            for (gi = 0; gi < LANES; gi++) begin : g_lane
                if (gi >= OFFSET) begin : g_combine
                    always_ff @(posedge clk) begin
                        if (!rst_n)
                            stage_data[gs][gi] <= '0;
                        else
                            stage_data[gs][gi] <=
                                stage_data[gs-1][gi] + stage_data[gs-1][gi-OFFSET];
                    end
                end else begin : g_pass
                    always_ff @(posedge clk) begin
                        if (!rst_n)
                            stage_data[gs][gi] <= '0;
                        else
                            stage_data[gs][gi] <= stage_data[gs-1][gi];
                    end
                end
            end
            always_ff @(posedge clk) begin
                if (!rst_n) stage_vld[gs] <= 1'b0;
                else        stage_vld[gs] <= stage_vld[gs-1];
            end
        end
    endgenerate

    // ---- optional exclusive-scan conversion --------------------------------
    // Exclusive[i] = Inclusive[i-1], Exclusive[0] = 0.  One extra pipe stage.
    generate
        if (EXCLUSIVE) begin : g_excl
            logic [WIDTH-1:0] excl [0:LANES-1];
            logic             excl_vld;
            for (gi = 0; gi < LANES; gi++) begin : g_shift
                always_ff @(posedge clk) begin
                    if (!rst_n)
                        excl[gi] <= '0;
                    else if (gi == 0)
                        excl[gi] <= '0;
                    else
                        excl[gi] <= stage_data[LOG2][gi-1];
                end
            end
            always_ff @(posedge clk) begin
                if (!rst_n) excl_vld <= 1'b0;
                else        excl_vld <= stage_vld[LOG2];
            end
            for (gi = 0; gi < LANES; gi++) begin : g_pack
                assign out_data[gi*WIDTH +: WIDTH] = excl[gi];
            end
            assign out_valid = excl_vld;
        end else begin : g_incl
            for (gi = 0; gi < LANES; gi++) begin : g_pack
                assign out_data[gi*WIDTH +: WIDTH] = stage_data[LOG2][gi];
            end
            assign out_valid = stage_vld[LOG2];
        end
    endgenerate

    // expose latency for the testbench / documentation
    // (unused in synthesis; localparam is visible hierarchically)
    // synthesis translate_off
    initial begin
        // sanity: LANES must be a power of two for exact log2 pipelining
        if ((LANES & (LANES-1)) != 0)
            $error("prefix_scan: LANES (%0d) must be a power of two", LANES);
    end
    // synthesis translate_on

endmodule
