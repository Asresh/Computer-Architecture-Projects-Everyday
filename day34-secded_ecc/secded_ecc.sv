// Author: Asresh Kuricheti
// -----------------------------------------------------------------------------
// Day 34 - Parameterized SECDED ECC pipeline
//
//   data_in -> Hamming encoder -> codeword_out
//   codeword_in -> syndrome/classifier -> correction -> data_out
//
// One request is accepted per cycle. Results are registered one cycle later.
// The code uses an extended Hamming code: R positional parity bits plus one
// overall parity bit. It corrects any single-bit error and detects every
// double-bit error within the SECDED fault model.
// -----------------------------------------------------------------------------
`timescale 1ns/1ps

module secded_ecc #(
    parameter int DATA_WIDTH = 32,
    parameter int PARITY_BITS = 6,
    parameter int CODE_WIDTH = DATA_WIDTH + PARITY_BITS + 1
) (
    input  logic                  clk,
    input  logic                  rst_n,
    input  logic                  req_valid,
    input  logic                  req_encode,
    input  logic [DATA_WIDTH-1:0] data_in,
    input  logic [CODE_WIDTH-1:0] codeword_in,
    output logic                  resp_valid,
    output logic [CODE_WIDTH-1:0] codeword_out,
    output logic [DATA_WIDTH-1:0] data_out,
    output logic                  single_error,
    output logic                  double_error,
    output logic [PARITY_BITS:0]  error_position
);

    localparam int HAMMING_WIDTH = DATA_WIDTH + PARITY_BITS;

    logic [CODE_WIDTH-1:0] encoded_next;
    logic [CODE_WIDTH-1:0] corrected_next;
    logic [DATA_WIDTH-1:0] decoded_next;
    logic [PARITY_BITS-1:0] syndrome_next;
    logic overall_error_next;
    logic single_next, double_next;
    logic [PARITY_BITS:0] position_next;

    integer pos, parity, data_index;
    always_comb begin
        encoded_next = '0;
        data_index = 0;

        // Hamming positions are one-based. Powers of two are parity slots.
        for (pos = 1; pos <= HAMMING_WIDTH; pos = pos + 1) begin
            if ((pos & (pos - 1)) != 0) begin
                if (data_index < DATA_WIDTH)
                    encoded_next[pos-1] = data_in[data_index];
                data_index = data_index + 1;
            end
        end

        // Each positional parity bit covers positions with its address bit set.
        for (parity = 0; parity < PARITY_BITS; parity = parity + 1) begin
            encoded_next[(1 << parity)-1] = 1'b0;
            for (pos = 1; pos <= HAMMING_WIDTH; pos = pos + 1)
                if ((pos & (1 << parity)) != 0)
                    encoded_next[(1 << parity)-1] =
                        encoded_next[(1 << parity)-1] ^ encoded_next[pos-1];
        end

        // The extra MSB makes the complete codeword even parity.
        encoded_next[CODE_WIDTH-1] = ^encoded_next[HAMMING_WIDTH-1:0];
    end

    integer dpos, dparity, decode_index;
    always_comb begin
        syndrome_next = '0;
        for (dparity = 0; dparity < PARITY_BITS; dparity = dparity + 1)
            for (dpos = 1; dpos <= HAMMING_WIDTH; dpos = dpos + 1)
                if ((dpos & (1 << dparity)) != 0)
                    syndrome_next[dparity] = syndrome_next[dparity] ^
                                             codeword_in[dpos-1];

        overall_error_next = ^codeword_in;
        corrected_next = codeword_in;
        single_next = 1'b0;
        double_next = 1'b0;
        position_next = '0;

        if (overall_error_next) begin
            single_next = 1'b1;
            if (syndrome_next == '0) begin
                corrected_next[CODE_WIDTH-1] = ~codeword_in[CODE_WIDTH-1];
                position_next = CODE_WIDTH;
            end else if (syndrome_next <= HAMMING_WIDTH) begin
                corrected_next[syndrome_next-1] = ~codeword_in[syndrome_next-1];
                position_next = {1'b0, syndrome_next};
            end
        end else if (syndrome_next != '0) begin
            double_next = 1'b1;
        end

        decoded_next = '0;
        decode_index = 0;
        for (dpos = 1; dpos <= HAMMING_WIDTH; dpos = dpos + 1) begin
            if ((dpos & (dpos - 1)) != 0) begin
                if (decode_index < DATA_WIDTH)
                    decoded_next[decode_index] = corrected_next[dpos-1];
                decode_index = decode_index + 1;
            end
        end
    end

    initial begin
        if ((1 << PARITY_BITS) < (DATA_WIDTH + PARITY_BITS + 1))
            $error("PARITY_BITS is too small for DATA_WIDTH");
        if (CODE_WIDTH != DATA_WIDTH + PARITY_BITS + 1)
            $error("CODE_WIDTH must equal DATA_WIDTH + PARITY_BITS + 1");
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            resp_valid     <= 1'b0;
            codeword_out   <= '0;
            data_out       <= '0;
            single_error   <= 1'b0;
            double_error   <= 1'b0;
            error_position <= '0;
        end else begin
            resp_valid <= req_valid;
            if (req_valid) begin
                if (req_encode) begin
                    codeword_out   <= encoded_next;
                    data_out       <= data_in;
                    single_error   <= 1'b0;
                    double_error   <= 1'b0;
                    error_position <= '0;
                end else begin
                    codeword_out   <= corrected_next;
                    data_out       <= decoded_next;
                    single_error   <= single_next;
                    double_error   <= double_next;
                    error_position <= position_next;
                end
            end
        end
    end
endmodule
