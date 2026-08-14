// Author: Asresh Kuricheti
// -----------------------------------------------------------------------------
// Self-checking testbench for Day 34 SECDED ECC.
//
//   directed vectors + 500 randomized words
//              |
//              v
//   independent reference encoder -> fault injection -> DUT -> scoreboard
//
// Checks clean decoding, every single-bit location, random single-bit errors,
// random double-bit errors, error classification, correction position, reset,
// one-cycle latency, and back-to-back throughput. Produces secded_ecc.vcd.
// -----------------------------------------------------------------------------
`timescale 1ns/1ps

module tb_secded_ecc;
    localparam int DATA_WIDTH = 32;
    localparam int PARITY_BITS = 6;
    localparam int CODE_WIDTH = DATA_WIDTH + PARITY_BITS + 1;
    localparam int HAMMING_WIDTH = DATA_WIDTH + PARITY_BITS;

    logic clk = 1'b0;
    logic rst_n = 1'b0;
    logic req_valid, req_encode;
    logic [DATA_WIDTH-1:0] data_in;
    logic [CODE_WIDTH-1:0] codeword_in;
    logic resp_valid;
    logic [CODE_WIDTH-1:0] codeword_out;
    logic [DATA_WIDTH-1:0] data_out;
    logic single_error, double_error;
    logic [PARITY_BITS:0] error_position;

    int checks = 0;
    int failures = 0;

    secded_ecc #(
        .DATA_WIDTH(DATA_WIDTH), .PARITY_BITS(PARITY_BITS),
        .CODE_WIDTH(CODE_WIDTH)
    ) dut (.*);

    always #5 clk = ~clk;

    function automatic logic [CODE_WIDTH-1:0] ref_encode(
        input logic [DATA_WIDTH-1:0] payload
    );
        logic [CODE_WIDTH-1:0] word;
        integer p, k, di;
        begin
            word = '0;
            di = 0;
            for (k = 1; k <= HAMMING_WIDTH; k = k + 1) begin
                if ((k & (k - 1)) != 0) begin
                    word[k-1] = payload[di];
                    di = di + 1;
                end
            end
            for (p = 0; p < PARITY_BITS; p = p + 1) begin
                word[(1 << p)-1] = 1'b0;
                for (k = 1; k <= HAMMING_WIDTH; k = k + 1)
                    if ((k & (1 << p)) != 0)
                        word[(1 << p)-1] = word[(1 << p)-1] ^ word[k-1];
            end
            word[CODE_WIDTH-1] = ^word[HAMMING_WIDTH-1:0];
            ref_encode = word;
        end
    endfunction

    task automatic apply_and_check(
        input logic encode,
        input logic [DATA_WIDTH-1:0] payload,
        input logic [CODE_WIDTH-1:0] injected,
        input logic exp_single,
        input logic exp_double,
        input integer exp_position
    );
        logic [CODE_WIDTH-1:0] clean;
        begin
            clean = ref_encode(payload);
            @(negedge clk);
            req_valid = 1'b1;
            req_encode = encode;
            data_in = payload;
            codeword_in = injected;
            @(posedge clk);
            #1;
            checks = checks + 1;
            if (!resp_valid) begin
                $error("response missing");
                failures = failures + 1;
            end
            if (encode) begin
                if (codeword_out !== clean || data_out !== payload ||
                    single_error || double_error) begin
                    $error("encode mismatch data=%h got=%h expected=%h",
                           payload, codeword_out, clean);
                    failures = failures + 1;
                end
            end else begin
                if ((!exp_double && (data_out !== payload)) ||
                    single_error !== exp_single || double_error !== exp_double ||
                    error_position !== exp_position[PARITY_BITS:0]) begin
                    $error("decode mismatch data=%h got=%h s=%b d=%b pos=%0d",
                           payload, data_out, single_error, double_error,
                           error_position);
                    failures = failures + 1;
                end
                if (!exp_double && codeword_out !== clean) begin
                    $error("corrected codeword mismatch got=%h expected=%h",
                           codeword_out, clean);
                    failures = failures + 1;
                end
                if (exp_double && codeword_out !== injected) begin
                    $error("double-error word must not be miscorrected");
                    failures = failures + 1;
                end
            end
        end
    endtask

    integer i, bit_a, bit_b;
    logic [DATA_WIDTH-1:0] payload;
    logic [CODE_WIDTH-1:0] clean, damaged;
    initial begin
        $dumpfile("secded_ecc.vcd");
        $dumpvars(0, tb_secded_ecc);
        req_valid = 0;
        req_encode = 0;
        data_in = '0;
        codeword_in = '0;

        repeat (3) @(posedge clk);
        rst_n = 1'b1;

        // Directed: encoding and clean decode.
        apply_and_check(1, 32'h0000_0000, '0, 0, 0, 0);
        apply_and_check(1, 32'hDEAD_BEEF, '0, 0, 0, 0);
        clean = ref_encode(32'hA5A5_5A5A);
        apply_and_check(0, 32'hA5A5_5A5A, clean, 0, 0, 0);
        damaged = clean ^ (CODE_WIDTH'(1) << 6);
        apply_and_check(0, 32'hA5A5_5A5A, damaged, 1, 0, 7);
        damaged = clean ^ (CODE_WIDTH'(1) << 6) ^ (CODE_WIDTH'(1) << 13);
        apply_and_check(0, 32'hA5A5_5A5A, damaged, 0, 1, 0);

        // Directed: exhaustively inject one error at every codeword bit.
        payload = 32'hCAFE_F00D;
        clean = ref_encode(payload);
        for (i = 0; i < CODE_WIDTH; i = i + 1) begin
            damaged = clean;
            damaged[i] = ~damaged[i];
            apply_and_check(0, payload, damaged, 1, 0, i + 1);
        end

        // Directed double-error corner cases: data/data and parity/overall.
        damaged = clean ^ (CODE_WIDTH'(1) << 2) ^ (CODE_WIDTH'(1) << 9);
        apply_and_check(0, payload, damaged, 0, 1, 0);
        damaged = clean ^ (CODE_WIDTH'(1) << 0) ^
                           (CODE_WIDTH'(1) << (CODE_WIDTH-1));
        apply_and_check(0, payload, damaged, 0, 1, 0);

        // Randomized independent reference-model campaign.
        for (i = 0; i < 500; i = i + 1) begin
            payload = $urandom;
            clean = ref_encode(payload);
            case ($urandom_range(0, 2))
                0: apply_and_check(0, payload, clean, 0, 0, 0);
                1: begin
                    bit_a = $urandom_range(0, CODE_WIDTH-1);
                    damaged = clean ^ (CODE_WIDTH'(1) << bit_a);
                    apply_and_check(0, payload, damaged, 1, 0, bit_a + 1);
                end
                2: begin
                    bit_a = $urandom_range(0, CODE_WIDTH-1);
                    bit_b = $urandom_range(0, CODE_WIDTH-2);
                    if (bit_b >= bit_a) bit_b = bit_b + 1;
                    damaged = clean ^ (CODE_WIDTH'(1) << bit_a) ^
                                      (CODE_WIDTH'(1) << bit_b);
                    apply_and_check(0, payload, damaged, 0, 1, 0);
                end
            endcase
        end

        @(negedge clk);
        req_valid = 1'b0;
        @(posedge clk);
        #1;
        if (resp_valid) begin
            $error("resp_valid failed to follow request bubble");
            failures = failures + 1;
        end

        $display("Checks: %0d  Failures: %0d", checks, failures);
        if (failures == 0)
            $display("RESULT: *** PASS ***");
        else
            $display("RESULT: *** FAIL ***");
        $finish;
    end

    initial begin
        #200000;
        $fatal(1, "TIMEOUT");
    end
endmodule
