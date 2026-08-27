// Author: Asresh Kuricheti
//
// Self-checking environment with an independent byte-addressed memory model.
// Directed and randomized commands are checked against a golden copy model.
//
//   stimulus -> DUT -> read/write memory model
//       |                      |
//       +---- golden model ----+--> compare + protocol checks

`timescale 1ns/1ps

module tb_burst_dma_engine;
    localparam int ADDR_WIDTH = 12;
    localparam int DATA_WIDTH = 32;
    localparam int LEN_WIDTH  = 6;
    localparam int WORDS      = 1 << (ADDR_WIDTH - 2);
    localparam int MAX_TEST_CYCLES = 50000;

    logic clk = 1'b0;
    logic rst_n = 1'b0;
    logic cmd_valid;
    logic cmd_ready;
    logic [ADDR_WIDTH-1:0] cmd_src_addr, cmd_dst_addr;
    logic [LEN_WIDTH-1:0] cmd_length;
    logic busy, done;
    logic read_req_valid, read_req_ready;
    logic [ADDR_WIDTH-1:0] read_req_addr;
    logic read_rsp_valid;
    logic [DATA_WIDTH-1:0] read_rsp_data;
    logic write_req_valid, write_req_ready;
    logic [ADDR_WIDTH-1:0] write_req_addr;
    logic [DATA_WIDTH-1:0] write_req_data;

    logic [DATA_WIDTH-1:0] memory [0:WORDS-1];
    logic [DATA_WIDTH-1:0] golden [0:WORDS-1];
    logic read_pending;
    logic [DATA_WIDTH-1:0] pending_read_data;
    integer read_delay;
    integer checks;
    integer cycle_count;
    integer seed;
    integer i;
    logic previous_read_stall;
    logic previous_write_stall;
    logic [ADDR_WIDTH-1:0] previous_read_addr;
    logic [ADDR_WIDTH-1:0] previous_write_addr;
    logic [DATA_WIDTH-1:0] previous_write_data;

    burst_dma_engine #(
        .ADDR_WIDTH(ADDR_WIDTH),
        .DATA_WIDTH(DATA_WIDTH),
        .LEN_WIDTH(LEN_WIDTH)
    ) dut (.*);

    always #5 clk = ~clk;

    // Backpressured memory with variable read latency.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            read_req_ready   <= 1'b0;
            write_req_ready  <= 1'b0;
            read_rsp_valid   <= 1'b0;
            read_rsp_data    <= '0;
            read_pending     <= 1'b0;
            pending_read_data <= '0;
            read_delay       <= 0;
        end else begin
            read_req_ready  <= ($urandom_range(0, 3) != 0);
            write_req_ready <= ($urandom_range(0, 2) != 0);
            read_rsp_valid  <= 1'b0;

            if (read_req_valid && read_req_ready) begin
                if (read_pending) $fatal(1, "DUT issued more than one read");
                if (read_req_addr[1:0] != 2'b00) $fatal(1, "unaligned read");
                pending_read_data <= memory[read_req_addr >> 2];
                read_delay        <= $urandom_range(0, 3);
                read_pending      <= 1'b1;
                checks            <= checks + 1;
            end

            if (read_pending) begin
                if (read_delay == 0) begin
                    read_rsp_valid <= 1'b1;
                    read_rsp_data  <= pending_read_data;
                    read_pending   <= 1'b0;
                end else begin
                    read_delay <= read_delay - 1;
                end
            end

            if (write_req_valid && write_req_ready) begin
                if (write_req_addr[1:0] != 2'b00) $fatal(1, "unaligned write");
                memory[write_req_addr >> 2] <= write_req_data;
                checks <= checks + 1;
            end
        end
    end

    // Portable ready/valid stability monitors (procedural SVA equivalent).
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            previous_read_stall  <= 1'b0;
            previous_write_stall <= 1'b0;
            previous_read_addr   <= '0;
            previous_write_addr  <= '0;
            previous_write_data  <= '0;
        end else begin
            if (previous_read_stall &&
                (!read_req_valid || read_req_addr != previous_read_addr))
                $fatal(1, "read request changed while stalled");
            if (previous_write_stall &&
                (!write_req_valid || write_req_addr != previous_write_addr ||
                 write_req_data != previous_write_data))
                $fatal(1, "write request changed while stalled");

            previous_read_stall  <= read_req_valid && !read_req_ready;
            previous_write_stall <= write_req_valid && !write_req_ready;
            previous_read_addr   <= read_req_addr;
            previous_write_addr  <= write_req_addr;
            previous_write_data  <= write_req_data;

            cycle_count <= cycle_count + 1;
            if (cycle_count > MAX_TEST_CYCLES) $fatal(1, "TIMEOUT");
            if (busy && cmd_ready) $fatal(1, "cmd_ready asserted while busy");
        end
    end

    task automatic run_copy(input integer src_word,
                            input integer dst_word,
                            input integer length);
        integer j;
        integer wait_cycles;
        begin
            for (j = 0; j < WORDS; j = j + 1) golden[j] = memory[j];
            for (j = 0; j < length; j = j + 1)
                golden[dst_word + j] = memory[src_word + j];

            @(negedge clk);
            cmd_src_addr = src_word << 2;
            cmd_dst_addr = dst_word << 2;
            cmd_length   = length;
            cmd_valid    = 1'b1;
            while (!cmd_ready) @(negedge clk);
            @(negedge clk);
            cmd_valid = 1'b0;

            wait_cycles = 0;
            while (!done) begin
                @(posedge clk);
                wait_cycles = wait_cycles + 1;
                if (wait_cycles > 2000) $fatal(1, "command timeout");
            end
            @(negedge clk);

            for (j = 0; j < WORDS; j = j + 1) begin
                if (memory[j] !== golden[j]) begin
                    $display("Mismatch word %0d: got %08x expected %08x",
                             j, memory[j], golden[j]);
                    $fatal(1, "golden memory mismatch");
                end
                checks = checks + 1;
            end
        end
    endtask

    initial begin
        $dumpfile("burst_dma_engine.vcd");
        $dumpvars(0, tb_burst_dma_engine);
        cmd_valid = 1'b0;
        cmd_src_addr = '0;
        cmd_dst_addr = '0;
        cmd_length = '0;
        checks = 0;
        cycle_count = 0;
        seed = 32'h42D0_A5A5;
        seed = $urandom(seed);
        for (i = 0; i < WORDS; i = i + 1)
            memory[i] = 32'hA500_0000 ^ (i * 32'h0001_0201);

        repeat (4) @(posedge clk);
        rst_n = 1'b1;
        repeat (2) @(posedge clk);

        // Directed: no-op, single beat, short burst, and maximum test burst.
        run_copy(8,   128, 0);
        run_copy(4,   200, 1);
        run_copy(16,  256, 7);
        run_copy(300, 500, 31);

        // Random non-overlapping transfers with variable memory backpressure.
        for (i = 0; i < 60; i = i + 1)
            run_copy($urandom_range(0, 199),
                     $urandom_range(600, 900),
                     $urandom_range(1, 24));

        $display("Checks completed: %0d", checks);
        $display("RESULT: *** PASS ***");
        $finish;
    end

endmodule
