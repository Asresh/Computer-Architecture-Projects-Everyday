// ============================================================================
// tb_booth_mul.sv  -  self-checking testbench for the radix-4 Booth multiplier
// ----------------------------------------------------------------------------
// Golden reference model: the plain SystemVerilog signed product `a * b`. Every
// DUT result is compared against it. Includes:
//   * directed corner cases (0, +/-1, max/min, sign combinations) that also
//     form the on-screen waveform window,
//   * an EXHAUSTIVE sweep of all 2^WIDTH x 2^WIDTH signed operand pairs,
//   * a randomized burst,
//   * a global timeout watchdog,
//   * a VCD dump for waveform rendering.
// Prints "RESULT: *** PASS ***" only if every comparison matched.
// ============================================================================
`default_nettype none
`timescale 1ns/1ps

module tb_booth_mul;

    localparam int WIDTH = 8;

    // ---- DUT I/O ------------------------------------------------------------
    logic                       clk = 1'b0;
    logic                       rst_n;
    logic                       start;
    logic signed [WIDTH-1:0]    multiplicand;
    logic signed [WIDTH-1:0]    multiplier;
    logic signed [2*WIDTH-1:0]  product;
    logic                       busy;
    logic                       done;

    integer errors = 0;
    integer checks = 0;

    // ---- 10 ns clock --------------------------------------------------------
    always #5 clk = ~clk;

    // ---- DUT ----------------------------------------------------------------
    booth_mul #(.WIDTH(WIDTH)) dut (
        .clk          (clk),
        .rst_n        (rst_n),
        .start        (start),
        .multiplicand (multiplicand),
        .multiplier   (multiplier),
        .product      (product),
        .busy         (busy),
        .done         (done)
    );

    // ---- one multiply, checked against the golden reference -----------------
    task automatic do_mul(input signed [WIDTH-1:0] a,
                          input signed [WIDTH-1:0] b);
        logic signed [2*WIDTH-1:0] golden;
        begin
            golden = a * b;                       // reference model

            @(negedge clk);
            multiplicand = a;
            multiplier   = b;
            start        = 1'b1;
            @(negedge clk);
            start        = 1'b0;

            // wait for the done pulse (watchdog covers a hang)
            wait (done == 1'b1);
            @(negedge clk);                       // sample the settled product

            checks = checks + 1;
            if (product !== golden) begin
                errors = errors + 1;
                $display("  MISMATCH: %0d * %0d = got %0d (0x%0h), exp %0d (0x%0h)",
                         a, b, product, product, golden, golden);
            end
        end
    endtask

    // ---- stimulus -----------------------------------------------------------
    integer i, j;
    logic signed [WIDTH-1:0] ra, rb;

    initial begin
        $dumpfile("booth_mul.vcd");
        $dumpvars(0, tb_booth_mul);

        start        = 1'b0;
        multiplicand = '0;
        multiplier   = '0;
        rst_n        = 1'b0;
        repeat (3) @(negedge clk);
        rst_n        = 1'b1;
        @(negedge clk);

        // ---- directed corner cases (this is the rendered waveform window) ---
        do_mul( 8'sd7,   8'sd6);     //  positive * positive  = 42
        do_mul(-8'sd7,   8'sd6);     //  negative * positive  = -42
        do_mul( 8'sd7,  -8'sd6);     //  positive * negative  = -42
        do_mul(-8'sd7,  -8'sd6);     //  negative * negative  = 42
        do_mul( 8'sd0,   8'sd123);   //  zero
        do_mul( 8'sd1,  -8'sd128);   //  identity * most-negative
        do_mul(-8'sd128,-8'sd128);   //  min * min = +16384 (extreme)
        do_mul( 8'sd127, 8'sd127);   //  max * max = +16129

        // ---- exhaustive signed sweep ---------------------------------------
        for (i = -(1<<(WIDTH-1)); i < (1<<(WIDTH-1)); i = i + 1)
            for (j = -(1<<(WIDTH-1)); j < (1<<(WIDTH-1)); j = j + 1)
                do_mul(i[WIDTH-1:0], j[WIDTH-1:0]);

        // ---- randomized burst ----------------------------------------------
        for (i = 0; i < 500; i = i + 1) begin
            ra = $random;
            rb = $random;
            do_mul(ra, rb);
        end

        // ---- verdict --------------------------------------------------------
        $display("checks run: %0d", checks);
        if (errors == 0)
            $display("RESULT: *** PASS ***");
        else
            $display("RESULT: *** FAIL *** (%0d mismatches)", errors);
        $finish;
    end

    // ---- timeout watchdog ---------------------------------------------------
    initial begin
        #5_000_000;                                // 5 ms of sim time
        $display("RESULT: *** FAIL *** (timeout)");
        $fatal(1, "timeout: DUT never asserted done");
    end

endmodule

`default_nettype wire
