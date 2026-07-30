`timescale 1ns/1ps
// ============================================================================
// Day11 : Store Buffer with Store-to-Load Forwarding
// ----------------------------------------------------------------------------
// A parameterized, synthesizable store buffer -- the small in-order FIFO that
// sits between a CPU's store port and the memory/cache. It lets store
// instructions "retire" (leave the pipeline) before their data has actually
// reached memory, decoupling store latency from the pipeline, while still
// giving younger loads the correct, most-recent value via *store-to-load
// forwarding*.
//
// Three concurrent interfaces:
//   1. Store enqueue (push)   : CPU pushes {addr,data} when st_valid & st_ready.
//   2. Load lookup   (query)  : combinational, same-cycle. For ld_addr, report
//                               whether a pending store forwards, and its data.
//   3. Memory drain  (pop)    : oldest entry is written to memory in order when
//                               mem_req & mem_ready; then it leaves the buffer.
//
// Forwarding semantics (the whole point): a load must observe the value of the
// *youngest* (most recently enqueued) pending store to the same address -- a
// later store to an address supersedes an earlier one. If no pending store
// matches, ld_fwd_hit = 0 and the load must go to memory/cache instead.
//
// Ordering model: stores drain to memory strictly in program (enqueue) order,
// so this is a plain circular FIFO. Address match is full-word granularity
// (exact ADDR_W-bit compare); byte-granular partial forwarding is deliberately
// out of scope for a daily building block.
//
// Design style: reset-safe, lint-friendly. The only array indexed by a runtime
// value is the head-pointer read for the drain port (a standard read mux). The
// forwarding search is a fixed-bound unrolled loop over the physical slots with
// a relative-age comparison -- no variable bit-selects of a packed vector.
// ============================================================================

module store_buffer #(
    parameter int ADDR_W = 32,          // address width
    parameter int DATA_W = 32,          // data width
    parameter int DEPTH  = 8            // number of entries (MUST be power of 2)
) (
    input  logic                 clk,
    input  logic                 rst_n,     // active-low synchronous reset

    // ---- Store enqueue (push) port ----
    input  logic                 st_valid,  // CPU offers a store this cycle
    output logic                 st_ready,  // buffer can accept (not full)
    input  logic [ADDR_W-1:0]    st_addr,
    input  logic [DATA_W-1:0]    st_data,

    // ---- Load lookup (forwarding) port : combinational, same cycle ----
    input  logic                 ld_valid,   // a load is querying this cycle
    input  logic [ADDR_W-1:0]    ld_addr,
    output logic                 ld_fwd_hit, // a pending store forwards
    output logic [DATA_W-1:0]    ld_fwd_data,// value of the youngest match

    // ---- Memory drain (pop) port ----
    output logic                 mem_req,    // oldest entry wants to be written
    input  logic                 mem_ready,  // memory/cache accepts the write
    output logic [ADDR_W-1:0]    mem_addr,
    output logic [DATA_W-1:0]    mem_data,

    // ---- Status ----
    output logic                 full,
    output logic                 empty,
    output logic [$clog2(DEPTH):0] count      // occupancy, 0..DEPTH
);

    // Pointer width: index into DEPTH physical slots.
    localparam int PW = $clog2(DEPTH);

    // ---- Architectural state ----
    logic [ADDR_W-1:0] mem_addr_q [DEPTH];
    logic [DATA_W-1:0] mem_data_q [DEPTH];
    logic              vld_q      [DEPTH];   // slot occupied?
    logic [PW-1:0]     head_q;               // oldest entry (drain point)
    logic [PW:0]       count_q;              // occupancy counter

    // ---- Status (combinational) ----
    assign count = count_q;
    assign empty = (count_q == '0);
    assign full  = (count_q == DEPTH[PW:0]);
    assign st_ready = ~full;

    // Physical slot of the next free entry (tail).
    logic [PW-1:0] tail_c;
    assign tail_c = head_q + count_q[PW-1:0];   // mod-DEPTH by natural wrap

    // Handshake fires.
    logic do_push;
    logic do_pop;
    assign do_push = st_valid & st_ready;
    assign do_pop  = mem_req  & mem_ready;

    // ---- Memory drain port : present the oldest entry ----
    assign mem_req  = ~empty;
    assign mem_addr = mem_addr_q[head_q];
    assign mem_data = mem_data_q[head_q];

    // ---- Store-to-load forwarding search (combinational) ----
    // Walk every physical slot with a fixed-bound loop. A slot forwards if it
    // is valid and its address matches. Among all matches we keep the YOUNGEST,
    // decided by relative age = (slot - head) mod DEPTH : the tail-most occupied
    // slot has the largest age, i.e. it is the most recently enqueued store.
    // `age` is the relative distance of a slot from the head, computed with
    // plain integer arithmetic (no packed-vector bit-selects): head slot -> 0,
    // tail-most occupied slot -> count-1 (the youngest / most recent store).
    always_comb begin
        int age;
        int best_age;
        logic match;
        ld_fwd_hit  = 1'b0;
        ld_fwd_data = '0;
        best_age    = 0;
        for (int i = 0; i < DEPTH; i++) begin
            match = vld_q[i] & (mem_addr_q[i] == ld_addr);
            age   = i - int'(head_q);
            if (age < 0) age = age + DEPTH;      // mod-DEPTH wrap
            if (ld_valid & match & (~ld_fwd_hit | (age >= best_age))) begin
                ld_fwd_hit  = 1'b1;
                ld_fwd_data = mem_data_q[i];
                best_age    = age;
            end
        end
    end

    // ---- Sequential update ----
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            head_q  <= '0;
            count_q <= '0;
            for (int i = 0; i < DEPTH; i++) begin
                vld_q[i]      <= 1'b0;
                mem_addr_q[i] <= '0;
                mem_data_q[i] <= '0;
            end
        end else begin
            // Enqueue into the tail slot.
            if (do_push) begin
                mem_addr_q[tail_c] <= st_addr;
                mem_data_q[tail_c] <= st_data;
                vld_q[tail_c]      <= 1'b1;
            end
            // Dequeue (drain) the head slot.
            if (do_pop) begin
                vld_q[head_q] <= 1'b0;
                head_q        <= head_q + 1'b1;   // mod-DEPTH wrap
            end
            // Occupancy: +1 push, -1 pop, net 0 when both fire.
            case ({do_push, do_pop})
                2'b10:   count_q <= count_q + 1'b1;
                2'b01:   count_q <= count_q - 1'b1;
                default: count_q <= count_q;      // 00 or 11 : unchanged
            endcase
        end
    end

`ifndef SYNTHESIS
    // Elaboration guard : DEPTH must be a power of two for the mod-DEPTH
    // pointer wrap and the relative-age arithmetic to be correct.
    initial begin
        if ((DEPTH & (DEPTH-1)) != 0) begin
            $error("store_buffer: DEPTH (%0d) must be a power of two", DEPTH);
        end
    end
`endif

endmodule
