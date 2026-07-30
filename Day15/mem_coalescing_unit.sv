// ============================================================================
// mem_coalescing_unit.sv - GPU global-memory coalescing unit
// ----------------------------------------------------------------------------
// When a GPU warp executes a load/store, every active lane presents its own
// byte address. Firing one DRAM/L2 transaction per lane would waste enormous
// bandwidth, so the memory pipeline first *coalesces* the per-lane addresses:
// it groups all lanes that fall in the same aligned cache-line "segment" and
// emits ONE transaction per unique segment. Fewer transactions per warp is the
// single biggest lever on GPU memory throughput, which is why coalesced access
// patterns are drilled so hard in CUDA performance work.
//
// This unit takes a warp request (an active-lane mask + one byte address per
// lane) and produces, in a single registered cycle:
//   * a leader mask   - exactly one lane per unique segment is the "leader"
//   * n_txn           - number of memory transactions the warp will generate
//   * per-leader base  - the aligned segment base address of each transaction
//   * per-leader mask  - which lanes each transaction serves (its coalesced set)
//
// The leader for a segment is the lowest-indexed active lane in that segment,
// so the result is deterministic and order-independent. All grouping logic is
// combinational; a valid->done handshake registers the result so the datapath
// sees a clean one-cycle latency.
//
// Fully parameterized, reset-safe, and lint-friendly. Per-lane buses use
// unpacked outer dimensions so element+field access is a plain index (no
// variable part-select on a packed multi-dim vector).
// ============================================================================
`timescale 1ns/1ps
module mem_coalescing_unit #(
    parameter int NLANES     = 8,   // lanes per warp (coalesce group)
    parameter int ADDR_WIDTH = 32,  // byte-address width
    parameter int LINE_BYTES = 32   // coalescing segment size in bytes (pow2)
) (
    input  logic                    clk,
    input  logic                    rst_n,

    // ---- request (one warp memory instruction) ----
    input  logic                    req_valid,
    input  logic [NLANES-1:0]       active_mask,          // 1 = lane participates
    input  logic [ADDR_WIDTH-1:0]   lane_addr [NLANES],   // per-lane byte address

    // ---- response (registered, one cycle after req_valid) ----
    output logic                    resp_valid,
    output logic [NLANES-1:0]       leader_mask,          // 1 = lane leads a txn
    output logic [$clog2(NLANES+1)-1:0] n_txn,            // # coalesced txns
    output logic [$clog2(NLANES+1)-1:0] n_active,         // # participating lanes
    // per-leader outputs are indexed by the leader's lane number:
    output logic [ADDR_WIDTH-1:0]   txn_base  [NLANES],   // aligned segment base
    output logic [NLANES-1:0]       txn_lanes [NLANES]    // lanes served by txn i
);

    // ---- derived widths ----
    localparam int OFFB = $clog2(LINE_BYTES);       // in-line offset bits
    localparam int SEGW = ADDR_WIDTH - OFFB;        // segment-id width
    localparam int CNTW = $clog2(NLANES+1);         // count width

    // ------------------------------------------------------------------
    // 1) Per-lane segment id  (addr / LINE_BYTES), only meaningful if active
    // ------------------------------------------------------------------
    logic [SEGW-1:0] seg [NLANES];
    always_comb begin
        for (int i = 0; i < NLANES; i++) begin
            seg[i] = lane_addr[i][ADDR_WIDTH-1:OFFB];
        end
    end

    // ------------------------------------------------------------------
    // 2) Leader detection + coalesced membership (all combinational).
    //    lane i is a leader iff it is active and no active lower-indexed
    //    lane shares its segment.  members[i] = every active lane in i's
    //    segment (valid only when i is a leader, but computed for all).
    // ------------------------------------------------------------------
    logic [NLANES-1:0] c_leader;
    logic [NLANES-1:0] c_members [NLANES];

    always_comb begin
        c_leader = '0;
        for (int i = 0; i < NLANES; i++) c_members[i] = '0;

        for (int i = 0; i < NLANES; i++) begin
            if (active_mask[i]) begin
                logic is_leader;
                is_leader = 1'b1;
                for (int j = 0; j < NLANES; j++) begin
                    if (active_mask[j] && (seg[j] == seg[i])) begin
                        // gather this segment's membership
                        c_members[i][j] = 1'b1;
                        // a lower-indexed active lane in the same segment
                        // means i is NOT the leader
                        if (j < i) is_leader = 1'b0;
                    end
                end
                c_leader[i] = is_leader;
            end
        end
    end

    // ------------------------------------------------------------------
    // 3) Population counts (active lanes and transactions).
    // ------------------------------------------------------------------
    logic [CNTW-1:0] c_nactive, c_ntxn;
    always_comb begin
        c_nactive = '0;
        c_ntxn    = '0;
        for (int i = 0; i < NLANES; i++) begin
            if (active_mask[i]) c_nactive = c_nactive + 1'b1;
            if (c_leader[i])    c_ntxn    = c_ntxn    + 1'b1;
        end
    end

    // ------------------------------------------------------------------
    // 4) Register the result behind the valid->done handshake.
    // ------------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            resp_valid  <= 1'b0;
            leader_mask <= '0;
            n_txn       <= '0;
            n_active    <= '0;
            for (int i = 0; i < NLANES; i++) begin
                txn_base[i]  <= '0;
                txn_lanes[i] <= '0;
            end
        end else begin
            resp_valid <= req_valid;
            if (req_valid) begin
                leader_mask <= c_leader;
                n_txn       <= c_ntxn;
                n_active    <= c_nactive;
                for (int i = 0; i < NLANES; i++) begin
                    txn_lanes[i] <= c_members[i];
                    // aligned segment base = seg << OFFB (low offset bits zeroed)
                    txn_base[i]  <= c_leader[i] ? {seg[i], {OFFB{1'b0}}} : '0;
                end
            end else begin
                // hold response low on idle cycles
                leader_mask <= '0;
                n_txn       <= '0;
                n_active    <= '0;
                for (int i = 0; i < NLANES; i++) begin
                    txn_base[i]  <= '0;
                    txn_lanes[i] <= '0;
                end
            end
        end
    end

endmodule
