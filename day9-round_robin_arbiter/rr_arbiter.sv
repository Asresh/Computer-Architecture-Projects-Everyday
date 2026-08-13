// rr_arbiter.sv - Day9
// Parameterized N-requester round-robin (rotating-priority) arbiter.
`timescale 1ns/1ps
//
// Classic on-chip arbitration block: many masters (cores, DMA engines, cache
// ports) contend for one shared resource (a bus, a memory port, an issue
// slot). A *fixed*-priority arbiter would let a high-priority requester starve
// the others; a round-robin arbiter guarantees fairness -- after a requester is
// served it drops to LOWEST priority, so under sustained contention every
// requester is granted in turn.
//
// Behaviour (single-cycle, no hold/lock):
//   * Each cycle, look at `req` and grant EXACTLY ONE requester (one-hot).
//   * Priority rotates: the search starts at pointer `base` and wraps around,
//     picking the first asserted request at or after `base`.
//   * On a grant, `base` advances to (granted_index + 1) mod N, so the just
//     served requester becomes lowest priority next cycle.
//   * If no request is asserted, `grant`=0, `grant_valid`=0, `base` holds.
//
// The design is fully synthesizable, reset-safe, and lint-friendly: the only
// sequential state is the rotate pointer; grant selection is combinational.

module rr_arbiter #(
    parameter int N    = 4,                        // number of requesters (>=1)
    parameter int IDXW = (N > 1) ? $clog2(N) : 1   // derived pointer width
) (
    input  logic            clk,
    input  logic            rst_n,        // active-low async reset
    input  logic [N-1:0]    req,          // request lines, one per requester
    output logic [N-1:0]    grant,        // one-hot grant (0 when idle)
    output logic            grant_valid,  // high when a requester is granted
    output logic [IDXW-1:0] grant_idx     // index of the granted requester
);

    // Rotate pointer: index of the CURRENT highest-priority requester.
    logic [IDXW-1:0] base;

    // One-hot -> binary index encoder (only the single set bit contributes).
    function automatic logic [IDXW-1:0] onehot2idx(input logic [N-1:0] oh1);
        onehot2idx = '0;
        for (int i = 0; i < N; i++)
            if (oh1[i]) onehot2idx = onehot2idx | i[IDXW-1:0];
    endfunction

    // ---- Combinational rotating-priority selection --------------------------
    // Rotating priority = "the lowest-numbered requesting lane at or above the
    // pointer, wrapping past the top". We compute it with fixed-width mask/shift
    // ops only (no variable bit-selects), so it stays lint-clean and maps to a
    // priority encoder plus a bit of masking in synthesis:
    //   hi   = requests on lanes >= base   (mask off lanes below the pointer)
    //   cand = hi if any, else the full req vector (this performs the wrap)
    //   oh   = cand & (-cand)              (isolate the lowest set bit -> one-hot)
    logic [N-1:0]    lo_mask;   // 1s on lanes strictly below `base`
    logic [N-1:0]    hi;        // requesting lanes at or above `base`
    logic [N-1:0]    cand;      // request set to search (with wrap)
    logic [N-1:0]    oh;        // one-hot grant
    logic            won;
    logic [IDXW-1:0] sel_idx;

    always_comb begin
        lo_mask = (N'(1) << base) - N'(1);   // bits 0..base-1 set
        hi      = req & ~lo_mask;             // requests at/above the pointer
        cand    = (hi != '0) ? hi : req;      // wrap to full req if none above
        oh      = cand & (~cand + N'(1));     // isolate lowest set bit
        won     = (req != '0);
    end

    assign sel_idx     = onehot2idx(oh);
    assign grant       = oh;
    assign grant_valid = won;
    assign grant_idx   = sel_idx;

    // ---- Sequential rotate-pointer update -----------------------------------
    // Advance past the just-served requester so it becomes lowest priority.
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            base <= '0;
        end else if (won) begin
            if (sel_idx == IDXW'(N - 1)) base <= '0;
            else                         base <= sel_idx + 1'b1;
        end
        // else: no grant this cycle -> hold pointer.
    end

endmodule
