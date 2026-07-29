// tlb.sv - Day10
// Fully-associative Translation Lookaside Buffer (TLB) with true-LRU refill.
`timescale 1ns/1ps
//
// Virtual memory gives every process the illusion of its own flat address
// space; the hardware translates each virtual page number (VPN) to a physical
// page number (PPN) using page tables that live in DRAM. Walking those tables
// on every access would be ruinously slow, so a small, fast cache of recent
// translations sits in the front of the pipeline: the TLB.
//
// This is a parameterized, FULLY-ASSOCIATIVE TLB (a small CAM): every entry is
// compared against the requested VPN in parallel, so any VPN may live in any
// slot. On a miss the page-table walker supplies the mapping, which is filled
// into a free slot -- or, when the TLB is full, on top of the TRUE LEAST-
// RECENTLY-USED entry chosen by an NxN reference ("age") matrix.
//
// Only the VPN is translated; the low OFFSET bits of the address pass straight
// through untouched, so the full physical address is {PPN, page_offset}. That
// passthrough is trivial wiring and lives outside this core (see the README);
// this module is the translation CAM + replacement engine.
//
// Behaviour (combinational lookup, synchronous state updates):
//   * Lookup   : `hit`/`miss`, `resp_ppn`, and `hit_way` are combinational
//                functions of `req_vpn` and the current entries.
//   * Fill     : on `fill_valid`, install {fill_vpn -> fill_ppn}. Target way is
//                (a) an existing entry holding the same VPN (overwrite, keeps
//                mappings unique), else (b) the lowest-numbered invalid way,
//                else (c) the true-LRU way. The chosen way is exposed as
//                `fill_way` every cycle for observability.
//   * Invalidate: on `inv_valid`, clear the entry matching `inv_vpn` (sfence of
//                a single page).
//   * Flush     : on `flush_all`, invalidate every entry (full sfence.vma).
//   * LRU touch : a fill, or a read that hits, makes that way MOST-recently
//                used. A fill takes precedence over a concurrent read hit.
//
// Replacement uses the classic reference-matrix true-LRU: use_mtx[i][j]=1 means
// "way i was used more recently than way j". Touching way k sets row k to all
// ones and column k to all zeros; the LRU victim is the way whose row (ignoring
// its diagonal bit) is all zeros. Fully synthesizable, reset-safe, lint-clean.

module tlb #(
    parameter int VPN_W   = 20,                         // virtual page number width
    parameter int PPN_W   = 22,                         // physical page number width
    parameter int ENTRIES = 4,                          // TLB entries (>=1)
    parameter int IDXW    = (ENTRIES > 1) ? $clog2(ENTRIES) : 1 // way-index width
) (
    input  logic             clk,
    input  logic             rst_n,        // active-low async reset

    // Lookup port (combinational)
    input  logic             req_valid,    // a translation is being requested
    input  logic [VPN_W-1:0] req_vpn,      // virtual page number to translate
    output logic             hit,          // req_valid & VPN present
    output logic             miss,         // req_valid & VPN absent
    output logic [PPN_W-1:0] resp_ppn,     // translated PPN (valid on hit)
    output logic [IDXW-1:0]  hit_way,      // matching way (valid on hit)

    // Refill port (from the page-table walker)
    input  logic             fill_valid,   // install a mapping this cycle
    input  logic [VPN_W-1:0] fill_vpn,
    input  logic [PPN_W-1:0] fill_ppn,
    output logic [IDXW-1:0]  fill_way,     // way a fill would use (victim select)

    // Invalidation
    input  logic             inv_valid,    // invalidate the entry for inv_vpn
    input  logic [VPN_W-1:0] inv_vpn,
    input  logic             flush_all     // invalidate every entry
);

    // ---- Architectural state ------------------------------------------------
    logic             valid   [ENTRIES];              // entry occupied
    logic [VPN_W-1:0] tag     [ENTRIES];              // stored VPN
    logic [PPN_W-1:0] data    [ENTRIES];              // stored PPN
    logic [ENTRIES-1:0] use_mtx [ENTRIES];            // reference (age) matrix

    // ---- Combinational lookup / selection -----------------------------------
    logic             hit_r;
    logic [IDXW-1:0]  hit_way_r;
    logic [PPN_W-1:0] ppn_r;

    logic             dup;        // fill_vpn already resident -> overwrite it
    logic [IDXW-1:0]  dup_way;
    logic             have_inv;   // at least one invalid (free) way
    logic [IDXW-1:0]  inv_way;    // lowest-numbered invalid way
    logic             have_lru;   // a true-LRU victim was found
    logic [IDXW-1:0]  lru_way;    // true-LRU way (row all zeros off-diagonal)
    logic [IDXW-1:0]  target;     // way a fill installs into

    logic             touch_en;   // update LRU this cycle
    logic [IDXW-1:0]  touch_way;  // way to promote to most-recently-used

    logic [ENTRIES-1:0] row_nod;  // a use-matrix row with its diagonal cleared

    always_comb begin
        // --- associative VPN lookup (first match wins; VPNs are unique) ---
        hit_r     = 1'b0;
        hit_way_r = '0;
        ppn_r     = '0;
        for (int i = 0; i < ENTRIES; i++) begin
            if (valid[i] && (tag[i] == req_vpn) && !hit_r) begin
                hit_r     = 1'b1;
                hit_way_r = IDXW'(i);
                ppn_r     = data[i];
            end
        end

        // --- fill-target selection: overwrite > free slot > LRU victim ---
        dup      = 1'b0;  dup_way = '0;
        for (int i = 0; i < ENTRIES; i++) begin
            if (valid[i] && (tag[i] == fill_vpn) && !dup) begin
                dup     = 1'b1;
                dup_way = IDXW'(i);
            end
        end

        have_inv = 1'b0;  inv_way = '0;
        for (int i = 0; i < ENTRIES; i++) begin
            if (!valid[i] && !have_inv) begin
                have_inv = 1'b1;
                inv_way  = IDXW'(i);
            end
        end

        have_lru = 1'b0;  lru_way = '0;
        for (int i = 0; i < ENTRIES; i++) begin
            row_nod    = use_mtx[i];
            row_nod[i] = 1'b0;                 // ignore the self/diagonal bit
            if ((row_nod == '0) && !have_lru) begin
                have_lru = 1'b1;
                lru_way  = IDXW'(i);
            end
        end

        target = dup ? dup_way : (have_inv ? inv_way : lru_way);

        // --- LRU promotion: a fill wins over a concurrent read hit ---
        touch_en  = fill_valid | (req_valid & hit_r);
        touch_way = fill_valid ? target : hit_way_r;
    end

    // ---- Combinational outputs ----------------------------------------------
    assign hit      = req_valid & hit_r;
    assign miss     = req_valid & ~hit_r;
    assign resp_ppn = (req_valid & hit_r) ? ppn_r : '0;
    assign hit_way  = hit_way_r;
    assign fill_way = target;

    // ---- Sequential state update --------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int i = 0; i < ENTRIES; i++) begin
                valid[i]   <= 1'b0;
                use_mtx[i] <= '0;
            end
        end else if (flush_all) begin
            // Full flush wins over everything else this cycle.
            for (int i = 0; i < ENTRIES; i++) begin
                valid[i]   <= 1'b0;
                use_mtx[i] <= '0;
            end
        end else begin
            // 1) single-page invalidate
            if (inv_valid) begin
                for (int i = 0; i < ENTRIES; i++)
                    if (valid[i] && (tag[i] == inv_vpn))
                        valid[i] <= 1'b0;
            end
            // 2) refill (install / overwrite) into the selected target way
            if (fill_valid) begin
                valid[target] <= 1'b1;
                tag  [target] <= fill_vpn;
                data [target] <= fill_ppn;
            end
            // 3) reference-matrix LRU promotion of the touched way
            if (touch_en) begin
                for (int i = 0; i < ENTRIES; i++) begin
                    for (int j = 0; j < ENTRIES; j++) begin
                        if (i == int'(touch_way))
                            use_mtx[i][j] <= 1'b1;        // row = newer than all
                        else if (j == int'(touch_way))
                            use_mtx[i][j] <= 1'b0;        // column = others older
                        // otherwise: hold (registered)
                    end
                end
            end
        end
    end

endmodule
