// Author: Asresh Kuricheti
// Self-checking flow:
//   independent write/read clocks -> DUT -> accepted-transfer scoreboard -> PASS
`timescale 1ns/1ps

module tb_async_fifo;
    localparam integer DATA_WIDTH = 16;
    localparam integer DEPTH = 8;
    localparam integer ADDR_WIDTH = $clog2(DEPTH);
    localparam integer PTR_WIDTH = ADDR_WIDTH + 1;
    localparam integer MODEL_SIZE = 4096;

    reg wr_clk = 1'b0;
    reg rd_clk = 1'b0;
    reg wr_reset_n = 1'b0;
    reg rd_reset_n = 1'b0;
    reg wr_en = 1'b0;
    reg [DATA_WIDTH-1:0] wr_data = {DATA_WIDTH{1'b0}};
    reg rd_en = 1'b0;
    wire wr_full;
    wire [PTR_WIDTH-1:0] wr_level;
    wire [DATA_WIDTH-1:0] rd_data;
    wire rd_valid;
    wire rd_empty;
    wire [PTR_WIDTH-1:0] rd_level;

    reg [DATA_WIDTH-1:0] model_mem [0:MODEL_SIZE-1];
    integer model_head = 0;
    integer model_tail = 0;
    integer model_count = 0;
    integer accepted_writes = 0;
    integer checked_reads = 0;
    integer checks = 0;
    integer errors = 0;
    integer index;
    reg [31:0] wr_lfsr = 32'h41c0_ffee;
    reg [31:0] rd_lfsr = 32'hace1_2026;
    reg [DATA_WIDTH-1:0] expected_read;

    async_fifo #(
        .DATA_WIDTH(DATA_WIDTH),
        .DEPTH(DEPTH)
    ) dut (
        .wr_clk(wr_clk), .wr_reset_n(wr_reset_n),
        .wr_en(wr_en), .wr_data(wr_data),
        .wr_full(wr_full), .wr_level(wr_level),
        .rd_clk(rd_clk), .rd_reset_n(rd_reset_n),
        .rd_en(rd_en), .rd_data(rd_data), .rd_valid(rd_valid),
        .rd_empty(rd_empty), .rd_level(rd_level)
    );

    always #5 wr_clk = ~wr_clk;
    initial begin
        #2;
        forever #7 rd_clk = ~rd_clk;
    end

    task record_error;
        input [8*96-1:0] message;
        begin
            errors = errors + 1;
            $display("ERROR @ %0t: %0s", $time, message);
        end
    endtask

    task push_word;
        input [DATA_WIDTH-1:0] value;
        begin
            while (wr_full)
                @(negedge wr_clk);
            @(negedge wr_clk);
            wr_data = value;
            wr_en = 1'b1;
            @(negedge wr_clk);
            wr_en = 1'b0;
        end
    endtask

    task pop_word;
        begin
            while (rd_empty)
                @(negedge rd_clk);
            @(negedge rd_clk);
            rd_en = 1'b1;
            @(negedge rd_clk);
            rd_en = 1'b0;
        end
    endtask

    // Golden producer: only accepted writes enter the reference FIFO.
    always @(posedge wr_clk) begin
        if (wr_reset_n) begin
            if (wr_en && !wr_full) begin
                model_mem[model_tail] = wr_data;
                model_tail = (model_tail + 1) % MODEL_SIZE;
                model_count = model_count + 1;
                accepted_writes = accepted_writes + 1;
                checks = checks + 1;
                if (model_count > DEPTH)
                    record_error("accepted write overflowed reference FIFO");
            end
            if (wr_level > DEPTH)
                record_error("write-domain occupancy exceeded DEPTH");
        end
    end

    // Golden consumer: sample the expected head on acceptance, then compare
    // after the DUT's nonblocking read-data update has settled.
    always @(posedge rd_clk) begin
        if (rd_reset_n && rd_en && !rd_empty) begin
            if (model_count <= 0) begin
                record_error("DUT accepted read while reference FIFO was empty");
            end else begin
                expected_read = model_mem[model_head];
                model_head = (model_head + 1) % MODEL_SIZE;
                model_count = model_count - 1;
                @(negedge rd_clk);
                checks = checks + 1;
                checked_reads = checked_reads + 1;
                if (!rd_valid)
                    record_error("accepted read did not assert rd_valid");
                if (rd_data !== expected_read) begin
                    errors = errors + 1;
                    $display("ERROR @ %0t: read got %h expected %h",
                             $time, rd_data, expected_read);
                end
            end
        end else if (rd_reset_n) begin
            @(negedge rd_clk);
            checks = checks + 1;
            if (rd_valid)
                record_error("rd_valid asserted without an accepted read");
            if (rd_level > DEPTH)
                record_error("read-domain occupancy exceeded DEPTH");
        end
    end

    initial begin : timeout_guard
        #200000;
        $display("RESULT: *** FAIL *** timeout");
        $finish;
    end

    initial begin : stimulus
        $dumpfile("async_fifo.vcd");
        $dumpvars(0, tb_async_fifo);

        repeat (4) @(negedge wr_clk);
        wr_reset_n = 1'b1;
        rd_reset_n = 1'b1;

        repeat (3) @(posedge wr_clk);
        checks = checks + 2;
        if (wr_full)
            record_error("FIFO reported full after reset");
        if (!rd_empty)
            record_error("FIFO did not report empty after reset");

        // Directed fill, rejected overflow attempt, and ordered drain.
        for (index = 0; index < DEPTH; index = index + 1)
            push_word(16'h1000 + index);
        @(negedge wr_clk);
        checks = checks + 1;
        if (!wr_full)
            record_error("FIFO did not become full after DEPTH writes");

        wr_data = 16'hdead;
        wr_en = 1'b1;
        @(negedge wr_clk);
        wr_en = 1'b0;
        checks = checks + 1;
        if (model_count != DEPTH)
            record_error("full FIFO accepted an overflow write");

        for (index = 0; index < DEPTH; index = index + 1)
            pop_word();
        repeat (2) @(negedge rd_clk);
        checks = checks + 1;
        if (!rd_empty)
            record_error("FIFO did not become empty after drain");

        // Concurrent randomized clocks create unrelated CDC phase crossings.
        fork
            begin : random_writer
                for (index = 0; index < 700; index = index + 1) begin
                    @(negedge wr_clk);
                    wr_lfsr = {wr_lfsr[30:0],
                               wr_lfsr[31] ^ wr_lfsr[21] ^ wr_lfsr[1] ^ wr_lfsr[0]};
                    wr_en = wr_lfsr[0] | wr_lfsr[4];
                    wr_data = wr_lfsr[DATA_WIDTH-1:0] ^ accepted_writes;
                end
                @(negedge wr_clk);
                wr_en = 1'b0;
            end
            begin : random_reader
                repeat (520) begin
                    @(negedge rd_clk);
                    rd_lfsr = {rd_lfsr[30:0],
                               rd_lfsr[31] ^ rd_lfsr[6] ^ rd_lfsr[4] ^ rd_lfsr[2]};
                    rd_en = rd_lfsr[0] | rd_lfsr[3];
                end
                @(negedge rd_clk);
                rd_en = 1'b0;
            end
        join

        while (model_count > 0)
            pop_word();
        repeat (4) @(negedge rd_clk);

        checks = checks + 3;
        if (!rd_empty)
            record_error("FIFO was not empty after randomized drain");
        if (accepted_writes != checked_reads)
            record_error("accepted write/read totals did not match");
        if (model_count != 0)
            record_error("reference FIFO retained data after drain");

        $display("Completed %0d checks (%0d writes, %0d ordered reads).",
                 checks, accepted_writes, checked_reads);
        if (errors == 0)
            $display("RESULT: *** PASS ***");
        else
            $display("RESULT: *** FAIL *** (%0d errors)", errors);
        $finish;
    end
endmodule
