// -----------------------------------------------------------------------------
// Day28 - Explicit Register Renaming Unit (Register Alias Table + Free List)
// -----------------------------------------------------------------------------
// The front-end of every out-of-order superscalar core. It removes the false
// (WAR / WAW) dependences that the architected register names create by mapping
// each architectural register (rd / rs1 / rs2) onto a fresh physical register
// drawn from a pool. After renaming, the only dependences left are the true
// (RAW) ones, and the scheduler (reservation stations / issue queue) is free to
// execute instructions out of program order.
//
// Two structures do the work:
//
//   * Register Alias Table (RAT) - NARCH entries, RAT[a] = the physical
//     register that currently holds architectural register `a`. Reset to the
//     identity map (RAT[a] = a) so the NARCH low physical registers hold the
//     initial architectural state.
//
//   * Free List - a FIFO of physical registers not currently part of any
//     architectural mapping. Reset to hold the upper (NPHYS-NARCH) physicals.
//
// Per rename request (one instruction / cycle):
//   psrc1 = RAT[rs1], psrc2 = RAT[rs2]                (read old mappings)
//   if the instruction writes a real rd (has_rd, rd != 0):
//        pop pdst from the free list
//        pold  = RAT[rd]        (the *previous* mapping - freed at commit)
//        RAT[rd] <= pdst        (install the new mapping)
//
// The old physical `pold` cannot be recycled immediately: older in-flight
// instructions may still read it. It is returned to the free list later through
// the independent commit/free port (free_valid / free_preg), exactly as a real
// core frees a physical register when the redefining instruction commits.
//
// Backpressure: if a request needs an allocation but the free list is empty,
// `stall` asserts and NO state changes - the front-end must retry next cycle.
//
// x0 handling (documented simplification): architectural register 0 is
// hardwired to zero, is never renamed, and RAT[0] stays == physical 0 for the
// life of the machine. Reads of x0 return physical 0; writes to x0 allocate
// nothing.
//
// Style: parameterised, reset-safe, lint-clean, no data-dependent variable
// bit-selects on buses (only array indexing by a full register name).
// -----------------------------------------------------------------------------

`timescale 1ns / 1ps

module register_rename #(
    parameter int NARCH = 32,                 // architectural registers (x0..x31)
    parameter int NPHYS = 64,                 // physical registers
    parameter int ALOG  = $clog2(NARCH),      // arch-register index width
    parameter int PLOG  = $clog2(NPHYS)       // phys-register index width
) (
    input  logic             clk,
    input  logic             rst_n,

    // ---- Rename (dispatch) port : one instruction per cycle ----
    input  logic             rename_valid,    // a request is present
    input  logic [ALOG-1:0]  rs1,             // source 1 architectural reg
    input  logic [ALOG-1:0]  rs2,             // source 2 architectural reg
    input  logic [ALOG-1:0]  rd,              // destination architectural reg
    input  logic             has_rd,          // instruction writes rd

    output logic [PLOG-1:0]  psrc1,           // physical mapping of rs1
    output logic [PLOG-1:0]  psrc2,           // physical mapping of rs2
    output logic [PLOG-1:0]  pdst,            // freshly allocated physical rd
    output logic [PLOG-1:0]  pold,            // previous mapping of rd (free later)
    output logic             alloc,           // a physical reg was allocated
    output logic             stall,           // needed an alloc but pool empty

    // ---- Commit / free port : return a physical register to the pool ----
    input  logic             free_valid,      // return free_preg to the pool
    input  logic [PLOG-1:0]  free_preg,       // physical register to recycle

    // ---- Debug / observability ----
    output logic [PLOG:0]    dbg_free_count   // number of free physical regs
);

    // Number of physicals that are free at reset (the pool never exceeds this).
    localparam int FREE_INIT = NPHYS - NARCH;

    // -------------------------------------------------------------------------
    // Register Alias Table
    // -------------------------------------------------------------------------
    logic [PLOG-1:0] rat [NARCH];

    // -------------------------------------------------------------------------
    // Free list - circular FIFO of physical register names.
    // Depth NPHYS so it can never overflow (count is bounded by FREE_INIT).
    // -------------------------------------------------------------------------
    logic [PLOG-1:0] freelist [NPHYS];
    logic [PLOG-1:0] fl_head;                 // pop side
    logic [PLOG-1:0] fl_tail;                 // push side
    logic [PLOG:0]   fl_count;                // 0 .. FREE_INIT

    wire fl_empty = (fl_count == '0);

    // Explicit modulo-NPHYS wrap so the ring buffer is correct for ANY NPHYS,
    // not only powers of two (a natural pointer roll-over would wrap at 2**PLOG).
    localparam logic [PLOG-1:0] FL_LAST = NPHYS - 1;
    wire [PLOG-1:0] fl_head_nxt = (fl_head == FL_LAST) ? '0 : fl_head + 1'b1;
    wire [PLOG-1:0] fl_tail_nxt = (fl_tail == FL_LAST) ? '0 : fl_tail + 1'b1;

    // -------------------------------------------------------------------------
    // Combinational rename outputs
    // -------------------------------------------------------------------------
    // An allocation is *needed* when a valid request writes a non-x0 rd.
    wire need_alloc = rename_valid & has_rd & (rd != '0);

    assign alloc = need_alloc & ~fl_empty;
    assign stall = need_alloc &  fl_empty;

    always_comb begin
        psrc1 = rat[rs1];
        psrc2 = rat[rs2];
        pold  = rat[rd];                      // current (about-to-be-old) mapping
        pdst  = freelist[fl_head];            // head of the free list (if alloc)
    end

    assign dbg_free_count = fl_count;

    // -------------------------------------------------------------------------
    // Sequential state update
    // -------------------------------------------------------------------------
    integer i;
    // Net change to the free count this cycle from the (independent) pop & push.
    wire do_pop  = alloc;                      // consume pdst
    wire do_push = free_valid;                 // recycle free_preg

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            // RAT = identity map: architectural reg a lives in physical a.
            for (i = 0; i < NARCH; i = i + 1)
                rat[i] <= i[PLOG-1:0];
            // Free list = the upper physicals NARCH .. NPHYS-1.
            for (i = 0; i < NPHYS; i = i + 1)
                freelist[i] <= (i < FREE_INIT) ? (NARCH + i) : '0;
            fl_head  <= '0;
            fl_tail  <= FREE_INIT[PLOG-1:0];   // wraps mod NPHYS
            fl_count <= FREE_INIT[PLOG:0];
        end else begin
            // ---- pop (allocate pdst) ----
            if (do_pop)
                fl_head <= fl_head_nxt;

            // ---- install new RAT mapping (x0 is never written) ----
            if (alloc)
                rat[rd] <= pdst;

            // ---- push (recycle a committed physical) ----
            if (do_push) begin
                freelist[fl_tail] <= free_preg;
                fl_tail <= fl_tail_nxt;
            end

            // ---- free count : +1 push, -1 pop ----
            case ({do_push, do_pop})
                2'b10:   fl_count <= fl_count + 1'b1;
                2'b01:   fl_count <= fl_count - 1'b1;
                default: fl_count <= fl_count;   // 00 or 11 -> unchanged
            endcase
        end
    end

`ifdef FORMAL_OR_DEBUG
    // x0 must never move.
    always_ff @(posedge clk) if (rst_n) assert (rat[0] == '0);
`endif

endmodule
