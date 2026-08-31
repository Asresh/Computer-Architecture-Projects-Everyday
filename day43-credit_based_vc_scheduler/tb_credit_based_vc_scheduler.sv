// Author: Asresh Kuricheti
// Self-checking directed and randomized testbench.
//
//   stimulus ---> DUT grant/credits ---> checks
//       |                                  ^
//       +--------> golden model -----------+

`timescale 1ns/1ps

module tb_credit_based_vc_scheduler;
    localparam integer NUM_VCS = 4;
    localparam integer DEPTH = 4;
    localparam integer VC_BITS = 2;
    localparam integer CREDIT_BITS = 3;

    logic clk;
    logic rst_n;
    logic [NUM_VCS-1:0] req_valid;
    logic grant_ready;
    logic credit_return_valid;
    logic [VC_BITS-1:0] credit_return_vc;
    logic grant_valid;
    logic [NUM_VCS-1:0] grant_onehot;
    logic [VC_BITS-1:0] grant_vc;
    logic [NUM_VCS-1:0] credit_available;
    logic [NUM_VCS*CREDIT_BITS-1:0] credit_count_flat;
    logic protocol_error;

    integer model_credit [0:NUM_VCS-1];
    integer model_rr;
    integer expected_vc;
    integer expected_valid;
    integer checks;
    integer cycle_count;
    integer i;
    integer k;
    integer idx;
    logic   model_error;

    credit_based_vc_scheduler #(
        .NUM_VCS(NUM_VCS),
        .BUFFER_DEPTH(DEPTH)
    ) dut (.*);

    always #5 clk = ~clk;

    task automatic fail(input string message);
        begin
            $display("ERROR: cycle %0d: %s", cycle_count, message);
            $fatal(1);
        end
    endtask

    task automatic apply_cycle(
        input logic [NUM_VCS-1:0] requests,
        input logic               ready,
        input logic               return_valid,
        input integer             return_vc
    );
        integer scanned;
        begin
            @(negedge clk);
            req_valid           = requests;
            grant_ready         = ready;
            credit_return_valid = return_valid;
            credit_return_vc    = return_vc[VC_BITS-1:0];
            #1;

            expected_valid = 0;
            expected_vc = 0;
            for (scanned = 0; scanned < NUM_VCS; scanned = scanned + 1) begin
                idx = model_rr + scanned;
                if (idx >= NUM_VCS)
                    idx = idx - NUM_VCS;
                if (!expected_valid && requests[idx] && (model_credit[idx] > 0)) begin
                    expected_valid = 1;
                    expected_vc = idx;
                end
            end

            checks = checks + 1;
            if (grant_valid !== expected_valid[0])
                fail("grant_valid differs from golden scheduler");
            if (expected_valid) begin
                checks = checks + 2;
                if (grant_vc !== expected_vc[VC_BITS-1:0])
                    fail("grant_vc differs from round-robin golden model");
                if (grant_onehot !== ({{(NUM_VCS-1){1'b0}}, 1'b1} << expected_vc))
                    fail("grant_onehot is not the expected one-hot value");
            end else if (grant_onehot !== '0) begin
                fail("grant_onehot asserted without a valid grant");
            end

            for (k = 0; k < NUM_VCS; k = k + 1) begin
                checks = checks + 2;
                if (credit_count_flat[k*CREDIT_BITS +: CREDIT_BITS] !== model_credit[k])
                    fail("visible credit count differs from golden model");
                if (credit_available[k] !== (model_credit[k] > 0))
                    fail("credit_available differs from golden model");
            end
            if (protocol_error !== model_error)
                fail("protocol_error differs from golden model");

            @(posedge clk);
            cycle_count = cycle_count + 1;
            if (expected_valid && ready) begin
                if (!(return_valid && (return_vc == expected_vc)))
                    model_credit[expected_vc] = model_credit[expected_vc] - 1;
                model_rr = (expected_vc + 1) % NUM_VCS;
            end
            if (return_valid) begin
                if (!(expected_valid && ready && (return_vc == expected_vc))) begin
                    if (model_credit[return_vc] < DEPTH)
                        model_credit[return_vc] = model_credit[return_vc] + 1;
                    else
                        model_error = 1'b1;
                end
            end
            #1;
        end
    endtask

    initial begin
        $dumpfile("credit_based_vc_scheduler.vcd");
        $dumpvars(0, tb_credit_based_vc_scheduler);
        clk = 1'b0;
        rst_n = 1'b0;
        req_valid = '0;
        grant_ready = 1'b0;
        credit_return_valid = 1'b0;
        credit_return_vc = '0;
        checks = 0;
        cycle_count = 0;
        model_rr = 0;
        model_error = 1'b0;
        for (i = 0; i < NUM_VCS; i = i + 1)
            model_credit[i] = DEPTH;

        repeat (3) @(posedge clk);
        rst_n = 1'b1;

        // Directed: fairness with all VCs requesting.
        apply_cycle(4'b1111, 1'b1, 1'b0, 0);
        apply_cycle(4'b1111, 1'b1, 1'b0, 0);
        apply_cycle(4'b1111, 1'b1, 1'b0, 0);
        apply_cycle(4'b1111, 1'b1, 1'b0, 0);

        // Directed: backpressure holds accounting; simultaneous send/return is net zero.
        apply_cycle(4'b0011, 1'b0, 1'b0, 0);
        apply_cycle(4'b0011, 1'b1, 1'b1, 0);

        // Drain VC 2, prove that a creditless requester is skipped, then replenish it.
        apply_cycle(4'b0100, 1'b1, 1'b0, 0);
        apply_cycle(4'b0100, 1'b1, 1'b0, 0);
        apply_cycle(4'b0100, 1'b1, 1'b0, 0);
        apply_cycle(4'b0100, 1'b1, 1'b0, 0);
        apply_cycle(4'b1100, 1'b1, 1'b0, 0);
        apply_cycle(4'b0100, 1'b1, 1'b1, 2);

        // Return to a full VC without a matching send: protocol violation.
        apply_cycle(4'b0000, 1'b1, 1'b1, 1);

        // Randomized stress, including backpressure and independent credit returns.
        for (i = 0; i < 500; i = i + 1)
            apply_cycle($urandom_range(0, 15), $urandom_range(0, 1),
                        $urandom_range(0, 1), $urandom_range(0, NUM_VCS-1));

        $display("Checked %0d scheduler and credit-accounting properties", checks);
        $display("RESULT: *** PASS ***");
        $finish;
    end

    initial begin
        #100000;
        $fatal(1, "TIMEOUT: testbench did not complete");
    end
endmodule
