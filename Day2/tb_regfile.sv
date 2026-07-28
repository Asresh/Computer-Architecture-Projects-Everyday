// -----------------------------------------------------------------------------
// tb_regfile.sv - Self-checking testbench for the RV32I register file
//
// Strategy:
//   * A software golden model (an unpacked array `gold[]`) mirrors the DUT:
//     synchronous writes committed on the rising edge, x0 pinned to zero, and
//     combinational reads with optional same-cycle write-forwarding.
//   * The clock is free-running. Each `do_cycle` applies inputs at a stable
//     point, checks the two combinational read ports BEFORE the rising edge
//     (so forwarding and pre-write state are observed), then lets the write
//     commit on the edge and updates the golden model to match.
//   * Directed stimulus covers reset, basic write/read-back, the x0 hardwire,
//     internal write-forwarding, dual-port reads, and back-to-back overwrite.
//   * Randomized stimulus fuzzes writes and reads across the whole file.
//   * A watchdog timeout guards a hung simulation.
//   * A VCD waveform is dumped for inspection / rendering.
//
// On success the TB prints exactly:  RESULT: *** PASS ***
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps
`default_nettype none

module tb_regfile;

    localparam int unsigned DATA_W      = 32;
    localparam int unsigned ADDR_W      = 5;
    localparam bit          WRITE_FIRST = 1'b1;
    localparam int unsigned NUM_REGS    = (1 << ADDR_W);

    // DUT interface.
    logic                clk = 1'b0;
    logic                rst_n;
    logic                we;
    logic [ADDR_W-1:0]   waddr;
    logic [DATA_W-1:0]   wdata;
    logic [ADDR_W-1:0]   raddr1, raddr2;
    logic [DATA_W-1:0]   rdata1, rdata2;

    // Free-running clock, 10 ns period.
    always #5 clk = ~clk;

    integer errors = 0;
    integer checks = 0;

    // Software golden model of the architectural state.
    logic [DATA_W-1:0] gold [0:NUM_REGS-1];

    regfile #(
        .DATA_W      (DATA_W),
        .ADDR_W      (ADDR_W),
        .WRITE_FIRST (WRITE_FIRST)
    ) dut (
        .clk    (clk),
        .rst_n  (rst_n),
        .we     (we),
        .waddr  (waddr),
        .wdata  (wdata),
        .raddr1 (raddr1),
        .rdata1 (rdata1),
        .raddr2 (raddr2),
        .rdata2 (rdata2)
    );

    // ------------------------------------------------------------------
    // Golden read model: x0 forcing + same-cycle write-forwarding, matching
    // the DUT's read path. Uses the current we/waddr/wdata inputs and the
    // committed golden state.
    // ------------------------------------------------------------------
    function automatic [DATA_W-1:0] read_model(input [ADDR_W-1:0] addr);
        if (addr == '0)
            read_model = '0;
        else if (WRITE_FIRST && we && (waddr != '0) && (addr == waddr))
            read_model = wdata;                    // forwarded write
        else
            read_model = gold[addr];
    endfunction

    // Apply inputs, check both read ports pre-edge, commit the write on the
    // edge, and advance the golden model. `w`, `wa`, `wd` drive the write port;
    // `ra1`, `ra2` drive the two read ports.
    task automatic do_cycle(input               w,
                            input [ADDR_W-1:0]  wa,
                            input [DATA_W-1:0]  wd,
                            input [ADDR_W-1:0]  ra1,
                            input [ADDR_W-1:0]  ra2);
        logic [DATA_W-1:0] exp1, exp2;
        @(negedge clk);            // stable point, well after the last edge
        we     = w;
        waddr  = wa;
        wdata  = wd;
        raddr1 = ra1;
        raddr2 = ra2;
        #1;                        // let combinational reads settle

        exp1 = read_model(ra1);
        exp2 = read_model(ra2);
        checks = checks + 1;
        if (rdata1 !== exp1) begin
            errors = errors + 1;
            $display("[FAIL] rdata1 addr=%0d got=%h exp=%h (we=%b wa=%0d wd=%h)",
                     ra1, rdata1, exp1, w, wa, wd);
        end
        if (rdata2 !== exp2) begin
            errors = errors + 1;
            $display("[FAIL] rdata2 addr=%0d got=%h exp=%h (we=%b wa=%0d wd=%h)",
                     ra2, rdata2, exp2, w, wa, wd);
        end

        @(posedge clk);            // write commits here
        #1;                        // update model to reflect the committed edge
        if (w && (wa != '0))
            gold[wa] = wd;
    endtask

    // Synchronous reset cycle: hold rst_n low across one rising edge. `we` is
    // kept low during reset (reset wins over writes on hardware anyway).
    task automatic reset_cycle();
        integer k;
        @(negedge clk);
        rst_n  = 1'b0;
        we     = 1'b0;
        waddr  = '0;
        wdata  = '0;
        raddr1 = 5'd1;
        raddr2 = 5'd2;
        #1;
        // Before the edge everything checked below is pre-reset; just drive
        // through the edge to clear, then model the clear.
        @(posedge clk);
        #1;
        for (k = 0; k < NUM_REGS; k = k + 1)
            gold[k] = '0;
        rst_n = 1'b1;
    endtask

    integer i;
    logic [ADDR_W-1:0] ra, rb, wr;
    logic [DATA_W-1:0] dw;

    initial begin
        $dumpfile("regfile.vcd");
        $dumpvars(0, tb_regfile);

        we = 1'b0; waddr = '0; wdata = '0; raddr1 = '0; raddr2 = '0;
        rst_n = 1'b1;

        // ---------------- Reset ----------------
        reset_cycle();
        // After reset every register (and x0) must read 0.
        do_cycle(1'b0, 5'd0, 32'h0, 5'd1, 5'd31);   // read x1, x31 -> 0

        // ---------------- Basic write then read-back ----------------
        do_cycle(1'b1, 5'd5, 32'hDEAD_BEEF, 5'd0, 5'd0);   // write x5
        do_cycle(1'b0, 5'd0, 32'h0,         5'd5, 5'd5);   // read x5 both ports

        // ---------------- x0 is hardwired to zero ----------------
        do_cycle(1'b1, 5'd0, 32'hFFFF_FFFF, 5'd0, 5'd0);   // attempt write x0
        do_cycle(1'b0, 5'd0, 32'h0,         5'd0, 5'd5);   // x0->0, x5 intact

        // ---------------- Internal write-forwarding ----------------
        // Same cycle: write x7 while reading x7 on port 1 and x5 on port 2.
        do_cycle(1'b1, 5'd7, 32'h1234_5678, 5'd7, 5'd5);   // port1 forwarded

        // ---------------- Dual independent read ports ----------------
        do_cycle(1'b1, 5'd9,  32'hCAFE_F00D, 5'd0, 5'd0);
        do_cycle(1'b0, 5'd0,  32'h0,         5'd7, 5'd9);   // read x7 & x9

        // ---------------- Back-to-back overwrite ----------------
        do_cycle(1'b1, 5'd5, 32'h0000_0001, 5'd5, 5'd0);   // overwrite x5 (fwd)
        do_cycle(1'b0, 5'd0, 32'h0,         5'd5, 5'd0);   // read new x5

        // ---------------- Randomized fuzz ----------------
        for (i = 0; i < 4000; i = i + 1) begin
            wr = $urandom_range(0, NUM_REGS-1);
            ra = $urandom_range(0, NUM_REGS-1);
            rb = $urandom_range(0, NUM_REGS-1);
            dw = {$random} ^ ($random << 1);
            do_cycle($urandom_range(0, 1), wr, dw, ra, rb);
        end

        // ---------------- Verdict ----------------
        if (errors == 0)
            $display("RESULT: *** PASS *** (%0d checks)", checks);
        else
            $display("RESULT: *** FAIL *** (%0d errors / %0d checks)",
                     errors, checks);

        $finish;
    end

    // Watchdog timeout.
    initial begin
        #5_000_000;
        $display("RESULT: *** FAIL *** (timeout)");
        $finish;
    end

endmodule

`default_nettype wire
