// ===========================================================================
// tb_argmax_reduce.sv - self-checking testbench for the argmax/argmin tree
// ===========================================================================
// Streams one vector per cycle into the DUT and, because the tree is a
// fixed-latency pipeline, pushes a combinationally-computed golden result
// (value + index, with lowest-index tie-break) through a TB delay line of
// matching depth LAT = 1 + clog2(LANES).  Whenever out_valid is asserted the
// DUT root is compared against the aligned golden entry.
//
// Coverage: reset, then directed corner cases driven back-to-back and mixing
// argmax/argmin launches - ascending / descending ramps, all-equal (tie ->
// lowest index), single peak / single trough, duplicated extreme (tie-break),
// full-scale and zero values, an in_valid gap - followed by many randomized
// {vector, mode} launches.
//
// Prints "RESULT: *** PASS ***" only if every compared output matched.
// Dumps argmax_reduce.vcd for waveform rendering.  Has a global timeout.
// ===========================================================================
`timescale 1ns/1ps

module tb_argmax_reduce;

    localparam int LANES = 8;
    localparam int WIDTH = 16;
    localparam int LOG2  = $clog2(LANES);
    localparam int IDXW  = LOG2;
    localparam int LAT   = 1 + LOG2;     // leaf-capture + LOG2 reduce stages

    logic                    clk = 1'b0;
    logic                    rst_n;
    logic                    in_valid;
    logic                    mode;
    logic [LANES*WIDTH-1:0]  in_data;

    logic                    out_valid;
    logic [WIDTH-1:0]        best_val;
    logic [IDXW-1:0]         best_idx;

    integer errors = 0;
    integer checks = 0;

    // ---- clock -------------------------------------------------------------
    always #5 clk = ~clk;

    // ---- DUT ---------------------------------------------------------------
    argmax_reduce #(.LANES(LANES), .WIDTH(WIDTH)) dut (
        .clk(clk), .rst_n(rst_n),
        .in_valid(in_valid), .mode(mode), .in_data(in_data),
        .out_valid(out_valid), .best_val(best_val), .best_idx(best_idx)
    );

    // ---- golden reference : first-extreme (lowest-index tie-break) ---------
    // Returns {value, index} packed as [WIDTH+IDXW-1 : 0].
    function automatic [WIDTH+IDXW-1:0] arg_reduce(input [LANES*WIDTH-1:0] v,
                                                   input                    is_min);
        logic [WIDTH-1:0] best;
        logic [IDXW-1:0]  bidx;
        logic [WIDTH-1:0] x;
        int k;
        logic better;
        begin
            best = v[0 +: WIDTH];
            bidx = '0;
            for (k = 1; k < LANES; k++) begin
                x = v[k*WIDTH +: WIDTH];
                better = is_min ? (x < best) : (x > best);  // strict -> keep
                if (better) begin                           //   earlier lane on tie
                    best = x;
                    bidx = IDXW'(k);
                end
            end
            arg_reduce = {best, bidx};
        end
    endfunction

    // ---- golden delay line (index [0] newest, [LAT-1] aligns with DUT) ------
    logic [WIDTH-1:0] exp_val [0:LAT-1];
    logic [IDXW-1:0]  exp_idx [0:LAT-1];
    logic             exp_vld [0:LAT-1];

    logic [WIDTH+IDXW-1:0] gold_now;
    integer p;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (p = 0; p < LAT; p++) begin
                exp_val[p] <= '0;
                exp_idx[p] <= '0;
                exp_vld[p] <= 1'b0;
            end
        end else begin
            gold_now   = arg_reduce(in_data, mode);
            exp_val[0] <= gold_now[IDXW +: WIDTH];
            exp_idx[0] <= gold_now[0 +: IDXW];
            exp_vld[0] <= in_valid;
            for (p = 1; p < LAT; p++) begin
                exp_val[p] <= exp_val[p-1];
                exp_idx[p] <= exp_idx[p-1];
                exp_vld[p] <= exp_vld[p-1];
            end
        end
    end

    // ---- comparison --------------------------------------------------------
    always @(posedge clk) begin
        if (rst_n && out_valid) begin
            checks++;
            if (!exp_vld[LAT-1] ||
                best_val !== exp_val[LAT-1] ||
                best_idx !== exp_idx[LAT-1]) begin
                errors++;
                $display("[%0t] MISMATCH  dut=(val=%0d,idx=%0d)  exp=(val=%0d,idx=%0d) vld=%b",
                         $time, best_val, best_idx,
                         exp_val[LAT-1], exp_idx[LAT-1], exp_vld[LAT-1]);
            end
        end
    end

    // ---- stimulus helpers --------------------------------------------------
    logic [WIDTH-1:0] lane [0:LANES-1];
    function automatic [LANES*WIDTH-1:0] pack;
        int i;
        begin
            pack = '0;
            for (i = 0; i < LANES; i++) pack[i*WIDTH +: WIDTH] = lane[i];
        end
    endfunction

    task automatic launch(input [LANES*WIDTH-1:0] v, input logic m);
        begin
            @(negedge clk);
            in_valid = 1'b1;
            mode     = m;
            in_data  = v;
        end
    endtask

    localparam logic ARGMAX = 1'b0;
    localparam logic ARGMIN = 1'b1;

    // ---- stimulus ----------------------------------------------------------
    integer i, t;
    initial begin
        $dumpfile("argmax_reduce.vcd");
        $dumpvars(0, tb_argmax_reduce);

        in_valid = 1'b0;
        mode     = ARGMAX;
        in_data  = '0;
        rst_n    = 1'b0;
        repeat (4) @(negedge clk);
        rst_n = 1'b1;
        @(negedge clk);

        // ascending ramp 10,20,..80 : argmax -> lane7, argmin -> lane0
        for (i = 0; i < LANES; i++) lane[i] = 16'd10 * (i+1);
        launch(pack(), ARGMAX);
        launch(pack(), ARGMIN);

        // descending 80,70,..10 : argmax -> lane0, argmin -> lane7
        for (i = 0; i < LANES; i++) lane[i] = 16'd10 * (LANES - i);
        launch(pack(), ARGMAX);
        launch(pack(), ARGMIN);

        // all equal -> tie broken to lane0 for BOTH modes
        for (i = 0; i < LANES; i++) lane[i] = 16'd42;
        launch(pack(), ARGMAX);
        launch(pack(), ARGMIN);

        // single peak at lane5 (argmax->5); trough elsewhere is 0 (argmin->lane0 tie)
        for (i = 0; i < LANES; i++) lane[i] = (i == 5) ? 16'd9999 : 16'd0;
        launch(pack(), ARGMAX);
        launch(pack(), ARGMIN);

        // single trough at lane3 amid a high plateau
        for (i = 0; i < LANES; i++) lane[i] = (i == 3) ? 16'd1 : 16'd5000;
        launch(pack(), ARGMIN);
        launch(pack(), ARGMAX);   // max is the plateau -> lane0 tie

        // duplicated maximum at lanes 2 and 6 -> argmax tie-break to lane2
        for (i = 0; i < LANES; i++) lane[i] = ((i == 2) || (i == 6)) ? 16'd777 : 16'd100;
        launch(pack(), ARGMAX);

        // duplicated minimum at lanes 1 and 4 -> argmin tie-break to lane1
        for (i = 0; i < LANES; i++) lane[i] = ((i == 1) || (i == 4)) ? 16'd3 : 16'd900;
        launch(pack(), ARGMIN);

        // full-scale and zero extremes
        for (i = 0; i < LANES; i++) lane[i] = (i == 4) ? 16'hFFFF : 16'h0000;
        launch(pack(), ARGMAX);
        launch(pack(), ARGMIN);

        // gap in the stream (in_valid low)
        @(negedge clk); in_valid = 1'b0; in_data = '0;
        @(negedge clk);

        // back-to-back randomized {vector, mode} launches
        for (t = 0; t < 300; t++) begin
            for (i = 0; i < LANES; i++) lane[i] = $random;
            launch(pack(), $random & 1'b1);
        end

        // drain
        @(negedge clk); in_valid = 1'b0; in_data = '0;
        repeat (LAT + 4) @(negedge clk);

        // ---- report --------------------------------------------------------
        $display("-----------------------------------------------------------");
        $display("argmax_reduce: %0d outputs checked, %0d mismatches", checks, errors);
        if (errors == 0 && checks > 0)
            $display("RESULT: *** PASS ***");
        else
            $display("RESULT: *** FAIL *** (%0d errors)", errors);
        $finish;
    end

    // ---- timeout -----------------------------------------------------------
    initial begin
        #100000;
        $display("RESULT: *** FAIL *** (timeout)");
        $finish;
    end

endmodule
