// ============================================================================
// Day11 : Self-checking testbench for store_buffer
// ----------------------------------------------------------------------------
// Golden reference : a SystemVerilog queue of {addr,data} entries that mirrors
// the DUT's FIFO exactly.
//   * push_back on an accepted store,
//   * pop_front on an accepted memory drain (and check the drained addr/data
//     equal the front of the reference),
//   * for every load lookup, scan the reference from BACK to FRONT (youngest
//     first) for an address match to derive the expected forward hit/data,
//   * every cycle, check DUT count/full/empty against the reference size.
//
// Stimulus : a directed phase that exercises the headline behaviours
// (enqueue, forward the youngest of two stores to one address, forward-then-
// drain, fill-to-full backpressure, drain-to-empty), followed by a long
// randomized phase mixing pushes, pops, and load queries against a small
// address space so forwards, misses, full, and empty all occur frequently.
//
// A watchdog timeout guards against hangs; store_buffer.vcd is dumped for the
// waveform renderer. Prints "RESULT: *** PASS ***" iff every check held.
// ============================================================================
`timescale 1ns/1ps

module tb_store_buffer;

    localparam int ADDR_W = 32;
    localparam int DATA_W = 32;
    localparam int DEPTH  = 8;

    // ---- DUT connections ----
    logic                 clk, rst_n;
    logic                 st_valid, st_ready;
    logic [ADDR_W-1:0]    st_addr;
    logic [DATA_W-1:0]    st_data;
    logic                 ld_valid;
    logic [ADDR_W-1:0]    ld_addr;
    logic                 ld_fwd_hit;
    logic [DATA_W-1:0]    ld_fwd_data;
    logic                 mem_req, mem_ready;
    logic [ADDR_W-1:0]    mem_addr;
    logic [DATA_W-1:0]    mem_data;
    logic                 full, empty;
    logic [$clog2(DEPTH):0] count;

    store_buffer #(.ADDR_W(ADDR_W), .DATA_W(DATA_W), .DEPTH(DEPTH)) dut (
        .clk(clk), .rst_n(rst_n),
        .st_valid(st_valid), .st_ready(st_ready),
        .st_addr(st_addr), .st_data(st_data),
        .ld_valid(ld_valid), .ld_addr(ld_addr),
        .ld_fwd_hit(ld_fwd_hit), .ld_fwd_data(ld_fwd_data),
        .mem_req(mem_req), .mem_ready(mem_ready),
        .mem_addr(mem_addr), .mem_data(mem_data),
        .full(full), .empty(empty), .count(count)
    );

    // ---- Clock : 10 ns period ----
    initial clk = 1'b0;
    always #5 clk = ~clk;

    // ---- Golden reference FIFO ----
    // Two parallel queues (addr, data) kept in enqueue order. front = oldest,
    // back = youngest. (Parallel scalar queues instead of a queue-of-struct
    // for portability across simulators.)
    logic [ADDR_W-1:0] ref_addr [$];
    logic [DATA_W-1:0] ref_data [$];

    int errors = 0;

    // Expected forward for an address, scanning youngest -> oldest.
    task automatic expect_fwd(input logic [ADDR_W-1:0] a,
                              output logic hit,
                              output logic [DATA_W-1:0] d);
        hit = 1'b0;
        d   = '0;
        for (int i = ref_addr.size()-1; i >= 0; i--) begin
            if (ref_addr[i] == a) begin
                hit = 1'b1;
                d   = ref_data[i];
                return;
            end
        end
    endtask

    // ---- Combinational lookup check + status check (before each posedge) ----
    // Sampled just before the clock edge so DUT combinational outputs reflect
    // the current architectural state and the current ld_addr/ld_valid drive.
    task automatic check_now();
        logic exp_hit;
        logic [DATA_W-1:0] exp_data;
        // status
        if (count !== ref_addr.size()) begin
            $display("[%0t] COUNT MISMATCH dut=%0d ref=%0d", $time, count, ref_addr.size());
            errors++;
        end
        if (empty !== (ref_addr.size() == 0)) begin
            $display("[%0t] EMPTY MISMATCH dut=%0b ref_size=%0d", $time, empty, ref_addr.size());
            errors++;
        end
        if (full !== (ref_addr.size() == DEPTH)) begin
            $display("[%0t] FULL MISMATCH dut=%0b ref_size=%0d", $time, full, ref_addr.size());
            errors++;
        end
        // forwarding (only meaningful when a load is being presented)
        if (ld_valid) begin
            expect_fwd(ld_addr, exp_hit, exp_data);
            if (ld_fwd_hit !== exp_hit) begin
                $display("[%0t] FWD-HIT MISMATCH addr=%h dut=%0b exp=%0b",
                         $time, ld_addr, ld_fwd_hit, exp_hit);
                errors++;
            end else if (exp_hit && (ld_fwd_data !== exp_data)) begin
                $display("[%0t] FWD-DATA MISMATCH addr=%h dut=%h exp=%h",
                         $time, ld_addr, ld_fwd_data, exp_data);
                errors++;
            end
        end
    endtask

    // ---- Drain-data check : when a pop is accepted, DUT must present the
    //      reference front's addr/data.
    task automatic check_drain();
        if (mem_req && mem_ready) begin
            if (ref_addr.size() == 0) begin
                $display("[%0t] DRAIN with empty reference!", $time);
                errors++;
            end else if (mem_addr !== ref_addr[0] || mem_data !== ref_data[0]) begin
                $display("[%0t] DRAIN MISMATCH dut=%h/%h ref=%h/%h",
                         $time, mem_addr, mem_data, ref_addr[0], ref_data[0]);
                errors++;
            end
        end
    endtask

    // ---- Reference update : apply the same push/pop the DUT will latch ----
    task automatic ref_update();
        if (mem_req && mem_ready) begin    // pop accepted
            void'(ref_addr.pop_front());
            void'(ref_data.pop_front());
        end
        if (st_valid && st_ready) begin    // push accepted
            ref_addr.push_back(st_addr);
            ref_data.push_back(st_data);
        end
    endtask

    // ---- One driven cycle ----
    // Inputs are applied by drive() immediately before step() is called (at the
    // previous posedge instant). We first let combinational logic settle (#1),
    // sample & check the DUT outputs against the reference, mirror the accepted
    // transaction into the reference, then advance to the next posedge where the
    // DUT latches exactly that transaction.
    task automatic step();
        #1;              // settle combinational outputs for the freshly-driven inputs
        check_now();     // combinational outputs vs current state
        check_drain();   // drain data vs reference front
        ref_update();    // mirror the transaction the DUT will latch
        @(posedge clk);  // advance; DUT latches
    endtask

    // Convenience drivers (set inputs, then call step()).
    task automatic drive(input logic sv, input logic [ADDR_W-1:0] sa,
                         input logic [DATA_W-1:0] sd,
                         input logic lv, input logic [ADDR_W-1:0] la,
                         input logic mr);
        st_valid = sv; st_addr = sa; st_data = sd;
        ld_valid = lv; ld_addr = la;
        mem_ready = mr;
    endtask

    // ---- Watchdog ----
    initial begin
        #300000;
        $display("RESULT: *** FAIL *** (timeout)");
        $fatal(1, "timeout");
    end

    // ---- Waveform dump ----
    initial begin
        $dumpfile("store_buffer.vcd");
        $dumpvars(0, tb_store_buffer);
    end

    // ---- Stimulus ----
    integer i;
    logic [ADDR_W-1:0] ra;
    logic [DATA_W-1:0] rd;
    logic              rsv, rlv, rmr;

    initial begin
        // Reset
        drive(1'b0,'0,'0,1'b0,'0,1'b0);
        rst_n = 1'b0;
        @(posedge clk); @(posedge clk); #1;
        rst_n = 1'b1;

        // -------- DIRECTED PHASE --------
        // 1) idle
        drive(1'b0,'0,'0,1'b0,'0,1'b0);            step();
        // 2) store A=0x100 <= 0xAAAA (no drain)
        drive(1'b1,32'h100,32'hAAAA,1'b0,'0,1'b0); step();
        // 3) store A=0x100 <= 0xBBBB  (younger store to same addr)
        drive(1'b1,32'h100,32'hBBBB,1'b0,'0,1'b0); step();
        // 4) store B=0x200 <= 0xC0DE
        drive(1'b1,32'h200,32'hC0DE,1'b0,'0,1'b0); step();
        // 5) load 0x100 -> must forward YOUNGEST = 0xBBBB
        drive(1'b0,'0,'0,1'b1,32'h100,1'b0);       step();
        // 6) load 0x200 -> forward 0xC0DE
        drive(1'b0,'0,'0,1'b1,32'h200,1'b0);       step();
        // 7) load 0x300 -> MISS (no pending store)
        drive(1'b0,'0,'0,1'b1,32'h300,1'b0);       step();
        // 8) drain oldest (0x100/0xAAAA) while querying 0x100 (still hits 0xBBBB)
        drive(1'b0,'0,'0,1'b1,32'h100,1'b1);       step();
        // 9) drain next (0x100/0xBBBB); now 0x100 has one entry left? no: both
        //    0x100 stores were oldest two; after this pop only 0x200 remains.
        drive(1'b0,'0,'0,1'b1,32'h100,1'b1);       step();
        // 10) load 0x100 -> now MISS (both drained)
        drive(1'b0,'0,'0,1'b1,32'h100,1'b0);       step();
        // 11) simultaneous push (0x400) + drain (0x200) -> count steady at 1
        drive(1'b1,32'h400,32'h4444,1'b0,'0,1'b1); step();
        // 12) drain 0x400
        drive(1'b0,'0,'0,1'b0,'0,1'b1);            step();
        // 13) now empty : drain asserted but nothing to pop
        drive(1'b0,'0,'0,1'b0,'0,1'b1);            step();

        // Fill to FULL to exercise backpressure (st_ready must drop).
        for (i = 0; i < DEPTH+2; i++) begin
            drive(1'b1, 32'h1000 + (i<<2), 32'hD00 + i, 1'b0,'0, 1'b0);
            step();
        end
        // Confirm full asserted / st_ready low observed via checks above.
        // Drain everything back to empty.
        for (i = 0; i < DEPTH+2; i++) begin
            drive(1'b0,'0,'0,1'b0,'0,1'b1);
            step();
        end

        // -------- RANDOMIZED PHASE --------
        // Small 8-address space (0x2000,0x2004,...) so matches are frequent.
        for (i = 0; i < 2000; i++) begin
            rsv = ($urandom_range(0,99) < 60);
            rlv = ($urandom_range(0,99) < 55);
            rmr = ($urandom_range(0,99) < 50);
            ra  = 32'h2000 + (($urandom_range(0,7)) << 2);
            rd  = $urandom;
            drive(rsv, 32'h2000 + (($urandom_range(0,7))<<2), rd, rlv, ra, rmr);
            step();
        end

        // Drain to empty for a clean tail.
        for (i = 0; i < DEPTH+2; i++) begin
            drive(1'b0,'0,'0,1'b0,'0,1'b1);
            step();
        end

        if (errors == 0)
            $display("RESULT: *** PASS *** (all checks held; %0d random ops)", 2000);
        else
            $display("RESULT: *** FAIL *** (%0d errors)", errors);
        $finish;
    end

endmodule
