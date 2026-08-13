// -----------------------------------------------------------------------------
// tb_cordic_pipelined.sv  --  self-checking testbench for cordic_pipelined
// -----------------------------------------------------------------------------
// Two independent checks on every result:
//   (1) BIT-EXACT: an in-testbench golden model re-runs the identical fixed-point
//       CORDIC recurrence one-shot and the DUT output must match exactly. An
//       in-order FIFO scoreboard tolerates the pipeline latency automatically
//       (every valid-in yields exactly one valid-out, in program order).
//   (2) MATH ACCURACY: for cos/sin rotation ops, x_out/y_out are additionally
//       compared against real-valued $cos/$sin within a tolerance, proving the
//       fixed-point engine actually computes the trig function (not just that it
//       matches its own model).
// Stimulus = directed corners (angles, quadrant vectors) + thousands of random
// ops with a mix of back-to-back and bubbled launches. A watchdog aborts hangs.
// -----------------------------------------------------------------------------
`timescale 1ns/1ps

module tb_cordic_pipelined;

    localparam int W     = 16;
    localparam int ITERS = 14;
    localparam int FRAC  = 13;
    localparam int GUARD = 4;
    localparam int IW    = W + GUARD;

    localparam real SCALE  = 8192.0;    // 2^FRAC
    localparam int  K_SEED = 4975;      // K in Q2.13 (0.60725). CORDIC gain is 1/K,
                                        // so seeding x0=K makes x_out=cos, y_out=sin.
    localparam real TOL    = 0.010;     // cos/sin accuracy tolerance (~1e-3 expected)

    // ---- DUT I/O ----
    logic                clk, rst_n;
    logic                in_valid, mode;
    logic signed [W-1:0] x_in, y_in, z_in;
    logic                out_valid, out_mode;
    logic signed [W-1:0] x_out, y_out, z_out;

    cordic_pipelined #(.W(W), .ITERS(ITERS), .FRAC(FRAC), .GUARD(GUARD)) dut (
        .clk(clk), .rst_n(rst_n),
        .in_valid(in_valid), .mode(mode), .x_in(x_in), .y_in(y_in), .z_in(z_in),
        .out_valid(out_valid), .out_mode(out_mode),
        .x_out(x_out), .y_out(y_out), .z_out(z_out)
    );

    // ---- clock ----
    initial clk = 1'b0;
    always #5 clk = ~clk;

    // ---- atan table reference (mirror of the DUT) ----
    function automatic logic signed [IW-1:0] atan_ref(input int unsigned i);
        case (i)
            0: atan_ref='sd6434; 1: atan_ref='sd3798; 2: atan_ref='sd2007; 3: atan_ref='sd1019;
            4: atan_ref='sd511;  5: atan_ref='sd256;  6: atan_ref='sd128;  7: atan_ref='sd64;
            8: atan_ref='sd32;   9: atan_ref='sd16;  10: atan_ref='sd8;   11: atan_ref='sd4;
            12: atan_ref='sd2;  13: atan_ref='sd1;   default: atan_ref='0;
        endcase
    endfunction

    // ---- bit-exact golden model: run the same recurrence one-shot ----
    function automatic logic [3*W-1:0] golden(input logic md,
                                              input logic signed [W-1:0] x0, y0, z0);
        logic signed [IW-1:0] x, y, z, xsh, ysh;
        logic dpos;
        int k;
        begin
            x = IW'(x0); y = IW'(y0); z = IW'(z0);
            for (k = 0; k < ITERS; k++) begin
                xsh  = x >>> k;
                ysh  = y >>> k;
                dpos = md ? (y[IW-1] == 1'b1) : (z[IW-1] == 1'b0);
                if (dpos) begin x = x - ysh; y = y + xsh; z = z - atan_ref(k); end
                else      begin x = x + ysh; y = y - xsh; z = z + atan_ref(k); end
            end
            golden = {x[W-1:0], y[W-1:0], z[W-1:0]};
        end
    endfunction

    // ---- scoreboard: one packed entry per launched op ----
    //   {isCS, mode, z0[W], expz[W], expy[W], expx[W]}
    localparam int EW = 4*W + 2;
    logic [EW-1:0] scb [$];

    int    launched, checked, errors;

    task automatic launch(input logic md, input logic isCS,
                          input logic signed [W-1:0] xx, yy, zz);
        logic [3*W-1:0] g;
        begin
            in_valid = 1'b1; mode = md; x_in = xx; y_in = yy; z_in = zz;
            g = golden(md, xx, yy, zz);
            // g = {expx, expy, expz}; slice back out
            scb.push_back({isCS, md, zz, g[1*W-1:0], g[2*W-1:1*W], g[3*W-1:2*W]});
            launched++;
        end
    endtask

    task automatic idle;
        begin in_valid = 1'b0; mode = 1'b0; x_in = '0; y_in = '0; z_in = '0; end
    endtask

    task automatic check_output;
        logic [EW-1:0]       e;
        logic                e_iscs, e_mode;
        logic signed [W-1:0] e_z0, e_x, e_y, e_z;
        real                 ang, rx, ry, gx, gy;
        begin
            if (out_valid) begin
                if (scb.size() == 0) begin
                    errors++;
                    $display("[%0t] ERROR: out_valid with empty scoreboard", $time);
                end else begin
                    e = scb.pop_front();
                    {e_iscs, e_mode, e_z0, e_z, e_y, e_x} = e;
                    checked++;
                    // (1) bit-exact
                    if (x_out !== e_x || y_out !== e_y || z_out !== e_z || out_mode !== e_mode) begin
                        errors++;
                        $display("[%0t] BITEXACT MISMATCH: got x=%0d y=%0d z=%0d m=%0b | exp x=%0d y=%0d z=%0d m=%0b",
                                 $time, x_out, y_out, z_out, out_mode, e_x, e_y, e_z, e_mode);
                    end
                    // (2) math accuracy for cos/sin rotation ops
                    if (e_iscs) begin
                        ang = $itor(e_z0) / SCALE;
                        rx  = $itor(x_out) / SCALE;
                        ry  = $itor(y_out) / SCALE;
                        gx  = $cos(ang);
                        gy  = $sin(ang);
                        if (((rx - gx) > TOL) || ((gx - rx) > TOL) ||
                            ((ry - gy) > TOL) || ((gy - ry) > TOL)) begin
                            errors++;
                            $display("[%0t] ACCURACY FAIL: ang=%f cos got=%f exp=%f | sin got=%f exp=%f",
                                     $time, ang, rx, gx, ry, gy);
                        end
                    end
                end
            end
        end
    endtask

    // ---- watchdog ----
    initial begin
        #200000;
        $display("RESULT: *** FAIL *** (timeout / watchdog fired)");
        $finish;
    end

    // ---- directed vectors ----
    localparam int NDIR = 16;
    logic                d_mode  [0:NDIR-1];
    logic                d_iscs  [0:NDIR-1];
    logic signed [W-1:0] d_x     [0:NDIR-1];
    logic signed [W-1:0] d_y     [0:NDIR-1];
    logic signed [W-1:0] d_z     [0:NDIR-1];

    task automatic setup_directed;
        int j;
        begin
            j = 0;
            // ---- rotation cos/sin, various angles (rad*8192), domain |z|<1.743 ----
            d_mode[j]=0; d_iscs[j]=1; d_x[j]=K_SEED; d_y[j]=0; d_z[j]=      0; j++; // 0
            d_mode[j]=0; d_iscs[j]=1; d_x[j]=K_SEED; d_y[j]=0; d_z[j]=   4096; j++; // +0.5
            d_mode[j]=0; d_iscs[j]=1; d_x[j]=K_SEED; d_y[j]=0; d_z[j]=  -4096; j++; // -0.5
            d_mode[j]=0; d_iscs[j]=1; d_x[j]=K_SEED; d_y[j]=0; d_z[j]=   8192; j++; // +1.0
            d_mode[j]=0; d_iscs[j]=1; d_x[j]=K_SEED; d_y[j]=0; d_z[j]=  -8192; j++; // -1.0
            d_mode[j]=0; d_iscs[j]=1; d_x[j]=K_SEED; d_y[j]=0; d_z[j]=   6434; j++; // +pi/4
            d_mode[j]=0; d_iscs[j]=1; d_x[j]=K_SEED; d_y[j]=0; d_z[j]=  12288; j++; // +1.5
            d_mode[j]=0; d_iscs[j]=1; d_x[j]=K_SEED; d_y[j]=0; d_z[j]= -12288; j++; // -1.5
            // ---- vectoring: magnitude / atan2 (x0>0) ----
            d_mode[j]=1; d_iscs[j]=0; d_x[j]=  8192; d_y[j]=    0; d_z[j]=0; j++;
            d_mode[j]=1; d_iscs[j]=0; d_x[j]=  8192; d_y[j]= 8192; d_z[j]=0; j++;
            d_mode[j]=1; d_iscs[j]=0; d_x[j]=  8192; d_y[j]=-8192; d_z[j]=0; j++;
            d_mode[j]=1; d_iscs[j]=0; d_x[j]=  4096; d_y[j]= 8192; d_z[j]=0; j++;
            d_mode[j]=1; d_iscs[j]=0; d_x[j]=  8192; d_y[j]= 4096; d_z[j]=0; j++;
            d_mode[j]=1; d_iscs[j]=0; d_x[j]=  6000; d_y[j]=-3000; d_z[j]=0; j++;
            d_mode[j]=1; d_iscs[j]=0; d_x[j]=  2000; d_y[j]= 5000; d_z[j]=0; j++;
            d_mode[j]=1; d_iscs[j]=0; d_x[j]=  1000; d_y[j]=  100; d_z[j]=0; j++;
        end
    endtask

    // ---- main ----
    localparam int NRAND = 3000;
    integer t;
    logic                r_mode, r_iscs;
    logic signed [W-1:0] r_x, r_y, r_z;

    initial begin
        $dumpfile("cordic_pipelined.vcd");
        $dumpvars(0, tb_cordic_pipelined);

        launched = 0; checked = 0; errors = 0;
        setup_directed();
        idle();
        rst_n = 1'b0;
        repeat (4) @(negedge clk);
        rst_n = 1'b1;
        @(negedge clk);

        // ---- directed phase (back-to-back) ----
        for (t = 0; t < NDIR; t++) begin
            check_output();
            launch(d_mode[t], d_iscs[t], d_x[t], d_y[t], d_z[t]);
            @(negedge clk);
        end

        // ---- randomized phase (mix of dense + bubbled launches) ----
        for (t = 0; t < NRAND; t++) begin
            check_output();
            if (($random % 5) != 0) begin  // ~80% duty -> exercises full-throughput + bubbles
                r_mode = $random & 1;
                if (r_mode == 1'b0) begin
                    // rotation; ~half are proper cos/sin (x0=K_SEED,y0=0), rest general
                    r_iscs = $random & 1;
                    r_z    = ({$random} % 27801) - 13900;        // |z| < 1.697 rad
                    if (r_iscs) begin r_x = K_SEED; r_y = 0; end
                    else begin
                        r_x = ({$random} % 12001) - 6000;        // -6000..6000
                        r_y = ({$random} % 12001) - 6000;
                    end
                end else begin
                    r_iscs = 1'b0;                              // vectoring: x0>0
                    r_x    = ({$random} % 5000) + 1000;          // 1000..5999
                    r_y    = ({$random} % 12001) - 6000;         // -6000..6000
                    r_z    = 0;
                end
                launch(r_mode, r_iscs, r_x, r_y, r_z);
            end else begin
                idle();
            end
            @(negedge clk);
        end

        // ---- drain the pipeline ----
        idle();
        while (scb.size() > 0) begin
            check_output();
            @(negedge clk);
        end
        // one more to catch the final popped result's timing
        check_output();
        @(negedge clk);

        // ---- verdict ----
        $display("-------------------------------------------------------------");
        $display("launched=%0d  checked=%0d  errors=%0d  (scoreboard left=%0d)",
                 launched, checked, errors, scb.size());
        if (errors == 0 && checked == launched && scb.size() == 0)
            $display("RESULT: *** PASS ***");
        else
            $display("RESULT: *** FAIL ***");
        $finish;
    end

endmodule
