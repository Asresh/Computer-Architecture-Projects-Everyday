// Author: Asresh Kuricheti
// Self-checking transaction-level golden model.
//
//   directed + random requests ---> DUT ---> probes/memory/response
//               reference directory <------ compare every transaction

`timescale 1ns/1ps

module tb_coherence_home_agent;
    localparam integer NUM_AGENTS = 4;
    localparam integer ADDR_WIDTH = 12;
    localparam integer DATA_WIDTH = 32;
    localparam integer TXN_ID_WIDTH = 6;
    localparam integer AGENT_WIDTH = 2;

    logic clk, rst_n;
    logic req_valid, req_ready, req_unique;
    logic [AGENT_WIDTH-1:0] req_src;
    logic [TXN_ID_WIDTH-1:0] req_txn_id;
    logic [ADDR_WIDTH-1:0] req_addr;
    logic probe_valid, probe_ready, probe_invalidate;
    logic [AGENT_WIDTH-1:0] probe_target, probe_ack_src;
    logic [ADDR_WIDTH-1:0] probe_addr;
    logic probe_ack_valid;
    logic mem_read_valid, mem_read_ready, mem_data_valid;
    logic [ADDR_WIDTH-1:0] mem_read_addr;
    logic [DATA_WIDTH-1:0] mem_read_data;
    logic rsp_valid, rsp_ready, rsp_grant_unique;
    logic [AGENT_WIDTH-1:0] rsp_dst;
    logic [TXN_ID_WIDTH-1:0] rsp_txn_id;
    logic [DATA_WIDTH-1:0] rsp_data;
    logic busy, line_valid, line_unique, protocol_error;
    logic [ADDR_WIDTH-1:0] line_addr;
    logic [NUM_AGENTS-1:0] line_sharers;
    logic [2:0] state_debug;

    logic ref_valid, ref_unique;
    logic [ADDR_WIDTH-1:0] ref_addr;
    logic [DATA_WIDTH-1:0] ref_data;
    logic [NUM_AGENTS-1:0] ref_sharers;
    integer checks, transactions, seed, cycle_count;

    coherence_home_agent #(
        .NUM_AGENTS(NUM_AGENTS), .ADDR_WIDTH(ADDR_WIDTH),
        .DATA_WIDTH(DATA_WIDTH), .TXN_ID_WIDTH(TXN_ID_WIDTH)
    ) dut (.*);

    always #5 clk = ~clk;

    function automatic [DATA_WIDTH-1:0] memory_value(input [ADDR_WIDTH-1:0] addr);
        memory_value = 32'hcafe0000 ^ {20'h0, addr};
    endfunction

    task automatic fail(input string message);
        begin
            $display("FAIL cycle %0d transaction %0d: %s", cycle_count, transactions, message);
            $display("RESULT: *** FAIL ***");
            $finish;
        end
    endtask

    task automatic tick;
        begin
            @(posedge clk); #1; cycle_count = cycle_count + 1;
        end
    endtask

    task automatic check_directory;
        begin
            checks = checks + 5;
            if (line_valid !== ref_valid) fail("line_valid mismatch");
            if (ref_valid && (line_addr !== ref_addr)) fail("line_addr mismatch");
            if (line_sharers !== ref_sharers) fail("line_sharers mismatch");
            if (line_unique !== ref_unique) fail("line_unique mismatch");
            if (protocol_error !== 1'b0) fail("unexpected protocol_error");
        end
    endtask

    task automatic transact(
        input logic [AGENT_WIDTH-1:0] src,
        input logic unique_access,
        input logic [ADDR_WIDTH-1:0] addr
    );
        logic hit;
        logic [NUM_AGENTS-1:0] expected_probes;
        logic expected_probe_invalidate;
        logic expected_mem;
        logic [DATA_WIDTH-1:0] expected_data;
        logic [TXN_ID_WIDTH-1:0] txn;
        integer watchdog;
        integer delay_count;
        begin
            transactions = transactions + 1;
            txn = transactions[TXN_ID_WIDTH-1:0];
            hit = ref_valid && (ref_addr == addr);
            expected_mem = !hit;
            expected_data = hit ? ref_data : memory_value(addr);
            if (!hit) begin
                expected_probes = ref_valid ? ref_sharers : '0;
                expected_probe_invalidate = 1'b1;
            end else if (unique_access) begin
                expected_probes = ref_sharers & ~(1'b1 << src);
                expected_probe_invalidate = 1'b1;
            end else if (ref_unique && !ref_sharers[src]) begin
                expected_probes = ref_sharers;
                expected_probe_invalidate = 1'b0;
            end else begin
                expected_probes = '0;
                expected_probe_invalidate = 1'b0;
            end

            @(negedge clk);
            req_valid = 1'b1;
            req_src = src;
            req_txn_id = txn;
            req_addr = addr;
            req_unique = unique_access;
            while (!req_ready) tick();
            tick();
            @(negedge clk); req_valid = 1'b0;

            watchdog = 0;
            while (!rsp_valid) begin
                watchdog = watchdog + 1;
                if (watchdog > 80) fail("transaction timeout");

                probe_ready = (($urandom(seed) % 4) != 0);
                mem_read_ready = (($urandom(seed) % 3) != 0);

                if (probe_valid && probe_ready) begin
                    checks = checks + 4;
                    if (!expected_probes[probe_target]) fail("unexpected or duplicate probe target");
                    if (probe_addr !== (expected_mem ? ref_addr : addr)) fail("probe address mismatch");
                    if (probe_invalidate !== expected_probe_invalidate) fail("probe command mismatch");
                    if (expected_probes == '0) fail("probe emitted with empty golden mask");
                    expected_probes[probe_target] = 1'b0;
                    tick();
                    probe_ready = 1'b0;
                    delay_count = $urandom(seed) % 3;
                    repeat (delay_count) tick();
                    @(negedge clk);
                    probe_ack_src = probe_target;
                    probe_ack_valid = 1'b1;
                    tick();
                    @(negedge clk); probe_ack_valid = 1'b0;
                end else if (mem_read_valid && mem_read_ready) begin
                    checks = checks + 2;
                    if (!expected_mem) fail("unexpected memory read");
                    if (mem_read_addr !== addr) fail("memory address mismatch");
                    expected_mem = 1'b0;
                    tick();
                    delay_count = 1 + ($urandom(seed) % 3);
                    repeat (delay_count) tick();
                    @(negedge clk);
                    mem_read_data = memory_value(addr);
                    mem_data_valid = 1'b1;
                    tick();
                    @(negedge clk); mem_data_valid = 1'b0;
                end else begin
                    tick();
                end
            end

            checks = checks + 6;
            if (expected_probes != '0) fail("response arrived before all probes");
            if (expected_mem) fail("response arrived before required memory read");
            if (rsp_dst !== src) fail("response destination mismatch");
            if (rsp_txn_id !== txn) fail("response transaction ID mismatch");
            if (rsp_data !== expected_data) fail("response data mismatch");
            if (rsp_grant_unique !== unique_access) fail("response grant mismatch");

            rsp_ready = (($urandom(seed) % 2) == 0);
            while (!rsp_ready) begin
                tick();
                if (!rsp_valid) fail("response lost under backpressure");
                rsp_ready = (($urandom(seed) % 2) == 0);
            end
            tick();
            @(negedge clk); rsp_ready = 1'b0;

            ref_valid = 1'b1;
            ref_addr = addr;
            ref_data = expected_data;
            if (unique_access) begin
                ref_sharers = (1'b1 << src);
                ref_unique = 1'b1;
            end else begin
                ref_sharers = hit ? (ref_sharers | (1'b1 << src)) : (1'b1 << src);
                ref_unique = 1'b0;
            end
            check_directory();
        end
    endtask

    initial begin
        #500000;
        $display("RESULT: *** FAIL *** (global timeout)");
        $finish;
    end

    initial begin
        $dumpfile("coherence_home_agent.vcd");
        $dumpvars(0, tb_coherence_home_agent);
        clk = 0; rst_n = 0; req_valid = 0; req_src = 0; req_txn_id = 0;
        req_addr = 0; req_unique = 0; probe_ready = 0; probe_ack_valid = 0;
        probe_ack_src = 0; mem_read_ready = 0; mem_data_valid = 0;
        mem_read_data = 0; rsp_ready = 0;
        ref_valid = 0; ref_unique = 0; ref_addr = 0; ref_data = 0;
        ref_sharers = 0; checks = 0; transactions = 0; cycle_count = 0;
        seed = 32'h45c0ffee;

        repeat (3) tick();
        @(negedge clk); rst_n = 1;
        check_directory();

        // Directed: miss, shared hit, exclusive upgrade, downgrade, replacement.
        transact(0, 0, 12'h100);
        transact(1, 0, 12'h100);
        transact(1, 1, 12'h100);
        transact(2, 0, 12'h100);
        transact(3, 1, 12'h240);
        transact(3, 1, 12'h240);

        // Randomized source, command, hit/miss mix, and all channel backpressure.
        repeat (200) begin
            if (($urandom(seed) % 4) != 0)
                transact($urandom(seed) % NUM_AGENTS, $urandom(seed) % 2, ref_addr);
            else
                transact($urandom(seed) % NUM_AGENTS, $urandom(seed) % 2,
                         ($urandom(seed) % 64) << 4);
        end

        $display("Completed %0d transactions, %0d cycles, and %0d checks",
                 transactions, cycle_count, checks);
        $display("RESULT: *** PASS ***");
        $finish;
    end
endmodule
