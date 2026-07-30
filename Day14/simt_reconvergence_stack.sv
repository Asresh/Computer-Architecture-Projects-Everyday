// simt_reconvergence_stack.sv - Day 14
//
// SIMT (Single-Instruction Multiple-Thread) reconvergence stack - the PDOM
// (Post-DOMinator) hardware structure a modern GPU (e.g. an NVIDIA SM) uses to
// execute a *warp* of lock-step threads through *divergent* control flow.
//
// A warp is NLANES threads sharing one instruction stream. As long as every
// active thread takes the same branch direction the warp runs as a single
// packet. When a data-dependent branch sends some lanes one way and the rest
// the other, the hardware must (1) serialise the two sides and (2) bring the
// lanes back together at the first instruction where both paths meet again -
// the branch's *immediate post-dominator* (the reconvergence PC / RPC).
//
// This module implements the canonical serial-stack algorithm:
//
//   Top-of-stack (TOS) = { mask, pc, rpc } is the group currently issued:
//     mask : one active bit per lane
//     pc   : the PC that group will fetch next
//     rpc  : the PC at which this group must reconverge (pop itself)
//
//   DIVERGE (branch at TOS with active mask M splits into T / NT != {},{}):
//     1. TOS becomes the *join* entry:  pc <- RPC (mask M and its rpc kept),
//     2. push the not-taken path        { NT, fall_pc, RPC },
//     3. push the taken path            { T,  taken_pc, RPC }.
//     (A uniform branch - all lanes one way - just retargets TOS.pc, no push.)
//
//   POP (reconverge): when a path's pc reaches its rpc it is finished; pop it,
//     exposing the sibling path, then finally the join entry, at which point
//     all M lanes run together again from RPC. Nesting recurses naturally.
//
// The controller drives DIVERGE / SETPC / POP; status output `at_reconv`
// (active_pc == tos.rpc) tells it exactly when to POP. Reset-safe, lint-clean,
// synthesizable. Stack is parallel mask/pc/rpc arrays indexed by a single
// count register `sp`; no variable bit-selects of packed vectors.

`timescale 1ns/1ps
`default_nettype none

module simt_reconvergence_stack #(
    parameter int NLANES = 8,     // warp width (threads per warp)
    parameter int DEPTH  = 16,    // stack depth (>= max nesting*2 + 1)
    parameter int PC_W   = 16     // program-counter width
) (
    input  wire                   clk,
    input  wire                   rst_n,      // active-low synchronous reset

    // Operation for this cycle (one command / cycle).
    input  wire  [2:0]            op,         // see localparams below
    input  wire  [NLANES-1:0]     in_mask,    // PUSH: seed active mask
    input  wire  [PC_W-1:0]       in_pc,      // PUSH/SETPC: pc value
    input  wire  [NLANES-1:0]     div_taken,  // DIVERGE: lanes taking the branch
    input  wire  [PC_W-1:0]       div_tpc,    // DIVERGE: taken-path target PC
    input  wire  [PC_W-1:0]       div_fpc,    // DIVERGE: fall-through target PC
    input  wire  [PC_W-1:0]       div_rpc,    // DIVERGE: reconvergence PC (IPDOM)

    // Top-of-stack view (the group to issue this cycle).
    output logic [NLANES-1:0]     active_mask,// TOS mask (0 when empty)
    output logic [PC_W-1:0]       active_pc,  // TOS pc
    output logic [PC_W-1:0]       tos_rpc,    // TOS reconvergence pc
    output logic [$clog2(DEPTH+1)-1:0] sp,    // entry count (0..DEPTH)
    output logic                  empty,      // sp == 0
    output logic                  full,       // sp == DEPTH
    output logic                  at_reconv,  // !empty && active_pc == tos.rpc
    output logic                  diverged,   // 1-cycle: last DIVERGE actually split
    output logic                  err         // sticky: overflow / underflow / bad op
);

    // --- Operation encoding ------------------------------------------------
    localparam logic [2:0] OP_NOP     = 3'd0;  // hold
    localparam logic [2:0] OP_PUSH    = 3'd1;  // seed base entry {in_mask,in_pc,NONE}
    localparam logic [2:0] OP_SETPC   = 3'd2;  // uniform advance: TOS.pc <- in_pc
    localparam logic [2:0] OP_DIVERGE = 3'd3;  // divergent branch at TOS
    localparam logic [2:0] OP_POP     = 3'd4;  // reconverge: pop TOS

    // rpc sentinel for a base entry that never reconverges (top-level warp).
    localparam logic [PC_W-1:0] RPC_NONE = {PC_W{1'b1}};

    localparam int SPW = $clog2(DEPTH+1);

    // --- Stack storage (parallel arrays) -----------------------------------
    logic [NLANES-1:0] mask_mem [0:DEPTH-1];
    logic [PC_W-1:0]   pc_mem   [0:DEPTH-1];
    logic [PC_W-1:0]   rpc_mem  [0:DEPTH-1];

    // Top-of-stack index (valid only when sp != 0).
    logic [SPW-1:0] tos;
    assign tos = (sp == '0) ? '0 : (sp - 1'b1);

    // Combinational split of the current active mask for a DIVERGE.
    logic [NLANES-1:0] cur_mask, take_set, fall_set;
    assign cur_mask  = (sp == '0) ? '0 : mask_mem[tos];
    assign take_set  = div_taken & cur_mask;          // active lanes going taken
    assign fall_set  = cur_mask & ~div_taken;         // active lanes falling through
    logic is_divergent;
    assign is_divergent = (take_set != '0) && (fall_set != '0);

    // --- Status outputs ----------------------------------------------------
    assign empty       = (sp == '0);
    assign full        = (sp == DEPTH[SPW-1:0]);
    assign active_mask = empty ? '0 : mask_mem[tos];
    assign active_pc   = empty ? '0 : pc_mem[tos];
    assign tos_rpc     = empty ? RPC_NONE : rpc_mem[tos];
    assign at_reconv   = !empty && (pc_mem[tos] == rpc_mem[tos]);

    // --- Sequential update -------------------------------------------------
    integer i;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sp       <= '0;
            diverged <= 1'b0;
            err      <= 1'b0;
            for (i = 0; i < DEPTH; i = i + 1) begin
                mask_mem[i] <= '0;
                pc_mem[i]   <= '0;
                rpc_mem[i]  <= '0;
            end
        end else begin
            diverged <= 1'b0;   // default: single-cycle pulse
            case (op)
                OP_NOP: begin
                    // hold
                end

                OP_PUSH: begin
                    if (full) begin
                        err <= 1'b1;                 // overflow
                    end else begin
                        mask_mem[sp[SPW-1:0]] <= in_mask;
                        pc_mem  [sp[SPW-1:0]] <= in_pc;
                        rpc_mem [sp[SPW-1:0]] <= RPC_NONE;
                        sp <= sp + 1'b1;
                    end
                end

                OP_SETPC: begin
                    if (empty) err <= 1'b1;          // no TOS to retarget
                    else       pc_mem[tos] <= in_pc;
                end

                OP_DIVERGE: begin
                    if (empty) begin
                        err <= 1'b1;                 // nothing executing
                    end else if (!is_divergent) begin
                        // Uniform branch: just retarget the whole group.
                        pc_mem[tos] <= (take_set != '0) ? div_tpc : div_fpc;
                    end else if (sp > (DEPTH-2)) begin
                        err <= 1'b1;                 // need 2 free slots to split
                    end else begin
                        // 1. TOS becomes the join entry (reconvergence point).
                        pc_mem[tos]        <= div_rpc;   // mask & rpc unchanged
                        // 2. push not-taken path, 3. push taken path.
                        mask_mem[sp[SPW-1:0]]        <= fall_set;
                        pc_mem  [sp[SPW-1:0]]        <= div_fpc;
                        rpc_mem [sp[SPW-1:0]]        <= div_rpc;
                        mask_mem[sp[SPW-1:0] + 1'b1] <= take_set;
                        pc_mem  [sp[SPW-1:0] + 1'b1] <= div_tpc;
                        rpc_mem [sp[SPW-1:0] + 1'b1] <= div_rpc;
                        sp       <= sp + 2'd2;
                        diverged <= 1'b1;
                    end
                end

                OP_POP: begin
                    if (empty) err <= 1'b1;          // underflow
                    else       sp  <= sp - 1'b1;
                end

                default: err <= 1'b1;                // undefined opcode
            endcase
        end
    end

endmodule

`default_nettype wire
