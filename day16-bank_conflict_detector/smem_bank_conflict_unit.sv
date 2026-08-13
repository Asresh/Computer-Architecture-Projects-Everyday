// smem_bank_conflict_unit.sv
// -----------------------------------------------------------------------------
// Day16 - GPU Shared-Memory Bank-Conflict Detector & Access Serializer
// -----------------------------------------------------------------------------
// A warp issues one shared-memory (CUDA __shared__ / OpenCL local) access per
// cycle: every active lane presents a byte address. Shared memory is physically
// built from NBANKS equally-wide banks; a word maps to bank = (addr/BYTES) mod
// NBANKS. A bank can serve exactly ONE distinct word per cycle. Therefore:
//
//   * lanes that hit DIFFERENT banks are all served in the same cycle (parallel)
//   * lanes that hit the SAME bank but the SAME word are served together by a
//     single broadcast/multicast (no penalty)  -- the CUDA "broadcast" case
//   * lanes that hit the SAME bank but DIFFERENT words must be serialized: the
//     access replays over multiple phases, one distinct word per phase per bank
//
// The number of phases (serialization factor) the whole warp access takes is
//     n_phases = max over banks of (# of distinct words requested in that bank)
// n_phases == 1  => conflict-free (best case). n_phases == NLANES => worst case
// (an N-way bank conflict: every active lane wants a different word in one bank).
//
// This unit is purely combinational in its logic (registered I/O for a clean
// single-cycle handshake, matching the rest of the series). For each lane it
// reports the phase in which that lane is serviced, whether it is the "word
// leader" (first requester of its distinct word -> owns a bank slot) or a
// broadcast follower, and warp-level popcounts (active / unique-words / phases).
//
// Design style: reset-safe, fully parameterized, no variable bit-selects, all
// cross-lane comparisons are elaboration-unrolled O(NLANES^2) loops.
// -----------------------------------------------------------------------------

module smem_bank_conflict_unit #(
    parameter int NLANES = 8,    // lanes in the (sub)warp presenting addresses
    parameter int NBANKS = 8,    // physical shared-memory banks
    parameter int ADDR_W = 32,   // byte-address width
    parameter int BYTES  = 4,    // bytes per bank word (= word granularity)
    // ---- derived widths (do NOT override) ----
    parameter int BANK_W = (NBANKS > 1) ? $clog2(NBANKS) : 1,
    parameter int PH_W   = $clog2(NLANES + 1),   // holds 0..NLANES
    parameter int CNT_W  = $clog2(NLANES + 1)
)(
    input  logic                       clk,
    input  logic                       rst_n,

    // ---- request (one warp shared-memory access) ----
    input  logic                       req_valid,
    input  logic [NLANES-1:0]          lane_active,          // per-lane enable
    input  logic [ADDR_W-1:0]          lane_addr [NLANES],   // per-lane byte addr

    // ---- registered response (available the next cycle) ----
    output logic                       resp_valid,
    output logic [PH_W-1:0]            n_phases,   // serialization factor (0..NLANES)
    output logic                       conflict,   // n_phases > 1
    output logic [CNT_W-1:0]           n_active,   // popcount(lane_active)
    output logic [CNT_W-1:0]           n_unique,   // # distinct words requested
    output logic [CNT_W-1:0]           n_bcast,    // active lanes served by broadcast
    output logic [PH_W-1:0]            lane_phase [NLANES], // 1..n_phases, 0 if idle
    output logic [BANK_W-1:0]          lane_bank  [NLANES], // bank each lane maps to
    output logic [NLANES-1:0]          lane_leader          // 1 = word leader (owns slot)
);

    // ---- derived widths --------------------------------------------------
    localparam int OFFB = (BYTES > 1) ? $clog2(BYTES) : 0; // byte-in-word bits

    // ---- combinational results ------------------------------------------
    logic [BANK_W-1:0] c_bank   [NLANES];
    logic              c_leader [NLANES];
    logic [PH_W-1:0]   c_phase  [NLANES];
    logic [CNT_W-1:0]  c_active, c_unique;
    logic [PH_W-1:0]   c_nphase;

    // per-lane word index (addr / BYTES), used for equality tests
    logic [ADDR_W-1:0] word [NLANES];
    int                L;   // leader index scratch (combinational)

    always_comb begin
        // 1) map each lane to its word and bank ---------------------------
        for (int i = 0; i < NLANES; i++) begin
            word[i]   = lane_addr[i] >> OFFB;         // word index = addr / BYTES
            c_bank[i] = (word[i] % NBANKS);           // bank = word mod NBANKS
        end

        // 2) word-leader detection: lane i leads iff it is the first ACTIVE
        //    lane (lowest index) presenting its word. Same word => same bank,
        //    so leaders are exactly the distinct (bank,word) slot owners.
        for (int i = 0; i < NLANES; i++) begin
            c_leader[i] = lane_active[i];
            for (int j = 0; j < NLANES; j++) begin
                if (j < i && lane_active[j] && (word[j] == word[i]))
                    c_leader[i] = 1'b0;
            end
        end

        // 3) per-lane serialization phase.
        //    For an active lane, let L be the index of its word leader (the
        //    lowest-index active lane sharing its word; L==i if i leads).
        //    phase(i) = # of word leaders j (j <= L) mapping to the same bank.
        //    Followers of the same word inherit the leader's phase because they
        //    scan the identical leader set up to the identical L.
        for (int i = 0; i < NLANES; i++) begin
            c_phase[i] = '0;
            if (lane_active[i]) begin
                // find L = leader index for lane i's word (lowest active match)
                L = i;
                for (int j = 0; j < NLANES; j++) begin
                    if (j < i && lane_active[j] && (word[j] == word[i]) && (L == i))
                        L = j; // first (lowest) match becomes the leader
                end
                // count same-bank leaders up to and including L
                for (int j = 0; j < NLANES; j++) begin
                    if (j <= L && c_leader[j] && (c_bank[j] == c_bank[i]))
                        c_phase[i] = c_phase[i] + 1'b1;
                end
            end
        end

        // 4) warp-level popcounts and serialization factor ----------------
        c_active = '0;
        c_unique = '0;
        c_nphase = '0;
        for (int i = 0; i < NLANES; i++) begin
            if (lane_active[i]) c_active = c_active + 1'b1;
            if (c_leader[i])    c_unique = c_unique + 1'b1;
            if (c_phase[i] > c_nphase) c_nphase = c_phase[i];
        end
    end

    // ---- registered handshake -------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            resp_valid  <= 1'b0;
            n_phases    <= '0;
            conflict    <= 1'b0;
            n_active    <= '0;
            n_unique    <= '0;
            n_bcast     <= '0;
            lane_leader <= '0;
            for (int i = 0; i < NLANES; i++) begin
                lane_phase[i] <= '0;
                lane_bank[i]  <= '0;
            end
        end else begin
            resp_valid <= req_valid;
            if (req_valid) begin
                n_phases <= c_nphase;
                conflict <= (c_nphase > 1);
                n_active <= c_active;
                n_unique <= c_unique;
                n_bcast  <= c_active - c_unique; // followers = broadcast-served lanes
                for (int i = 0; i < NLANES; i++) begin
                    lane_phase[i]  <= c_phase[i];
                    lane_bank[i]   <= c_bank[i];
                    lane_leader[i] <= c_leader[i];
                end
            end else begin
                n_phases <= '0;
                conflict <= 1'b0;
                n_active <= '0;
                n_unique <= '0;
                n_bcast  <= '0;
                lane_leader <= '0;
                for (int i = 0; i < NLANES; i++) begin
                    lane_phase[i] <= '0;
                    lane_bank[i]  <= '0;
                end
            end
        end
    end

endmodule
