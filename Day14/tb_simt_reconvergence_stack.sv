// tb_simt_reconvergence_stack.sv - Day 14
//
// Self-checking testbench for the SIMT reconvergence (PDOM) stack.
//
// Strategy: an INDEPENDENT software golden model (plain SV arrays + counter)
// re-implements the reconvergence-stack algorithm from the spec. Every cycle we
// drive one operation into both the DUT and the model, then compare the DUT's
// top-of-stack view (mask/pc/rpc), entry count, and status flags against the
// model. Coverage = directed scenarios (uniform branch, single diverge +
// reconverge, nested diverge, full drain, overflow/underflow errors) followed
// by a long randomized legal-op stream. A watchdog aborts a hung run; the DUT
// also dumps simt_reconvergence_stack.vcd for the waveform image.

`timescale 1ns/1ps
`default_nettype none

module tb_simt_reconvergence_stack;

    localparam int NLANES = 8;
    localparam int DEPTH  = 16;
    localparam int PC_W   = 16;
    localparam int SPW    = $clog2(DEPTH+1);
    localparam logic [PC_W-1:0] RPC_NONE = {PC_W{1'b1}};

    // Op encoding (must match DUT).
    localparam logic [2:0] OP_NOP     = 3'd0;
    localparam logic [2:0] OP_PUSH    = 3'd1;
    localparam logic [2:0] OP_SETPC   = 3'd2;
    localparam logic [2:0] OP_DIVERGE = 3'd3;
    localparam logic [2:0] OP_POP     = 3'd4;

    // --- DUT I/O ------------------------------------------------------------
    logic                   clk, rst_n;
    logic [2:0]             op;
    logic [NLANES-1:0]      in_mask, div_taken;
    logic [PC_W-1:0]        in_pc, div_tpc, div_fpc, div_rpc;

    logic [NLANES-1:0]      active_mask;
    logic [PC_W-1:0]        active_pc, tos_rpc;
    logic [SPW-1:0]         sp;
    logic                   empty, full, at_reconv, diverged, err;

    simt_reconvergence_stack #(
        .NLANES(NLANES), .DEPTH(DEPTH), .PC_W(PC_W)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .op(op), .in_mask(in_mask), .in_pc(in_pc),
        .div_taken(div_taken), .div_tpc(div_tpc), .div_fpc(div_fpc),
        .div_rpc(div_rpc),
        .active_mask(active_mask), .active_pc(active_pc), .tos_rpc(tos_rpc),
        .sp(sp), .empty(empty), .full(full), .at_reconv(at_reconv),
        .diverged(diverged), .err(err)
    );

    // --- Golden model -------------------------------------------------------
    logic [NLANES-1:0] r_mask [0:DEPTH-1];
    logic [PC_W-1:0]   r_pc   [0:DEPTH-1];
    logic [PC_W-1:0]   r_rpc  [0:DEPTH-1];
    int                r_sp;
    logic              r_err;
    logic              r_diverged;

    // Expected combinational views derived from the model state.
    function automatic logic [NLANES-1:0] r_active_mask; return (r_sp==0)? '0 : r_mask[r_sp-1]; endfunction
    function automatic logic [PC_W-1:0]   r_active_pc;   return (r_sp==0)? '0 : r_pc  [r_sp-1]; endfunction
    function automatic logic [PC_W-1:0]   r_tos_rpc;     return (r_sp==0)? RPC_NONE : r_rpc[r_sp-1]; endfunction
    function automatic logic              r_empty;       return (r_sp==0); endfunction
    function automatic logic              r_full;        return (r_sp==DEPTH); endfunction
    function automatic logic              r_at_reconv;   return (r_sp!=0) && (r_pc[r_sp-1]==r_rpc[r_sp-1]); endfunction

    // Independent re-implementation of one operation on the model.
    task automatic ref_apply(input logic [2:0] o);
        logic [NLANES-1:0] m, t, nt;
        r_diverged = 1'b0;
        case (o)
            OP_NOP: ;
            OP_PUSH: begin
                if (r_full()) r_err = 1'b1;
                else begin
                    r_mask[r_sp] = in_mask;
                    r_pc  [r_sp] = in_pc;
                    r_rpc [r_sp] = RPC_NONE;
                    r_sp = r_sp + 1;
                end
            end
            OP_SETPC: begin
                if (r_empty()) r_err = 1'b1;
                else           r_pc[r_sp-1] = in_pc;
            end
            OP_DIVERGE: begin
                if (r_empty()) r_err = 1'b1;
                else begin
                    m  = r_mask[r_sp-1];
                    t  = div_taken & m;
                    nt = m & ~div_taken;
                    if ((t=='0) || (nt=='0))
                        r_pc[r_sp-1] = (t!='0) ? div_tpc : div_fpc;   // uniform
                    else if (r_sp > (DEPTH-2)) r_err = 1'b1;
                    else begin
                        r_pc[r_sp-1] = div_rpc;                       // join entry
                        r_mask[r_sp]   = nt; r_pc[r_sp]   = div_fpc; r_rpc[r_sp]   = div_rpc;
                        r_mask[r_sp+1] = t;  r_pc[r_sp+1] = div_tpc; r_rpc[r_sp+1] = div_rpc;
                        r_sp = r_sp + 2;
                        r_diverged = 1'b1;
                    end
                end
            end
            OP_POP: begin
                if (r_empty()) r_err = 1'b1;
                else           r_sp = r_sp - 1;
            end
            default: r_err = 1'b1;
        endcase
    endtask

    // --- Scoreboard ---------------------------------------------------------
    int errors;
    task automatic check(input string tag);
        if (active_mask !== r_active_mask()) begin
            $error("[%0t] %s: active_mask DUT=%b REF=%b", $time, tag, active_mask, r_active_mask()); errors++;
        end
        if (active_pc   !== r_active_pc())   begin
            $error("[%0t] %s: active_pc DUT=%h REF=%h", $time, tag, active_pc, r_active_pc()); errors++;
        end
        if (tos_rpc     !== r_tos_rpc())     begin
            $error("[%0t] %s: tos_rpc DUT=%h REF=%h", $time, tag, tos_rpc, r_tos_rpc()); errors++;
        end
        if (sp          !== r_sp[SPW-1:0])   begin
            $error("[%0t] %s: sp DUT=%0d REF=%0d", $time, tag, sp, r_sp); errors++;
        end
        if (empty !== r_empty() || full !== r_full() || at_reconv !== r_at_reconv()) begin
            $error("[%0t] %s: flags DUT(e%b f%b r%b) REF(e%b f%b r%b)", $time, tag,
                   empty, full, at_reconv, r_empty(), r_full(), r_at_reconv()); errors++;
        end
        if (err !== r_err) begin
            $error("[%0t] %s: err DUT=%b REF=%b", $time, tag, err, r_err); errors++;
        end
        if (diverged !== r_diverged) begin
            $error("[%0t] %s: diverged DUT=%b REF=%b", $time, tag, diverged, r_diverged); errors++;
        end
    endtask

    // Drive one op into DUT + model for a full cycle, then compare.
    task automatic step(input logic [2:0] o, input string tag);
        @(negedge clk);
        op = o;
        @(posedge clk);          // DUT & model capture the same op
        ref_apply(o);
        #1;                      // let DUT combinational outputs settle
        check(tag);
        @(negedge clk);
        op = OP_NOP;
    endtask

    // --- Clock & watchdog ---------------------------------------------------
    initial clk = 1'b0;
    always #5 clk = ~clk;

    initial begin
        #100000;
        $error("TIMEOUT: watchdog fired");
        $finish;
    end

    // --- Stimulus -----------------------------------------------------------
    int k;
    logic [NLANES-1:0] rmask;
    initial begin
        $dumpfile("simt_reconvergence_stack.vcd");
        $dumpvars(0, tb_simt_reconvergence_stack);

        // defaults
        op=OP_NOP; in_mask='0; in_pc='0; div_taken='0; div_tpc='0; div_fpc='0; div_rpc='0;
        errors=0; r_sp=0; r_err=0; r_diverged=0;

        // reset
        rst_n=0;
        repeat (3) @(negedge clk);
        rst_n=1;
        @(negedge clk);
        check("post-reset");   // empty, mask 0

        // ---- Directed 1: seed the full warp -------------------------------
        in_mask = 8'hFF; in_pc = 16'h0000;
        step(OP_PUSH, "seed-warp");

        // ---- Directed 2: UNIFORM branch (all lanes taken) - no split ------
        div_taken = 8'hFF; div_tpc = 16'h0040; div_fpc = 16'h0004; div_rpc = 16'h0080;
        step(OP_DIVERGE, "uniform-all-taken");   // sp stays 1, pc -> 0x40

        // ---- Directed 3: DIVERGENT branch at pc=0x40 ----------------------
        // lanes 0..3 take (pc 0x50), lanes 4..7 fall (pc 0x44), reconverge 0x60
        div_taken = 8'h0F; div_tpc = 16'h0050; div_fpc = 16'h0044; div_rpc = 16'h0060;
        step(OP_DIVERGE, "diverge-split");        // sp 1->3, TOS = taken {0F,0x50}
        if (active_mask !== 8'h0F || active_pc !== 16'h0050)
            begin $error("split TOS wrong"); errors++; end

        // taken path runs to reconvergence PC, then pops
        in_pc = 16'h0060; step(OP_SETPC, "taken-run-to-rpc");
        if (!at_reconv) begin $error("expected at_reconv on taken path"); errors++; end
        step(OP_POP, "pop-taken");                // TOS = fall {F0,0x44}
        if (active_mask !== 8'hF0 || active_pc !== 16'h0044)
            begin $error("sibling TOS wrong"); errors++; end

        // ---- Directed 4: NESTED diverge on the fall-through path ----------
        // of {F0}: lanes 4,5 take (0x54), lanes 6,7 fall (0x48), reconv 0x58
        div_taken = 8'h30; div_tpc = 16'h0054; div_fpc = 16'h0048; div_rpc = 16'h0058;
        step(OP_DIVERGE, "nested-diverge");       // sp 2->4
        if (active_mask !== 8'h30 || active_pc !== 16'h0054)
            begin $error("nested TOS wrong"); errors++; end

        // drain the two inner paths back to 0x58
        in_pc = 16'h0058; step(OP_SETPC, "inner-taken->rpc");
        step(OP_POP, "pop-inner-taken");          // TOS = inner fall {C0,0x48}
        in_pc = 16'h0058; step(OP_SETPC, "inner-fall->rpc");
        step(OP_POP, "pop-inner-fall");           // TOS = inner join {F0,0x58}
        if (active_mask !== 8'hF0 || active_pc !== 16'h0058)
            begin $error("inner join wrong"); errors++; end

        // inner join runs to outer rpc 0x60, pop -> outer join {FF,0x60}
        in_pc = 16'h0060; step(OP_SETPC, "innerjoin->outer_rpc");
        step(OP_POP, "pop-inner-join");           // TOS = outer join {FF,0x60}
        if (active_mask !== 8'hFF || active_pc !== 16'h0060)
            begin $error("outer join wrong (full reconverge failed)"); errors++; end

        // ---- Directed 5: error cases --------------------------------------
        // drain the base entry, then underflow
        step(OP_POP, "pop-base");                 // empty
        if (!empty) begin $error("expected empty"); errors++; end
        step(OP_POP, "underflow");                // err must set
        if (!err) begin $error("underflow err not set"); errors++; end

        // ---- Directed 6: overflow via repeated PUSH -----------------------
        // fresh reset to clear sticky err
        rst_n=0; @(negedge clk); rst_n=1; @(negedge clk);
        r_sp=0; r_err=0;  // reset model too
        check("post-reset-2");
        // Push DEPTH+1 base entries: the (DEPTH+1)-th must set overflow err.
        for (k = 0; k <= DEPTH; k++) begin
            in_mask = 8'hFF; in_pc = 16'h0100 + k*4;
            step(OP_PUSH, $sformatf("overflow-push-%0d", k));
        end
        if (!full) begin $error("expected full after DEPTH pushes"); errors++; end
        if (!err)  begin $error("overflow err never set"); errors++; end

        // ---- Randomized legal-op stream -----------------------------------
        rst_n=0; @(negedge clk); rst_n=1; @(negedge clk);
        r_sp=0; r_err=0;
        check("post-reset-3");
        in_mask = 8'hFF; in_pc = 16'h0; step(OP_PUSH, "seed-rand");
        for (k = 0; k < 400; k++) begin
            rmask = $random;
            in_pc     = $random;
            div_taken = $random;
            div_tpc   = $random;
            div_fpc   = $random;
            div_rpc   = $random;
            // pick a legal op given model state (avoid deliberate errors here)
            if (r_sp == 0) begin
                in_mask = (rmask=='0) ? 8'hFF : rmask;
                step(OP_PUSH, "rnd-push");
            end else if (r_sp >= DEPTH-2) begin
                step(OP_POP, "rnd-pop(full)");
            end else begin
                case ($random % 3)
                    0: step(OP_SETPC,   "rnd-setpc");
                    1: step(OP_DIVERGE, "rnd-diverge");
                    default: step(OP_POP, "rnd-pop");
                endcase
            end
        end

        // ---- Report --------------------------------------------------------
        repeat (2) @(negedge clk);
        if (errors == 0)
            $display("RESULT: *** PASS *** (all directed + %0d randomized ops matched golden model)", k);
        else
            $display("RESULT: *** FAIL *** (%0d mismatches)", errors);
        $finish;
    end

endmodule

`default_nettype wire
