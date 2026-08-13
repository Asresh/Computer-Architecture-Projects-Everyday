// ============================================================================
// booth_mul.sv  -  Radix-4 (Modified) Booth signed sequential multiplier
// ----------------------------------------------------------------------------
// Day 8 of the Computer-Architecture-Projects-Everyday series.
//
// Computes a WIDTH x WIDTH -> 2*WIDTH signed product using the classic
// add/shift datapath with modified (radix-4) Booth recoding. Radix-4 encoding
// inspects three bits {Q[1], Q[0], q_-1} of the running multiplier each step
// and folds them into a single signed action from {+0, +M, +2M, -M, -2M}. That
// lets the engine retire TWO multiplier bits per cycle, so an N-bit multiply
// finishes in N/2 iterations instead of N - the same trick real CPU integer
// multipliers use to cut latency.
//
// Datapath (textbook A / Q / q_-1 form):
//   * A     : (WIDTH+2)-bit signed accumulator (wide enough to add +/-2M).
//   * Q     : WIDTH-bit multiplier register (the recoding window slides here).
//   * qm1   : the Booth "extra" bit to the right of Q[0].
//   Each iteration ADDs the recoded multiple into A, then ARITHMETIC-shifts the
//   combined {A, Q, qm1} right by 2 (sign-preserving). After WIDTH/2 iterations
//   the 2*WIDTH-bit product sits in the low bits of {A, Q}.
//
// Control: a 3-state handshake FSM (IDLE -> RUN -> DONE). Assert `start` for one
// cycle with operands stable; `busy` is high while iterating; `done` pulses for
// one cycle when `product` is valid. Fully synchronous, active-low reset.
//
// Parameterized, reset-safe, and lint-clean. WIDTH must be even.
// ============================================================================
`default_nettype none

module booth_mul #(
    parameter int WIDTH = 8                       // operand width; MUST be even
) (
    input  wire                      clk,
    input  wire                      rst_n,        // synchronous active-low reset
    input  wire                      start,        // 1-cycle load/launch pulse
    input  wire signed [WIDTH-1:0]   multiplicand, // "M"
    input  wire signed [WIDTH-1:0]   multiplier,   // "Q"
    output logic signed [2*WIDTH-1:0] product,     // signed 2*WIDTH result
    output logic                     busy,         // high while iterating
    output logic                     done          // 1-cycle pulse: product valid
);

    // ---- derived sizes ------------------------------------------------------
    localparam int IT = WIDTH / 2;                 // radix-4 iterations
    localparam int AW = WIDTH + 2;                 // accumulator width (holds +/-2M)
    localparam int CW = AW + WIDTH + 1;            // combined {A, Q, qm1} width
    localparam int CNTW = $clog2(IT + 1);          // iteration counter width

    // synthesis-time sanity: radix-4 needs an even operand width.
    initial begin
        if (WIDTH % 2 != 0)
            $fatal(1, "booth_mul: WIDTH (%0d) must be even", WIDTH);
    end

    // ---- state --------------------------------------------------------------
    typedef enum logic [1:0] {S_IDLE, S_RUN, S_DONE} state_e;
    state_e state, state_n;

    logic signed [AW-1:0]    A;                    // accumulator (high part)
    logic        [WIDTH-1:0] Q;                    // multiplier  (low part)
    logic                    qm1;                  // Booth extra bit
    logic signed [AW-1:0]    M;                    // sign-extended multiplicand
    logic signed [AW-1:0]    M2;                   // 2*M
    logic        [CNTW-1:0]  cnt;                  // iterations remaining

    // ---- combinational Booth step -------------------------------------------
    // Recode {Q[1], Q[0], qm1} into the signed action on the accumulator, then
    // arithmetic-shift the whole {A, Q, qm1} vector right by two.
    logic signed [AW-1:0]  A_add;                  // A after the recoded add
    logic signed [CW-1:0]  comb, comb_sh;
    logic [AW+WIDTH-1:0]   full;                   // {A, Q} for the final slice

    assign full = {A, Q};                          // low 2*WIDTH bits = product

    always_comb begin
        unique case ({Q[1], Q[0], qm1})
            3'b001, 3'b010: A_add = A + M;         //  +1*M
            3'b011:         A_add = A + M2;        //  +2*M
            3'b100:         A_add = A - M2;        //  -2*M
            3'b101, 3'b110: A_add = A - M;         //  -1*M
            default:        A_add = A;             //  000 / 111 -> +0
        endcase
        comb    = {A_add, Q, qm1};                 // repack
        comb_sh = comb >>> 2;                      // arithmetic shift right by 2
    end

    // ---- next-state (control) -----------------------------------------------
    always_comb begin
        state_n = state;
        unique case (state)
            S_IDLE: if (start)            state_n = S_RUN;
            S_RUN:  if (cnt == CNTW'(1))  state_n = S_DONE; // this cycle is the last step
            S_DONE:                       state_n = S_IDLE;
            default:                      state_n = S_IDLE;
        endcase
    end

    // ---- sequential datapath ------------------------------------------------
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state   <= S_IDLE;
            A       <= '0;
            Q       <= '0;
            qm1     <= 1'b0;
            M       <= '0;
            M2      <= '0;
            cnt     <= '0;
            product <= '0;
            busy    <= 1'b0;
            done    <= 1'b0;
        end else begin
            state <= state_n;
            done  <= 1'b0;                          // default: pulse low

            unique case (state)
                S_IDLE: begin
                    busy <= 1'b0;
                    if (start) begin
                        // Load operands. Sign-extend M into the accumulator width.
                        M    <= AW'(multiplicand);
                        M2   <= AW'(multiplicand) <<< 1;
                        A    <= '0;
                        Q    <= multiplier;
                        qm1  <= 1'b0;
                        cnt  <= CNTW'(IT);
                        busy <= 1'b1;
                    end
                end

                S_RUN: begin
                    // One radix-4 add/shift step: commit the shifted vector.
                    // We enter RUN with cnt = IT and leave when cnt == 1, so a
                    // step is committed on every RUN cycle (exactly IT of them).
                    A   <= comb_sh[CW-1 -: AW];     // top AW bits  -> A
                    Q   <= comb_sh[WIDTH -: WIDTH]; // next WIDTH   -> Q  (bits [WIDTH:1])
                    qm1 <= comb_sh[0];              // low bit      -> qm1
                    cnt <= cnt - 1'b1;
                end

                S_DONE: begin
                    // Product is the low 2*WIDTH bits of {A, Q}.
                    product <= full[2*WIDTH-1:0];
                    busy    <= 1'b0;
                    done    <= 1'b1;                 // one-cycle valid pulse
                end

                default: ;
            endcase
        end
    end

endmodule

`default_nettype wire
