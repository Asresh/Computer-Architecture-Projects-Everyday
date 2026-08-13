// ===========================================================================
// tb_prefix_scan.sv - self-checking testbench for the Kogge-Stone prefix scan
// ===========================================================================
// Drives one shared stimulus stream into TWO DUT instances at once:
//   * an INCLUSIVE scan    (EXCLUSIVE = 0)
//   * an EXCLUSIVE scan    (EXCLUSIVE = 1)
// Each DUT is a fixed-latency pipeline, so a golden reference (computed
// combinationally from the same in_data) is pushed through a TB delay line of
// matching depth and compared against the DUT output whenever out_valid is
// asserted.  Because the network never stalls, we stream a new vector every
// cycle: directed corner cases (zeros, ramp, saturating all-ones, alternating,
// descending, single-hot, overflow-wrap) followed by many randomized vectors.
//
// Prints "RESULT: *** PASS ***" only if every compared output matched.
// Dumps prefix_scan.vcd for waveform rendering.  Has a global timeout.
// ===========================================================================
`timescale 1ns/1ps

module tb_prefix_scan;

    localparam int LANES = 8;
    localparam int WIDTH = 16;
    localparam int LOG2  = $clog2(LANES);
    localparam int LAT_I = 1 + LOG2;       // inclusive latency
    localparam int LAT_E = 1 + LOG2 + 1;   // exclusive latency

    logic                    clk = 1'b0;
    logic                    rst_n;
    logic                    in_valid;
    logic [LANES*WIDTH-1:0]  in_data;

    logic                    o_valid_i, o_valid_e;
    logic [LANES*WIDTH-1:0]  o_data_i,  o_data_e;

    integer errors = 0;
    integer checks = 0;

    // ---- clock -------------------------------------------------------------
    always #5 clk = ~clk;

    // ---- DUTs --------------------------------------------------------------
    prefix_scan #(.LANES(LANES), .WIDTH(WIDTH), .EXCLUSIVE(1'b0)) dut_incl (
        .clk(clk), .rst_n(rst_n),
        .in_valid(in_valid), .in_data(in_data),
        .out_valid(o_valid_i), .out_data(o_data_i)
    );

    prefix_scan #(.LANES(LANES), .WIDTH(WIDTH), .EXCLUSIVE(1'b1)) dut_excl (
        .clk(clk), .rst_n(rst_n),
        .in_valid(in_valid), .in_data(in_data),
        .out_valid(o_valid_e), .out_data(o_data_e)
    );

    // ---- golden scan function (matches WIDTH wrap-around) -------------------
    function automatic [LANES*WIDTH-1:0] scan(input [LANES*WIDTH-1:0] v,
                                              input                    excl);
        logic [WIDTH-1:0] acc;
        logic [WIDTH-1:0] x;
        int i;
        begin
            acc = '0;
            scan = '0;
            for (i = 0; i < LANES; i++) begin
                x = v[i*WIDTH +: WIDTH];
                if (excl) begin
                    scan[i*WIDTH +: WIDTH] = acc;   // sum of strictly-earlier lanes
                    acc = acc + x;
                end else begin
                    acc = acc + x;
                    scan[i*WIDTH +: WIDTH] = acc;   // sum including this lane
                end
            end
        end
    endfunction

    // ---- golden delay lines (index [0] newest, [LAT-1] aligns with DUT) -----
    logic [LANES*WIDTH-1:0] exp_i [0:LAT_I-1];
    logic                   vld_i [0:LAT_I-1];
    logic [LANES*WIDTH-1:0] exp_e [0:LAT_E-1];
    logic                   vld_e [0:LAT_E-1];

    integer j;
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            for (j = 0; j < LAT_I; j++) begin exp_i[j] <= '0; vld_i[j] <= 1'b0; end
            for (j = 0; j < LAT_E; j++) begin exp_e[j] <= '0; vld_e[j] <= 1'b0; end
        end else begin
            // inclusive line
            exp_i[0] <= scan(in_data, 1'b0);
            vld_i[0] <= in_valid;
            for (j = 1; j < LAT_I; j++) begin
                exp_i[j] <= exp_i[j-1];
                vld_i[j] <= vld_i[j-1];
            end
            // exclusive line
            exp_e[0] <= scan(in_data, 1'b1);
            vld_e[0] <= in_valid;
            for (j = 1; j < LAT_E; j++) begin
                exp_e[j] <= exp_e[j-1];
                vld_e[j] <= vld_e[j-1];
            end
        end
    end

    // ---- comparison (checked one delta after the clock edge) ---------------
    always @(posedge clk) begin
        if (rst_n) begin
            if (o_valid_i) begin
                checks++;
                if (!vld_i[LAT_I-1] || o_data_i !== exp_i[LAT_I-1]) begin
                    errors++;
                    $display("[%0t] INCL MISMATCH  dut=%h exp=%h vld=%b",
                             $time, o_data_i, exp_i[LAT_I-1], vld_i[LAT_I-1]);
                end
            end
            if (o_valid_e) begin
                checks++;
                if (!vld_e[LAT_E-1] || o_data_e !== exp_e[LAT_E-1]) begin
                    errors++;
                    $display("[%0t] EXCL MISMATCH  dut=%h exp=%h vld=%b",
                             $time, o_data_e, exp_e[LAT_E-1], vld_e[LAT_E-1]);
                end
            end
        end
    end

    // ---- helper: pack a lane array into a bus ------------------------------
    logic [WIDTH-1:0] lane [0:LANES-1];
    function automatic [LANES*WIDTH-1:0] pack;
        int i;
        begin
            pack = '0;
            for (i = 0; i < LANES; i++) pack[i*WIDTH +: WIDTH] = lane[i];
        end
    endfunction

    task automatic drive(input [LANES*WIDTH-1:0] v);
        begin
            @(negedge clk);
            in_valid = 1'b1;
            in_data  = v;
        end
    endtask

    // ---- stimulus ----------------------------------------------------------
    integer i, t;
    logic [LANES*WIDTH-1:0] rv;
    initial begin
        $dumpfile("prefix_scan.vcd");
        $dumpvars(0, tb_prefix_scan);

        in_valid = 1'b0;
        in_data  = '0;
        rst_n    = 1'b0;
        repeat (4) @(negedge clk);
        rst_n = 1'b1;
        @(negedge clk);

        // ---- directed corner cases (one vector per cycle) ------------------
        // all zeros
        for (i = 0; i < LANES; i++) lane[i] = 16'd0;
        drive(pack());

        // unit ramp -> inclusive gives triangular numbers 1,3,6,10,...
        for (i = 0; i < LANES; i++) lane[i] = i[WIDTH-1:0] + 16'd1;
        drive(pack());

        // all ones -> inclusive = 1,2,3,...,LANES
        for (i = 0; i < LANES; i++) lane[i] = 16'd1;
        drive(pack());

        // alternating 3 / 0
        for (i = 0; i < LANES; i++) lane[i] = (i % 2 == 0) ? 16'd3 : 16'd0;
        drive(pack());

        // descending
        for (i = 0; i < LANES; i++) lane[i] = (LANES - i);
        drive(pack());

        // single-hot at lane 0
        for (i = 0; i < LANES; i++) lane[i] = (i == 0) ? 16'd100 : 16'd0;
        drive(pack());

        // single-hot at last lane
        for (i = 0; i < LANES; i++) lane[i] = (i == LANES-1) ? 16'd100 : 16'd0;
        drive(pack());

        // overflow / wrap: large values so the running sum wraps mod 2^WIDTH
        for (i = 0; i < LANES; i++) lane[i] = 16'hC000;
        drive(pack());

        // ---- gap in the stream (in_valid low) ------------------------------
        @(negedge clk); in_valid = 1'b0; in_data = '0;
        @(negedge clk);

        // ---- back-to-back randomized vectors -------------------------------
        for (t = 0; t < 200; t++) begin
            for (i = 0; i < LANES; i++) lane[i] = $random;
            drive(pack());
        end

        // idle then a final vector to flush
        @(negedge clk); in_valid = 1'b0; in_data = '0;
        repeat (LAT_E + 4) @(negedge clk);

        // ---- report --------------------------------------------------------
        $display("-----------------------------------------------------------");
        $display("prefix_scan: %0d outputs checked, %0d mismatches", checks, errors);
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
