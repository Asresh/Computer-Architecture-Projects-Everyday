// =============================================================================
// Day17 - Pipelined Bitonic Sorting Network
// -----------------------------------------------------------------------------
// A fully-pipelined hardware sorting network that sorts a vector of N unsigned
// WIDTH-bit keys per launch. Bitonic sort is THE canonical data-parallel sort
// primitive on GPUs (fixed O(N log^2 N) compare-exchange schedule, no data-
// dependent control flow -> perfectly SIMT-friendly) and the workhorse of
// low-latency "sort / top-N" datapaths in high-frequency-trading engines
// (e.g. keeping the best few bids/asks of an order book, or ranking signals).
//
// Structure
// ---------
//   Let L = log2(N). A bitonic sorter is a fixed mesh of compare-exchange (CAE)
//   elements arranged in L*(L+1)/2 layers. Layer (stage s, sub-step t) pairs
//   each lane i with lane (i XOR J) where J = 2^(s-1-t), and sorts the pair
//   ascending when (i & K)==0 (K = 2^s) else descending. Repeating this over
//   s = 1..L, t = 0..s-1 leaves the whole vector monotonically sorted.
//
//   This module places ONE pipeline register after every layer, so the network
//   is fully pipelined: it accepts a fresh N-key vector every clock and, after
//   a fixed latency of (LAYERS+1) cycles, emits one fully-sorted vector every
//   clock (throughput = 1 vector / cycle, independent of the data).
//
//   The mesh is built ascending; a per-launch `dir_asc` control (pipelined
//   alongside the data) selects ascending output directly or descending output
//   by reversing the sorted vector at the tail - a monotone vector reversed is
//   still monotone in the opposite order, so no extra compare hardware is used.
//
// Properties
// ----------
//   * Parameterized in N (power of two, >= 2) and key WIDTH.
//   * Purely structural / data-independent schedule - no variable bit-selects,
//     no data-dependent branching, lint- and synthesis-friendly.
//   * Reset-safe: only the valid/dir pipeline needs reset; data lanes are
//     naturally flushed by the valid pipeline.
//   * Keys are treated as UNSIGNED magnitudes (prices, volumes, ranks...).
// =============================================================================

`default_nettype none

module bitonic_sorter #(
    parameter int N     = 8,   // number of keys per vector (power of two, >= 2)
    parameter int WIDTH = 16   // key width in bits
) (
    input  wire                  clk,
    input  wire                  rst_n,
    input  wire                  in_valid,   // launch a new vector this cycle
    input  wire                  dir_asc,    // 1 = ascending, 0 = descending
    input  wire [N*WIDTH-1:0]    in_keys,    // packed: lane i = [i*WIDTH +: WIDTH]
    output wire                  out_valid,  // sorted vector valid this cycle
    output wire [N*WIDTH-1:0]    out_keys    // packed sorted result
);

    // ---- derived geometry --------------------------------------------------
    localparam int L      = $clog2(N);        // number of major stages
    localparam int LAYERS = (L * (L + 1)) / 2; // total compare-exchange layers
    localparam int LAT    = LAYERS + 1;        // pipeline latency in cycles

    // pipeline data: pipe[0] = registered input, pipe[LAYERS] = sorted output.
    logic [WIDTH-1:0] pipe  [0:LAYERS][0:N-1];
    logic             vpipe [0:LAYERS];
    logic             dpipe [0:LAYERS];

    integer m;

    // ---- input registration (pipeline stage 0) -----------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            vpipe[0] <= 1'b0;
        end else begin
            vpipe[0] <= in_valid;
            dpipe[0] <= dir_asc;
            for (m = 0; m < N; m = m + 1)
                pipe[0][m] <= in_keys[m*WIDTH +: WIDTH];
        end
    end

    // ---- the compare-exchange mesh: one registered layer per (stage, sub) ---
    genvar s, t;
    generate
        for (s = 1; s <= L; s = s + 1) begin : gen_stage
            for (t = 0; t < s; t = t + 1) begin : gen_sub
                // flat layer index in [0, LAYERS): (s-1)*s/2 + t, sequential.
                localparam int G = ((s - 1) * s) / 2 + t;
                localparam int K = (1 << s);         // ascending-block size
                localparam int J = (1 << (s - 1 - t)); // compare distance

                integer lane;
                always_ff @(posedge clk or negedge rst_n) begin
                    if (!rst_n) begin
                        vpipe[G+1] <= 1'b0;
                    end else begin
                        vpipe[G+1] <= vpipe[G];
                        dpipe[G+1] <= dpipe[G];
                        for (lane = 0; lane < N; lane = lane + 1) begin
                            // TAKE_MIN = is_low ? ascending : !ascending, where
                            //   is_low    = (lane & J)==0  (lower index of pair)
                            //   ascending = (lane & K)==0
                            if (((lane & J) == 0) ? ((lane & K) == 0)
                                                  : ((lane & K) != 0)) begin
                                // this lane keeps the SMALLER of the pair
                                pipe[G+1][lane] <=
                                    (pipe[G][lane] <= pipe[G][lane ^ J])
                                        ? pipe[G][lane] : pipe[G][lane ^ J];
                            end else begin
                                // this lane keeps the LARGER of the pair
                                pipe[G+1][lane] <=
                                    (pipe[G][lane] >= pipe[G][lane ^ J])
                                        ? pipe[G][lane] : pipe[G][lane ^ J];
                            end
                        end
                    end
                end
            end
        end
    endgenerate

    // ---- output: ascending straight through, descending = reversed lanes ----
    genvar o;
    generate
        for (o = 0; o < N; o = o + 1) begin : gen_out
            assign out_keys[o*WIDTH +: WIDTH] =
                dpipe[LAYERS] ? pipe[LAYERS][o] : pipe[LAYERS][N-1-o];
        end
    endgenerate

    assign out_valid = vpipe[LAYERS];

    // ---- elaboration-time sanity checks -------------------------------------
    // synthesis translate_off
    initial begin
        if ((N < 2) || ((N & (N - 1)) != 0))
            $fatal(1, "bitonic_sorter: N (%0d) must be a power of two >= 2", N);
        if (WIDTH < 1)
            $fatal(1, "bitonic_sorter: WIDTH (%0d) must be >= 1", WIDTH);
    end
    // synthesis translate_on

endmodule

`default_nettype wire
