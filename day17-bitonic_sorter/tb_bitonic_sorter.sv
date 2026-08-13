// =============================================================================
// Day17 - Self-checking testbench for the pipelined bitonic sorting network.
// -----------------------------------------------------------------------------
// Golden model: an independent software sort (unsigned) of each launched
// vector, reversed for descending. Because the DUT is fully pipelined and
// in-order, expected results are pushed into a FIFO scoreboard at launch time
// and popped/compared whenever out_valid asserts.
//
// Stimulus:
//   * Directed corner cases: already-sorted, reverse-sorted, all-equal,
//     alternating hi/lo, single spike, zeros, max values, and both directions.
//   * Back-pressure / bubbles: idle cycles (in_valid=0) interleaved to prove
//     the valid pipeline gates results correctly.
//   * Randomized: many random vectors with a random direction each.
//
// A global timeout guards against a wedged pipeline. Prints
// "RESULT: *** PASS ***" iff every launched vector matched the golden model
// and the expected number of results were checked. Dumps bitonic_sorter.vcd.
// =============================================================================

`default_nettype none
`timescale 1ns/1ps

module tb_bitonic_sorter;

    localparam int N     = 8;
    localparam int WIDTH = 16;
    localparam int L     = $clog2(N);
    localparam int LAT   = (L * (L + 1)) / 2 + 1;  // DUT pipeline latency

    // ---- clock / reset ------------------------------------------------------
    logic clk = 1'b0;
    always #5 clk = ~clk;   // 100 MHz

    logic rst_n;

    // ---- DUT I/O ------------------------------------------------------------
    logic                in_valid;
    logic                dir_asc;
    logic [N*WIDTH-1:0]  in_keys;
    logic                out_valid;
    logic [N*WIDTH-1:0]  out_keys;

    bitonic_sorter #(.N(N), .WIDTH(WIDTH)) dut (
        .clk      (clk),
        .rst_n    (rst_n),
        .in_valid (in_valid),
        .dir_asc  (dir_asc),
        .in_keys  (in_keys),
        .out_valid(out_valid),
        .out_keys (out_keys)
    );

    // ---- scoreboard: FIFO of expected packed results ------------------------
    localparam int SB = 256;
    logic [N*WIDTH-1:0] sb_data [0:SB-1];
    integer sb_head, sb_tail;

    integer launched;   // vectors driven
    integer checked;    // results compared
    integer errors;

    // ---- golden model: sort N unsigned keys, reverse if descending ----------
    // Returns the packed expected result for a given packed input + direction.
    function automatic [N*WIDTH-1:0] golden_sort(input [N*WIDTH-1:0] keys,
                                                 input logic          asc);
        logic [WIDTH-1:0] a [0:N-1];
        logic [WIDTH-1:0] tmp;
        integer i, j;
        begin
            for (i = 0; i < N; i = i + 1)
                a[i] = keys[i*WIDTH +: WIDTH];
            // insertion sort, ascending, unsigned
            for (i = 1; i < N; i = i + 1) begin
                tmp = a[i];
                j = i - 1;
                while (j >= 0 && a[j] > tmp) begin
                    a[j+1] = a[j];
                    j = j - 1;
                end
                a[j+1] = tmp;
            end
            golden_sort = '0;
            for (i = 0; i < N; i = i + 1) begin
                if (asc) golden_sort[i*WIDTH +: WIDTH] = a[i];
                else     golden_sort[i*WIDTH +: WIDTH] = a[N-1-i];
            end
        end
    endfunction

    // ---- helper: launch one vector on the next posedge ----------------------
    // Sets stimulus, records the golden result in the scoreboard FIFO.
    task automatic launch(input [N*WIDTH-1:0] keys, input logic asc);
        begin
            @(negedge clk);
            in_valid = 1'b1;
            dir_asc  = asc;
            in_keys  = keys;
            sb_data[sb_tail] = golden_sort(keys, asc);
            sb_tail = (sb_tail + 1) % SB;
            launched = launched + 1;
        end
    endtask

    task automatic idle(input integer cycles);
        integer c;
        begin
            for (c = 0; c < cycles; c = c + 1) begin
                @(negedge clk);
                in_valid = 1'b0;
            end
        end
    endtask

    // ---- checker: on every out_valid, pop FIFO and compare ------------------
    logic [N*WIDTH-1:0] exp;
    integer k;
    always @(posedge clk) begin
        if (rst_n && out_valid) begin
            if (sb_head == sb_tail) begin
                $display("[%0t] ERROR: out_valid with empty scoreboard", $time);
                errors = errors + 1;
            end else begin
                exp = sb_data[sb_head];
                sb_head = (sb_head + 1) % SB;
                checked = checked + 1;
                if (out_keys !== exp) begin
                    errors = errors + 1;
                    $display("[%0t] MISMATCH #%0d", $time, checked);
                    for (k = 0; k < N; k = k + 1)
                        $display("   lane %0d: got %0d  exp %0d", k,
                                 out_keys[k*WIDTH +: WIDTH],
                                 exp[k*WIDTH +: WIDTH]);
                end
            end
        end
    end

    // ---- helpers to build packed vectors ------------------------------------
    function automatic [N*WIDTH-1:0] pack8(input [WIDTH-1:0] v0, v1, v2, v3,
                                                              v4, v5, v6, v7);
        begin
            pack8 = '0;
            pack8[0*WIDTH +: WIDTH] = v0; pack8[1*WIDTH +: WIDTH] = v1;
            pack8[2*WIDTH +: WIDTH] = v2; pack8[3*WIDTH +: WIDTH] = v3;
            pack8[4*WIDTH +: WIDTH] = v4; pack8[5*WIDTH +: WIDTH] = v5;
            pack8[6*WIDTH +: WIDTH] = v6; pack8[7*WIDTH +: WIDTH] = v7;
        end
    endfunction

    // ---- stimulus -----------------------------------------------------------
    logic [N*WIDTH-1:0] rv;
    integer t, i;
    initial begin
        $dumpfile("bitonic_sorter.vcd");
        $dumpvars(0, tb_bitonic_sorter);

        in_valid = 1'b0; dir_asc = 1'b1; in_keys = '0;
        sb_head = 0; sb_tail = 0;
        launched = 0; checked = 0; errors = 0;

        rst_n = 1'b0;
        repeat (3) @(negedge clk);
        rst_n = 1'b1;
        @(negedge clk);

        // ---- directed corner cases (ascending) -----------------------------
        launch(pack8(10, 20, 30, 40, 50, 60, 70, 80), 1'b1); // already sorted
        launch(pack8(80, 70, 60, 50, 40, 30, 20, 10), 1'b1); // reverse sorted
        launch(pack8(42, 42, 42, 42, 42, 42, 42, 42), 1'b1); // all equal
        launch(pack8( 9,  1,  9,  1,  9,  1,  9,  1), 1'b1); // alternating
        launch(pack8( 0,  0,  0,  5,  0,  0,  0,  0), 1'b1); // single spike
        launch(pack8(16'hFFFF, 0, 16'hFFFF, 0,
                     16'hFFFF, 0, 16'hFFFF, 0), 1'b1);       // extremes
        // ---- directed corner cases (descending) ----------------------------
        launch(pack8(10, 20, 30, 40, 50, 60, 70, 80), 1'b0); // -> descending
        launch(pack8( 3,  1,  4,  1,  5,  9,  2,  6), 1'b0);

        // bubbles between launches (valid-gating check)
        idle(4);
        launch(pack8(100, 50, 200, 25, 150, 75, 175, 125), 1'b1);
        idle(2);
        launch(pack8(  7,  6,  5,  4,  3,  2,  1,  0), 1'b0);

        // ---- randomized stream ---------------------------------------------
        for (t = 0; t < 300; t = t + 1) begin
            rv = '0;
            for (i = 0; i < N; i = i + 1)
                rv[i*WIDTH +: WIDTH] = $random;
            launch(rv, $random & 1'b1);
            // sprinkle occasional bubbles
            if ((t % 17) == 0) idle(1);
        end

        // stop driving, let the pipeline drain
        @(negedge clk);
        in_valid = 1'b0;
        repeat (LAT + 8) @(negedge clk);

        // ---- verdict -------------------------------------------------------
        $display("-------------------------------------------------------");
        $display("launched = %0d  checked = %0d  errors = %0d",
                 launched, checked, errors);
        if (errors == 0 && checked == launched && launched > 0)
            $display("RESULT: *** PASS ***");
        else
            $display("RESULT: *** FAIL ***");
        $finish;
    end

    // ---- global timeout -----------------------------------------------------
    initial begin
        #500000;
        $display("RESULT: *** FAIL *** (timeout)");
        $finish;
    end

endmodule

`default_nettype wire
