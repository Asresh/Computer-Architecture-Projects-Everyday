// systolic_array.sv - Day 13
//
// Output-stationary systolic array for dense matrix multiply C = A * B.
//
// This is the dataflow at the heart of a GPU Tensor Core / TPU MXU: an N x N
// grid of multiply-accumulate (MAC) processing elements (PEs). Each PE owns one
// output element C[i][j] and holds a running accumulator. Operand A streams
// west -> east across each row; operand B streams north -> south down each
// column. The two operand streams are fed in a time-skewed (diagonal) pattern
// so that A[i][k] and B[k][j] arrive at PE(i,j) on the same cycle for every k,
// and the PE folds their product into its accumulator. After the array drains,
// every PE holds one dot product and C = A * B is complete.
//
// Why output-stationary: each partial sum stays put in its PE, so the O(N^3)
// accumulations for an N x N x N multiply are done with only O(N) I/O bandwidth
// at the array edges and purely local, nearest-neighbour wiring - the property
// that lets these arrays scale to hundreds of PEs at high clock rates.
//
// Signed two's-complement operands. Reset-safe, lint-friendly, synthesizable.
// No variable bit-selects of packed vectors (only array indexing); the flat
// port <-> 2-D unpacking uses constant (genvar) offsets.

`default_nettype none

module systolic_array #(
    parameter int N     = 4,    // array dimension: computes (NxN) * (NxN)
    parameter int IN_W  = 8,    // signed input element width
    parameter int ACC_W = 32    // signed accumulator / output element width
) (
    input  wire                    clk,
    input  wire                    rst_n,   // active-low synchronous-use reset
    input  wire                    start,   // pulse: latch A,B and begin a pass
    input  wire  [N*N*IN_W-1:0]    a_in,    // row-major A (signed elements)
    input  wire  [N*N*IN_W-1:0]    b_in,    // row-major B (signed elements)
    output logic                   busy,    // high while a pass is in flight
    output logic                   done,    // 1-cycle pulse; c_out then valid
    output logic [N*N*ACC_W-1:0]   c_out    // row-major C = A*B (signed)
);

    // Streaming length: the last operand pair reaches the far corner PE and is
    // accumulated by cycle 3N-2, so 3N cycles fully drain the array. Extra
    // cycles feed zeros at the edges and are harmless.
    localparam int TOTAL = 3 * N;
    localparam int CW    = $clog2(TOTAL + 1);

    // ---- Operand storage (latched at start) --------------------------------
    logic signed [IN_W-1:0]  A_mem [N][N];
    logic signed [IN_W-1:0]  B_mem [N][N];

    // ---- PE array state ----------------------------------------------------
    logic signed [IN_W-1:0]  a_reg [N][N];  // A operand currently at each PE
    logic signed [IN_W-1:0]  b_reg [N][N];  // B operand currently at each PE
    logic signed [ACC_W-1:0] acc   [N][N];  // per-PE dot-product accumulator
    logic [CW-1:0]           t;             // streaming cycle counter

    // ---- Skewed edge operands ---------------------------------------------
    // West edge of row i receives A[i][k] on cycle k+i  => k = t - i.
    // North edge of col j receives B[k][j] on cycle k+j => k = t - j.
    logic signed [IN_W-1:0]  west_in  [N];
    logic signed [IN_W-1:0]  north_in [N];

    // ---- Flat port <-> 2-D unpacking (constant genvar offsets) -------------
    wire signed [IN_W-1:0] a_flat [N][N];
    wire signed [IN_W-1:0] b_flat [N][N];

    genvar gi, gj;
    generate
        for (gi = 0; gi < N; gi++) begin : g_row
            for (gj = 0; gj < N; gj++) begin : g_col
                assign a_flat[gi][gj] = a_in[(gi*N + gj)*IN_W +: IN_W];
                assign b_flat[gi][gj] = b_in[(gi*N + gj)*IN_W +: IN_W];
                assign c_out[(gi*N + gj)*ACC_W +: ACC_W] = acc[gi][gj];
            end
        end
    endgenerate

    // ---- Skew feeder (combinational) --------------------------------------
    always_comb begin
        for (int i = 0; i < N; i++) begin
            west_in[i]  = '0;
            north_in[i] = '0;
        end
        if (busy) begin
            for (int i = 0; i < N; i++) begin
                if ((int'(t) - i) >= 0 && (int'(t) - i) < N)
                    west_in[i] = A_mem[i][int'(t) - i];
            end
            for (int j = 0; j < N; j++) begin
                if ((int'(t) - j) >= 0 && (int'(t) - j) < N)
                    north_in[j] = B_mem[int'(t) - j][j];
            end
        end
    end

    // ---- Control + PE datapath (sequential) --------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            busy <= 1'b0;
            done <= 1'b0;
            t    <= '0;
            for (int i = 0; i < N; i++)
                for (int j = 0; j < N; j++) begin
                    a_reg[i][j] <= '0;
                    b_reg[i][j] <= '0;
                    acc[i][j]   <= '0;
                    A_mem[i][j] <= '0;
                    B_mem[i][j] <= '0;
                end
        end else begin
            done <= 1'b0;

            if (start && !busy) begin
                // Latch operands, clear the array, arm the stream.
                for (int i = 0; i < N; i++)
                    for (int j = 0; j < N; j++) begin
                        A_mem[i][j] <= a_flat[i][j];
                        B_mem[i][j] <= b_flat[i][j];
                        a_reg[i][j] <= '0;
                        b_reg[i][j] <= '0;
                        acc[i][j]   <= '0;
                    end
                t    <= '0;
                busy <= 1'b1;
            end else if (busy) begin
                // MAC on the operands presently latched in every PE.
                for (int i = 0; i < N; i++)
                    for (int j = 0; j < N; j++)
                        acc[i][j] <= acc[i][j] + a_reg[i][j] * b_reg[i][j];

                // Systolic shift: A moves east, B moves south; the array edges
                // pull in the skewed operands, interior PEs take their neighbour.
                for (int i = 0; i < N; i++)
                    for (int j = 0; j < N; j++) begin
                        a_reg[i][j] <= (j == 0) ? west_in[i]  : a_reg[i][j-1];
                        b_reg[i][j] <= (i == 0) ? north_in[j] : b_reg[i-1][j];
                    end

                if (t == CW'(TOTAL - 1)) begin
                    busy <= 1'b0;
                    done <= 1'b1;     // result in acc / c_out is now final
                end else begin
                    t <= t + 1'b1;
                end
            end
        end
    end

endmodule

`default_nettype wire
