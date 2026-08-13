// ===========================================================================
// argmax_reduce.sv - Pipelined Argmax / Argmin Reduction Tree
// ===========================================================================
// A fully-pipelined binary reduction tree that reduces a packed vector of
// LANES unsigned values down to the SINGLE extreme element, returning BOTH
// its value AND its originating lane index (an "arg-reduce", the value+index
// variant of a warp reduction).  A per-launch `mode` selects argmax vs argmin.
//
// This is the value/index reduction primitive that sits behind CUDA warp
// reductions (`__shfl_down`/`__reduce_max_sync`) and CUB `DeviceReduce::ArgMax`
// / `ArgMin`.  In a market-data / HFT datapath it is exactly the top-of-book
// selector: given a vector of resting price levels, argmax picks the best bid
// (highest price + which lane it lives on) and argmin picks the best ask,
// which is the single most latency-critical reduction on a trading fast path.
//
// Microarchitecture
// -----------------
//   * The reduction is a balanced binary tree of LOG2 = clog2(LANES) levels.
//     Level 0 registers the LANES leaves as (value, index) pairs.  Each
//     subsequent level halves the survivor count with a row of compare-select
//     (CMPSEL) nodes and is separated by a pipeline register, so the tree
//     accepts a fresh vector EVERY cycle at a fixed, data-independent latency
//     of LAT = LOG2 + 1 cycles (1 leaf-capture stage + LOG2 reduce stages).
//   * Each CMPSEL compares the two child values under the pipelined `mode`
//     bit and forwards the winner's {value,index}.  TIES are broken toward the
//     LOWER lane index (deterministic, matching CUB's first-extreme rule).
//     Because leaves start in lane order and every tie keeps the lower index,
//     the left child of any node always carries the smaller index, so ">="
//     (argmax) / "<=" (argmin) on the value alone realises the tie-break with
//     no extra index comparison.
//   * `mode` and `valid` are pipelined alongside the data, so back-to-back
//     launches may freely mix argmax and argmin with no bubble.
//
// Purely structural constant-index tree wiring: no variable bit-selects and
// no data-dependent control flow -> lint- and synthesis-friendly.  LANES must
// be a power of two (checked by an elaboration assertion).
// ===========================================================================
`timescale 1ns/1ps

module argmax_reduce #(
    parameter int LANES = 8,     // number of input lanes (power of two, >= 2)
    parameter int WIDTH = 16     // unsigned value width in bits
) (
    input  logic                    clk,
    input  logic                    rst_n,     // active-low synchronous-ish reset
    input  logic                    in_valid,  // launch a reduction this cycle
    input  logic                    mode,      // 0 = argmax, 1 = argmin
    input  logic [LANES*WIDTH-1:0]  in_data,   // packed, lane0 = least-significant slice

    output logic                    out_valid, // result vector valid (LAT cycles later)
    output logic [WIDTH-1:0]        best_val,  // extreme value
    output logic [$clog2(LANES)-1:0] best_idx  // lane index of the extreme value
);

    localparam int LOG2 = $clog2(LANES);
    localparam int IDXW = LOG2;                // >=1 since LANES >= 2

    // elaboration-time sanity checks
    initial begin
        if ((LANES < 2) || ((LANES & (LANES-1)) != 0))
            $fatal(1, "argmax_reduce: LANES must be a power of two >= 2 (got %0d)", LANES);
    end

    // -----------------------------------------------------------------------
    // Pipeline storage.  Every stage is sized to LANES entries; a level `lv`
    // only uses its low (LANES >> lv) entries.  The unused upper entries are
    // simply never written past the point they are consumed and never read.
    // -----------------------------------------------------------------------
    logic [WIDTH-1:0] s_val [0:LOG2][0:LANES-1];
    logic [IDXW-1:0]  s_idx [0:LOG2][0:LANES-1];
    logic             s_vld [0:LOG2];
    logic             s_md  [0:LOG2];

    // ---- Stage 0 : register the LANES leaves in lane order -----------------
    integer i;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s_vld[0] <= 1'b0;
            s_md[0]  <= 1'b0;
            for (i = 0; i < LANES; i++) begin
                s_val[0][i] <= '0;
                s_idx[0][i] <= '0;
            end
        end else begin
            s_vld[0] <= in_valid;
            s_md[0]  <= mode;
            for (i = 0; i < LANES; i++) begin
                s_val[0][i] <= in_data[i*WIDTH +: WIDTH];
                s_idx[0][i] <= IDXW'(i);
            end
        end
    end

    // ---- Reduce levels : LOG2 rows of registered compare-select nodes ------
    genvar lv, j;
    generate
        for (lv = 0; lv < LOG2; lv++) begin : g_level
            localparam int NIN  = LANES >> lv;   // survivors entering this level
            localparam int NOUT = NIN >> 1;      // survivors leaving this level

            // valid / mode travel down with the data
            always_ff @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    s_vld[lv+1] <= 1'b0;
                    s_md[lv+1]  <= 1'b0;
                end else begin
                    s_vld[lv+1] <= s_vld[lv];
                    s_md[lv+1]  <= s_md[lv];
                end
            end

            for (j = 0; j < NOUT; j++) begin : g_cmpsel
                // Left child (2*j) always holds the lower lane index, so a
                // ">="/"<=" value test picks the winner AND breaks ties toward
                // the lower index in one comparison.
                wire pick_left = s_md[lv]
                    ? (s_val[lv][2*j] <= s_val[lv][2*j+1])   // argmin
                    : (s_val[lv][2*j] >= s_val[lv][2*j+1]);  // argmax

                always_ff @(posedge clk or negedge rst_n) begin
                    if (!rst_n) begin
                        s_val[lv+1][j] <= '0;
                        s_idx[lv+1][j] <= '0;
                    end else if (pick_left) begin
                        s_val[lv+1][j] <= s_val[lv][2*j];
                        s_idx[lv+1][j] <= s_idx[lv][2*j];
                    end else begin
                        s_val[lv+1][j] <= s_val[lv][2*j+1];
                        s_idx[lv+1][j] <= s_idx[lv][2*j+1];
                    end
                end
            end
        end
    endgenerate

    // ---- Root of the tree drives the outputs -------------------------------
    assign out_valid = s_vld[LOG2];
    assign best_val  = s_val[LOG2][0];
    assign best_idx  = s_idx[LOG2][0];

endmodule
