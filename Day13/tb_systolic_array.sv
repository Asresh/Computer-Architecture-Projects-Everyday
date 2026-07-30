// tb_systolic_array.sv - Day 13
//
// Self-checking testbench for the output-stationary systolic array.
//
// Reference model: a plain triple-nested signed integer matrix multiply
// (C = A * B) computed in the testbench. Every DUT result is compared element
// by element against this golden model. Stimulus is directed (identity, zeros,
// a hand-worked case, negative operands) plus randomized signed matrices.
// A global watchdog guarantees termination and a VCD is dumped for waveforms.

`default_nettype none
`timescale 1ns/1ps

module tb_systolic_array;

    localparam int N     = 4;
    localparam int IN_W  = 8;
    localparam int ACC_W = 32;

    // ---- DUT interface -----------------------------------------------------
    logic                    clk, rst_n, start, busy, done;
    logic [N*N*IN_W-1:0]     a_in, b_in;
    logic [N*N*ACC_W-1:0]    c_out;

    integer errors = 0;
    integer tests  = 0;

    systolic_array #(.N(N), .IN_W(IN_W), .ACC_W(ACC_W)) dut (
        .clk(clk), .rst_n(rst_n), .start(start),
        .a_in(a_in), .b_in(b_in),
        .busy(busy), .done(done), .c_out(c_out)
    );

    // ---- Clock -------------------------------------------------------------
    initial clk = 1'b0;
    always #5 clk = ~clk;

    // ---- Waveform probes ---------------------------------------------------
    // Unpacked PE arrays are not dumped element-by-element by every simulator,
    // so mirror a few interior datapath nodes into packed probe wires that do
    // appear in the VCD (via hierarchical references into the DUT).
    wire signed [IN_W-1:0]  p_west0  = dut.west_in[0];
    wire signed [IN_W-1:0]  p_north0 = dut.north_in[0];
    wire signed [IN_W-1:0]  p_areg00 = dut.a_reg[0][0];
    wire signed [IN_W-1:0]  p_breg00 = dut.b_reg[0][0];
    wire signed [ACC_W-1:0] p_acc00  = dut.acc[0][0];
    wire signed [ACC_W-1:0] p_acc11  = dut.acc[1][1];
    wire signed [ACC_W-1:0] p_c00    = c_out[0*ACC_W +: ACC_W];

    // ---- Waveform dump -----------------------------------------------------
    initial begin
        $dumpfile("systolic_array.vcd");
        $dumpvars(0, tb_systolic_array);
    end

    // ---- Watchdog ----------------------------------------------------------
    initial begin
        #200000;
        $display("RESULT: *** FAIL *** (global timeout)");
        $fatal(1);
    end

    // ---- Software matrices + golden reference ------------------------------
    logic signed [IN_W-1:0]  A [N][N];
    logic signed [IN_W-1:0]  B [N][N];
    logic signed [ACC_W-1:0] Cexp [N][N];

    function automatic void pack_inputs();
        for (int i = 0; i < N; i++)
            for (int j = 0; j < N; j++) begin
                a_in[(i*N + j)*IN_W +: IN_W] = A[i][j];
                b_in[(i*N + j)*IN_W +: IN_W] = B[i][j];
            end
    endfunction

    function automatic void ref_matmul();
        for (int i = 0; i < N; i++)
            for (int j = 0; j < N; j++) begin
                logic signed [ACC_W-1:0] s;
                s = '0;
                for (int k = 0; k < N; k++)
                    s = s + ACC_W'(A[i][k]) * ACC_W'(B[k][j]);
                Cexp[i][j] = s;
            end
    endfunction

    // Operand fills. `sel` picks the target matrix (0 = A, 1 = B) so we avoid
    // passing unpacked arrays as subroutine ports (not supported everywhere).
    // mode: 0 = zeros, 1 = identity, 2 = 1,2,3,... sequence, 3 = random byte.
    task automatic fill(input int sel, input int mode);
        for (int i = 0; i < N; i++)
            for (int j = 0; j < N; j++) begin
                logic signed [IN_W-1:0] v;
                case (mode)
                    1:       v = (i == j) ? 8'sd1 : 8'sd0;
                    2:       v = IN_W'(i*N + j + 1);
                    3:       v = IN_W'($random);
                    default: v = '0;
                endcase
                if (sel == 0) A[i][j] = v;
                else          B[i][j] = v;
            end
    endtask

    // ---- Drive one multiply pass and check it ------------------------------
    task automatic run_case(input string label);
        logic signed [ACC_W-1:0] got;
        int case_err;
        case_err = 0;

        pack_inputs();
        ref_matmul();

        @(negedge clk);
        start = 1'b1;
        @(negedge clk);
        start = 1'b0;

        wait (done == 1'b1);      // asserted the cycle the result is final
        @(negedge clk);           // sample c_out cleanly after the pulse

        tests++;
        for (int i = 0; i < N; i++)
            for (int j = 0; j < N; j++) begin
                got = c_out[(i*N + j)*ACC_W +: ACC_W];
                if (got !== Cexp[i][j]) begin
                    errors++;
                    case_err++;
                    $display("  MISMATCH [%s] C[%0d][%0d]: got %0d exp %0d",
                             label, i, j, got, Cexp[i][j]);
                end
            end
        $display("  [%-8s] %0dx%0d product checked - %s",
                 label, N, N, (case_err == 0) ? "ok" : "FAIL");
    endtask

    // ---- Test program ------------------------------------------------------
    initial begin
        rst_n = 1'b0; start = 1'b0; a_in = '0; b_in = '0;
        repeat (3) @(negedge clk);
        rst_n = 1'b1;
        @(negedge clk);

        $display("Day13 systolic array %0dx%0d signed matmul - self-check", N, N);

        // Directed: A = I, B = sequence  ->  C = B
        fill(0, 1); fill(1, 2); run_case("I*seq");
        // Directed: B = I, A = sequence  ->  C = A
        fill(0, 2); fill(1, 1); run_case("seq*I");
        // Directed: all zeros -> zero
        fill(0, 0); fill(1, 2); run_case("0*seq");
        // Directed: sequence * sequence (dense, all positive)
        fill(0, 2); fill(1, 2); run_case("seq*seq");

        // Directed: negative operands (sign handling)
        for (int i = 0; i < N; i++)
            for (int j = 0; j < N; j++) begin
                A[i][j] = IN_W'(i - 3);
                B[i][j] = IN_W'(2 - j);
            end
        run_case("signed");

        // Randomized signed matrices
        for (int trial = 0; trial < 24; trial++) begin
            fill(0, 3); fill(1, 3);
            run_case($sformatf("rand%0d", trial));
        end

        $display("Ran %0d matmul cases, %0d element mismatches.", tests, errors);
        if (errors == 0)
            $display("RESULT: *** PASS ***");
        else
            $display("RESULT: *** FAIL *** (%0d mismatches)", errors);
        $finish;
    end

endmodule

`default_nettype wire
