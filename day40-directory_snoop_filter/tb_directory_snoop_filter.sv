// Author: Asresh Kuricheti
// Self-checking directed/random verification: requests -> golden directory -> PASS.
`timescale 1ns/1ps
module tb_directory_snoop_filter;
    localparam integer ADDR_WIDTH = 16;
    localparam integer LINE_OFFSET = 4;
    localparam integer SETS = 8;
    localparam integer CORES = 4;
    localparam integer INDEX_WIDTH = $clog2(SETS);
    localparam integer CORE_WIDTH = $clog2(CORES);
    localparam integer TAG_WIDTH = ADDR_WIDTH - LINE_OFFSET - INDEX_WIDTH;
    localparam [1:0] READ_SHARED = 2'b00;
    localparam [1:0] READ_UNIQUE = 2'b01;
    localparam [1:0] EVICT = 2'b10;

    reg clk = 1'b0;
    reg reset_n = 1'b0;
    reg req_valid = 1'b0;
    reg [1:0] req_op = 2'b0;
    reg [CORE_WIDTH-1:0] req_core = 0;
    reg [ADDR_WIDTH-1:0] req_addr = 0;
    wire rsp_valid;
    wire rsp_hit;
    wire [CORES-1:0] snoop_mask;
    wire replacement;
    wire [ADDR_WIDTH-1:0] replaced_addr;
    wire [CORES-1:0] post_sharers;
    wire post_owner_valid;
    wire [CORE_WIDTH-1:0] post_owner;
    wire [$clog2(SETS+1)-1:0] entry_count;

    reg [TAG_WIDTH-1:0] m_tag [0:SETS-1];
    reg [CORES-1:0] m_sharers [0:SETS-1];
    reg [CORE_WIDTH-1:0] m_owner [0:SETS-1];
    reg m_valid [0:SETS-1];
    reg m_owner_valid [0:SETS-1];
    reg exp_hit, exp_replacement, exp_owner_valid;
    reg [CORES-1:0] exp_snoop, exp_post_sharers;
    reg [ADDR_WIDTH-1:0] exp_replaced_addr;
    reg [CORE_WIDTH-1:0] exp_owner;
    integer tests = 0;
    integer errors = 0;
    integer seed = 32'h40d1_2026;
    integer k;

    directory_snoop_filter #(
        .ADDR_WIDTH(ADDR_WIDTH), .LINE_OFFSET(LINE_OFFSET),
        .SETS(SETS), .CORES(CORES)
    ) dut (.*);

    always #5 clk = ~clk;

    function integer model_count;
        integer n;
        begin
            model_count = 0;
            for (n = 0; n < SETS; n = n + 1)
                model_count = model_count + m_valid[n];
        end
    endfunction

    task model_and_drive;
        input [1:0] op;
        input integer core;
        input [ADDR_WIDTH-1:0] addr;
        integer idx;
        reg [TAG_WIDTH-1:0] tag;
        reg [CORES-1:0] bit_mask;
        reg hit;
        begin
            @(negedge clk);
            req_valid = 1'b1;
            req_op = op;
            req_core = core[CORE_WIDTH-1:0];
            req_addr = addr;
            idx = (addr >> LINE_OFFSET) & (SETS - 1);
            tag = addr >> (LINE_OFFSET + INDEX_WIDTH);
            bit_mask = {{(CORES-1){1'b0}}, 1'b1} << core;
            hit = m_valid[idx] && (m_tag[idx] == tag);

            exp_hit = hit;
            exp_snoop = 0;
            exp_replacement = 0;
            exp_replaced_addr = 0;
            exp_post_sharers = 0;
            exp_owner_valid = 0;
            exp_owner = 0;

            case (op)
                READ_SHARED: begin
                    if (hit) begin
                        if (m_owner_valid[idx] && (m_owner[idx] != core))
                            exp_snoop = {{(CORES-1){1'b0}}, 1'b1} << m_owner[idx];
                        m_sharers[idx] = m_sharers[idx] | bit_mask;
                        m_owner_valid[idx] = 0;
                        exp_post_sharers = m_sharers[idx];
                    end else begin
                        if (m_valid[idx]) begin
                            exp_replacement = 1;
                            exp_snoop = m_sharers[idx];
                            exp_replaced_addr = {m_tag[idx], idx[INDEX_WIDTH-1:0],
                                                 {LINE_OFFSET{1'b0}}};
                        end
                        m_valid[idx] = 1;
                        m_tag[idx] = tag;
                        m_sharers[idx] = bit_mask;
                        m_owner_valid[idx] = 0;
                        exp_post_sharers = bit_mask;
                    end
                end
                READ_UNIQUE: begin
                    if (hit)
                        exp_snoop = m_sharers[idx] & ~bit_mask;
                    else if (m_valid[idx]) begin
                        exp_replacement = 1;
                        exp_snoop = m_sharers[idx];
                        exp_replaced_addr = {m_tag[idx], idx[INDEX_WIDTH-1:0],
                                             {LINE_OFFSET{1'b0}}};
                    end
                    m_valid[idx] = 1;
                    m_tag[idx] = tag;
                    m_sharers[idx] = bit_mask;
                    m_owner_valid[idx] = 1;
                    m_owner[idx] = core;
                    exp_post_sharers = bit_mask;
                    exp_owner_valid = 1;
                    exp_owner = core;
                end
                EVICT: begin
                    if (hit && m_sharers[idx][core]) begin
                        m_sharers[idx] = m_sharers[idx] & ~bit_mask;
                        exp_post_sharers = m_sharers[idx];
                        if (m_sharers[idx] == 0)
                            m_valid[idx] = 0;
                        if (m_owner_valid[idx] && (m_owner[idx] == core))
                            m_owner_valid[idx] = 0;
                        else begin
                            exp_owner_valid = m_owner_valid[idx];
                            exp_owner = m_owner[idx];
                        end
                    end
                end
            endcase

            @(posedge clk); #1;
            tests = tests + 1;
            if (!rsp_valid || rsp_hit !== exp_hit || snoop_mask !== exp_snoop ||
                replacement !== exp_replacement || replaced_addr !== exp_replaced_addr ||
                post_sharers !== exp_post_sharers ||
                post_owner_valid !== exp_owner_valid ||
                (exp_owner_valid && post_owner !== exp_owner) ||
                entry_count !== model_count()) begin
                $display("ERROR test=%0d op=%0d core=%0d addr=%h", tests, op, core, addr);
                $display(" got hit=%b snoop=%b repl=%b old=%h sharers=%b owner_v=%b owner=%0d count=%0d",
                         rsp_hit, snoop_mask, replacement, replaced_addr, post_sharers,
                         post_owner_valid, post_owner, entry_count);
                $display(" exp hit=%b snoop=%b repl=%b old=%h sharers=%b owner_v=%b owner=%0d count=%0d",
                         exp_hit, exp_snoop, exp_replacement, exp_replaced_addr,
                         exp_post_sharers, exp_owner_valid, exp_owner, model_count());
                errors = errors + 1;
            end
        end
    endtask

    initial begin
        $dumpfile("directory_snoop_filter.vcd");
        $dumpvars(0, tb_directory_snoop_filter);
        for (k = 0; k < SETS; k = k + 1) begin
            m_valid[k] = 0;
            m_tag[k] = 0;
            m_sharers[k] = 0;
            m_owner_valid[k] = 0;
            m_owner[k] = 0;
        end
        repeat (3) @(posedge clk);
        reset_n = 1'b1;

        // Directed: shared copies, upgrade invalidations, owner downgrade,
        // eviction, and a same-index replacement with targeted snoops.
        model_and_drive(READ_SHARED, 0, 16'h0120);
        model_and_drive(READ_SHARED, 1, 16'h0120);
        model_and_drive(READ_UNIQUE, 2, 16'h0120);
        model_and_drive(READ_SHARED, 3, 16'h0120);
        model_and_drive(EVICT,       2, 16'h0120);
        model_and_drive(EVICT,       3, 16'h0120);
        model_and_drive(READ_UNIQUE, 1, 16'h0220);
        model_and_drive(READ_SHARED, 0, 16'h0320);

        // Random traffic reuses a compact address pool to exercise hits,
        // aliases, upgrades, last-sharer removal, and replacement snoops.
        for (k = 0; k < 700; k = k + 1)
            model_and_drive($urandom(seed) % 3,
                            $urandom(seed) % CORES,
                            (($urandom(seed) % 32) << LINE_OFFSET));

        @(negedge clk);
        req_valid = 0;
        @(posedge clk); #1;
        if (errors == 0)
            $display("RESULT: *** PASS *** (%0d checks)", tests);
        else
            $display("RESULT: *** FAIL *** (%0d errors / %0d checks)", errors, tests);
        $finish;
    end

    initial begin
        #100000;
        $display("RESULT: *** FAIL *** (timeout)");
        $finish;
    end
endmodule
