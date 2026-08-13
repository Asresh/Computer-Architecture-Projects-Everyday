// =============================================================================
// tb_recip_nr_pipelined.sv -- self-checking TB for the Day22 pipelined
// Newton-Raphson reciprocal unit.
//
// Golden model: an INDEPENDENT integer reference  round(2^SCALE / x)  computed
// with the simulator's native (128-bit) integer division -- it shares NO logic
// with the NR datapath under test. Because the reciprocal significand carries
// only ~W meaningful bits, results are checked to a relative tolerance of
// 2^-TOLBITS (>= TOLBITS correct bits) plus a 1-ULP slack, which the DUT beats
// with margin (measured worst case ~26 correct bits).
//
// Stimulus:
//   * directed corners  : x = 1,2,3,4,5,7,255,256,2^12, 2^23, 2^24-1, 0xAAAAAA
//   * a div-by-zero probe (x==0 -> div0 flag + saturated result)
//   * NRAND uniformly-random operands, streamed back-to-back to exercise the
//     one-result-per-cycle pipeline (multiple in flight simultaneously).
// A scoreboard queue matches each result to the operand launched LATENCY cycles
// earlier. A global timeout guards against a stalled pipeline.
//
// Prints "RESULT: *** PASS ***" only if every checked result is within budget
// and the exact expected number of results came back.
// =============================================================================
`timescale 1ns/1ps

module tb_recip_nr_pipelined;
    localparam int W       = 24;
    localparam int SCALE   = 2*(W-1);      // 46
    localparam int OW      = SCALE + 1;    // 47
    localparam int LATENCY = 7;            // pipeline depth (in -> out)
    localparam int TOLBITS = 20;           // require >= 20 correct bits
    localparam int NRAND   = 4000;

    logic                clk, rst_n, in_valid, out_valid, div0;
    logic [W-1:0]        x;
    logic [OW-1:0]       y;

    recip_nr_pipelined #(.W(W)) dut (
        .clk(clk), .rst_n(rst_n), .in_valid(in_valid), .x(x),
        .out_valid(out_valid), .div0(div0), .y(y)
    );

    // 10 ns clock
    initial clk = 1'b0;
    always #5 clk = ~clk;

    // ---- independent golden reference: round(2^SCALE / xin) ----
    function automatic [OW+4:0] golden(input logic [W-1:0] xin);
        logic [127:0] num, den, q;
        begin
            if (xin == 0) begin
                golden = {(OW+5){1'b1}};          // div0 -> saturate marker
            end else begin
                num    = (128'd1 << SCALE) + (xin >> 1);  // + half-ULP round
                den    = xin;
                q      = num / den;
                golden = q[OW+4:0];
            end
        end
    endfunction

    // ---- scoreboard: FIFO of expected {x, ref, div0} launched into pipe ----
    logic [W-1:0]   x_q   [$];
    logic [OW+4:0]  ref_q [$];
    logic           z_q   [$];

    integer checks, errs, worst_bits_x, i;
    real    worst_bits;

    task automatic launch(input logic [W-1:0] xin);
        begin
            @(negedge clk);
            in_valid = 1'b1;
            x        = xin;
            x_q.push_back(xin);
            ref_q.push_back(golden(xin));
            z_q.push_back(xin == 0);
        end
    endtask

    task automatic idle_cycle;
        begin
            @(negedge clk);
            in_valid = 1'b0;
            x        = '0;
        end
    endtask

    // ---- result checker: runs every cycle out_valid is high ----
    // tolerance: |y-ref| <= (ref >> TOLBITS) + 1
    always @(posedge clk) begin
        if (rst_n && out_valid) begin
            logic [W-1:0]  xe;
            logic [OW+4:0] re;
            logic          ze;
            logic [OW+4:0] diff, tol;
            real           bits;
            if (ref_q.size() == 0) begin
                $display("FATAL: result with empty scoreboard @%0t", $time);
                errs = errs + 1;
            end else begin
                xe = x_q.pop_front();
                re = ref_q.pop_front();
                ze = z_q.pop_front();
                checks = checks + 1;
                if (ze) begin
                    // div-by-zero: expect div0 asserted and saturated output
                    if (!div0 || y !== {OW{1'b1}}) begin
                        errs = errs + 1;
                        $display("ERR div0: x=0 div0=%b y=%h (want div0=1, y=all-ones)",
                                 div0, y);
                    end
                end else begin
                    if (div0) begin
                        errs = errs + 1;
                        $display("ERR: div0 wrongly set for x=%0d", xe);
                    end
                    diff = (y > re[OW-1:0]) ? (y - re[OW-1:0]) : (re[OW-1:0] - y);
                    tol  = (re[OW-1:0] >> TOLBITS) + 1;
                    if (diff > tol) begin
                        errs = errs + 1;
                        if (errs <= 20)
                            $display("ERR: x=%0d y=%h ref=%h diff=%0d tol=%0d",
                                     xe, y, re[OW-1:0], diff, tol);
                    end
                    // track worst correct-bit count for reporting
                    if (diff != 0) begin
                        bits = $ln(1.0*re[OW-1:0] / diff) / $ln(2.0);
                        if (checks == 1 || bits < worst_bits) begin
                            worst_bits   = bits;
                            worst_bits_x = xe;
                        end
                    end
                end
            end
        end
    end

    // ---- global timeout ----
    initial begin
        #2_000_000;
        $display("RESULT: *** FAIL *** (timeout)");
        $fatal(1, "timeout");
    end

    // ---- VCD ----
    initial begin
        $dumpfile("recip_nr_pipelined.vcd");
        $dumpvars(0, tb_recip_nr_pipelined);
    end

    // ---- directed operand list ----
    logic [W-1:0] directed [];

    initial begin
        checks = 0; errs = 0; worst_bits = 999.0; worst_bits_x = 0;
        in_valid = 1'b0; x = '0; rst_n = 1'b0;

        directed = new[12];
        directed = '{ 24'd1, 24'd2, 24'd3, 24'd4, 24'd5, 24'd7,
                      24'd255, 24'd256, 24'd4096, 24'd8388608,
                      24'hFFFFFF, 24'hAAAAAA };

        repeat (4) @(negedge clk);
        rst_n = 1'b1;
        repeat (2) @(negedge clk);

        // directed corners, streamed back-to-back
        for (i = 0; i < directed.size(); i = i + 1)
            launch(directed[i]);

        // div-by-zero probe
        launch(24'd0);

        // randomized back-to-back stream (one launch per cycle)
        for (i = 0; i < NRAND; i = i + 1) begin
            logic [W-1:0] r;
            r = $urandom;
            if (r == 0) r = 1;               // keep valid operands here
            launch(r);
        end

        // stop driving and let the pipeline drain
        idle_cycle();
        repeat (LATENCY + 4) @(negedge clk);

        // final accounting
        if (ref_q.size() != 0) begin
            $display("ERR: %0d launched ops never produced a result", ref_q.size());
            errs = errs + 1;
        end

        $display("-------------------------------------------------------------");
        $display("Day22 Newton-Raphson reciprocal: checked %0d results, %0d error(s)",
                 checks, errs);
        if (worst_bits < 900.0)
            $display("worst-case accuracy: %.1f correct bits (at x=%0d)  [need >= %0d]",
                     worst_bits, worst_bits_x, TOLBITS);
        else
            $display("all results bit-exact against the rounded golden reference");
        if (errs == 0 && checks == (directed.size() + 1 + NRAND))
            $display("RESULT: *** PASS ***");
        else
            $display("RESULT: *** FAIL *** (%0d errors, %0d checks)", errs, checks);
        $finish;
    end
endmodule
