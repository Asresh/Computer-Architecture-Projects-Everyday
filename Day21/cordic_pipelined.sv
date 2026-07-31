// -----------------------------------------------------------------------------
// cordic_pipelined.sv
// -----------------------------------------------------------------------------
// Fully-pipelined, dual-mode CORDIC engine (circular coordinate system).
//
//   ROTATION  mode (mode=0): drives z -> 0.  Feed x0 = K (~0.6073, the CORDIC-gain
//                            reciprocal seed), y0 = 0, z0 = theta
//                            => x_out = cos(theta), y_out = sin(theta).
//   VECTORING mode (mode=1): drives y -> 0.  Feed (x0, y0), z0 = 0
//                            => x_out = K*sqrt(x0^2+y0^2), z_out = atan2(y0, x0).
//
// One rotation micro-step is mapped to one registered pipeline stage, so the
// engine accepts a NEW operand every cycle and produces one result every cycle
// at a FIXED, data-independent latency of (ITERS + 1) cycles. Every per-stage
// shift is by a compile-time-constant amount (the stage index) -> no variable
// bit-selects, no data-dependent control flow: purely structural, lint-clean,
// and directly synthesizable to an FPGA/ASIC shift-add array.
//
// Fixed-point format: signed Q(W-1-FRAC).FRAC. Defaults W=16, FRAC=13 give a
// range of [-4.0, +4.0) with a resolution of 2^-13. Data path carries GUARD
// extra integer guard bits internally so the running vector (which grows by the
// CORDIC gain 1/K ~= 1.6468) never overflows for the documented input domain.
// -----------------------------------------------------------------------------
`timescale 1ns/1ps

module cordic_pipelined #(
    parameter int W     = 16,   // external x/y/z width (signed Q(W-1-FRAC).FRAC)
    parameter int ITERS = 14,   // number of CORDIC rotation stages (= pipeline depth)
    parameter int FRAC  = 13,   // fractional bits
    parameter int GUARD = 4     // extra internal integer guard bits (overflow margin)
) (
    input  logic                clk,
    input  logic                rst_n,

    input  logic                in_valid,   // assert to launch a new operand this cycle
    input  logic                mode,        // 0 = ROTATION, 1 = VECTORING
    input  logic signed [W-1:0] x_in,
    input  logic signed [W-1:0] y_in,
    input  logic signed [W-1:0] z_in,

    output logic                out_valid,   // result valid (latency ITERS+1 after in_valid)
    output logic                out_mode,    // mode that produced the current result (pipelined)
    output logic signed [W-1:0] x_out,
    output logic signed [W-1:0] y_out,
    output logic signed [W-1:0] z_out
);

    localparam int IW = W + GUARD;  // internal datapath width

    // --------------------------------------------------------------------------
    // atan(2^-i) look-up table, in the same Q.FRAC angle format (FRAC=13 scale).
    // Values are round(atan(2^-i) * 2^FRAC). Kept as a function (Icarus does not
    // support unpacked-array parameters) indexed by the constant stage number.
    // --------------------------------------------------------------------------
    function automatic logic signed [IW-1:0] atan_tab(input int unsigned i);
        case (i)
            0:  atan_tab = 'sd6434;  // atan(1)      = 0.785398 rad
            1:  atan_tab = 'sd3798;  // atan(1/2)    = 0.463648
            2:  atan_tab = 'sd2007;  // atan(1/4)    = 0.244979
            3:  atan_tab = 'sd1019;  // atan(1/8)    = 0.124355
            4:  atan_tab = 'sd511;   // atan(1/16)   = 0.062419
            5:  atan_tab = 'sd256;   // atan(1/32)   = 0.031240
            6:  atan_tab = 'sd128;   // atan(1/64)   = 0.015624
            7:  atan_tab = 'sd64;    // atan(1/128)  = 0.007812
            8:  atan_tab = 'sd32;    // atan(1/256)  = 0.003906
            9:  atan_tab = 'sd16;    // atan(1/512)  = 0.001953
            10: atan_tab = 'sd8;     // atan(1/1024) = 0.000977
            11: atan_tab = 'sd4;
            12: atan_tab = 'sd2;
            13: atan_tab = 'sd1;
            default: atan_tab = '0;
        endcase
    endfunction

    // --------------------------------------------------------------------------
    // Pipeline state. Index [0] is the input-latch stage; [k] holds the vector
    // after (k) rotation micro-steps. The result leaves at index [ITERS].
    // --------------------------------------------------------------------------
    logic signed [IW-1:0] x_s [0:ITERS];
    logic signed [IW-1:0] y_s [0:ITERS];
    logic signed [IW-1:0] z_s [0:ITERS];
    logic                 v_s [0:ITERS];
    logic                 m_s [0:ITERS];

    // Stage 0: register (sign-extended) inputs.
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            x_s[0] <= '0; y_s[0] <= '0; z_s[0] <= '0;
            v_s[0] <= 1'b0; m_s[0] <= 1'b0;
        end else begin
            x_s[0] <= IW'(x_in);   // signed extension (x_in is signed)
            y_s[0] <= IW'(y_in);
            z_s[0] <= IW'(z_in);
            v_s[0] <= in_valid;
            m_s[0] <= mode;
        end
    end

    // Stages 1..ITERS: one CORDIC rotation micro-step per stage.
    //   d = +1 : x -= y>>>i ; y += x>>>i ; z -= atan[i]
    //   d = -1 : x += y>>>i ; y -= x>>>i ; z += atan[i]
    // Direction: ROTATION drives z->0 (d = sign of z); VECTORING drives y->0
    // (d = -sign of y). The >>> shift amount is the constant stage index i.
    genvar i;
    generate
        for (i = 0; i < ITERS; i++) begin : g_stage
            logic                 dpos;   // 1 => d = +1
            logic signed [IW-1:0] xsh, ysh;
            logic signed [IW-1:0] xn, yn, zn;

            always_comb begin
                xsh  = x_s[i] >>> i;                       // arithmetic shift, constant i
                ysh  = y_s[i] >>> i;
                // ROTATION: d=+1 when z>=0 (sign bit 0). VECTORING: d=+1 when y<0 (sign bit 1).
                dpos = m_s[i] ? (y_s[i][IW-1] == 1'b1)
                              : (z_s[i][IW-1] == 1'b0);
                if (dpos) begin
                    xn = x_s[i] - ysh;
                    yn = y_s[i] + xsh;
                    zn = z_s[i] - atan_tab(i);
                end else begin
                    xn = x_s[i] + ysh;
                    yn = y_s[i] - xsh;
                    zn = z_s[i] + atan_tab(i);
                end
            end

            always_ff @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    x_s[i+1] <= '0; y_s[i+1] <= '0; z_s[i+1] <= '0;
                    v_s[i+1] <= 1'b0; m_s[i+1] <= 1'b0;
                end else begin
                    x_s[i+1] <= xn;
                    y_s[i+1] <= yn;
                    z_s[i+1] <= zn;
                    v_s[i+1] <= v_s[i];
                    m_s[i+1] <= m_s[i];
                end
            end
        end
    endgenerate

    // Output: low W bits of the internal vector (exact for the documented domain).
    assign x_out     = x_s[ITERS][W-1:0];
    assign y_out     = y_s[ITERS][W-1:0];
    assign z_out     = z_s[ITERS][W-1:0];
    assign out_valid = v_s[ITERS];
    assign out_mode  = m_s[ITERS];

endmodule
