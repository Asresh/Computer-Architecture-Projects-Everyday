// -----------------------------------------------------------------------------
// tb_lsu.sv - Self-checking testbench for the RV32I load/store unit + data mem
//
// Strategy:
//   * An independent software golden model stores memory as a flat little-endian
//     BYTE array (gmem[]) -- deliberately a different implementation from the
//     DUT's word + byte-lane storage, so a shared bug is unlikely to hide.
//   * read_model() reproduces the DUT's load semantics (lane/half selection,
//     sign vs. zero extension, and the within-word misalignment policy);
//     apply_store_gold() reproduces the store semantics (per-byte lanes).
//   * do_store applies a store and commits it on the rising edge, then advances
//     the golden model; do_load drives a load, checks rdata combinationally
//     against the model, and advances a clock. Reads see committed stores.
//   * Directed stimulus covers: a store-then-load showcase at the same and
//     adjacent addresses (the waveform), every funct3, every byte offset within
//     a word, sign- vs. zero-extension corners, and the documented misalignment
//     policy for halfwords and words.
//   * Randomized stimulus fuzzes 350 store+load pairs across the memory.
//   * A watchdog timeout guards a hung simulation.
//   * A VCD waveform is dumped for inspection / rendering.
//
// On success the TB prints exactly:  RESULT: *** PASS ***
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps
`default_nettype none

module tb_lsu;

    localparam int unsigned DATA_W = 32;
    localparam int unsigned WORDS  = 256;
    localparam int unsigned IDXW   = $clog2(WORDS);
    localparam int unsigned NBYTES = WORDS * 4;

    localparam logic [2:0] F3_B  = 3'b000, F3_H  = 3'b001, F3_W = 3'b010,
                           F3_BU = 3'b100, F3_HU = 3'b101;

    // DUT interface.
    logic              clk = 1'b0;
    logic              rst_n;
    logic              mem_read;
    logic              mem_write;
    logic [2:0]        funct3;
    logic [31:0]       addr;
    logic [DATA_W-1:0] wdata;
    logic [DATA_W-1:0] rdata;

    // Free-running clock, 10 ns period.
    always #5 clk = ~clk;

    integer errors = 0;
    integer checks = 0;

    // Independent golden model: flat little-endian byte array.
    logic [7:0] gmem [0:NBYTES-1];

    lsu #(.DATA_W(DATA_W), .WORDS(WORDS)) dut (
        .clk       (clk),
        .rst_n     (rst_n),
        .mem_read  (mem_read),
        .mem_write (mem_write),
        .funct3    (funct3),
        .addr      (addr),
        .wdata     (wdata),
        .rdata     (rdata)
    );

    // ------------------------------------------------------------------
    // Golden load model: mirrors the DUT's lane/half selection, extension,
    // and within-word misalignment policy, but from the byte array.
    // ------------------------------------------------------------------
    function automatic [31:0] read_model(input [2:0] f3, input [31:0] a);
        logic [IDXW-1:0] wi;
        logic [1:0]      o;
        integer          base;
        logic [7:0]      b0, b1, b2, b3, bl;
        logic [15:0]     hl;
        wi   = a[IDXW+1:2];
        o    = a[1:0];
        base = wi * 4;
        b0 = gmem[base+0]; b1 = gmem[base+1];
        b2 = gmem[base+2]; b3 = gmem[base+3];
        case (o)
            2'd0:    bl = b0;
            2'd1:    bl = b1;
            2'd2:    bl = b2;
            default: bl = b3;
        endcase
        hl = o[1] ? {b3, b2} : {b1, b0};
        case (f3)
            F3_B   : read_model = {{24{bl[7]}},  bl};
            F3_BU  : read_model = {24'b0,        bl};
            F3_H   : read_model = {{16{hl[15]}}, hl};
            F3_HU  : read_model = {16'b0,        hl};
            F3_W   : read_model = {b3, b2, b1, b0};
            default: read_model = {b3, b2, b1, b0};
        endcase
    endfunction

    // Golden store: per-byte lanes into the byte array.
    task automatic apply_store_gold(input [2:0] f3, input [31:0] a,
                                    input [31:0] wd);
        logic [IDXW-1:0] wi;
        logic [1:0]      o;
        integer          base;
        wi   = a[IDXW+1:2];
        o    = a[1:0];
        base = wi * 4;
        case (f3)
            F3_B: gmem[base + o] = wd[7:0];
            F3_H: begin
                if (o[1] == 1'b0) begin
                    gmem[base+0] = wd[7:0];  gmem[base+1] = wd[15:8];
                end else begin
                    gmem[base+2] = wd[7:0];  gmem[base+3] = wd[15:8];
                end
            end
            F3_W: begin
                gmem[base+0] = wd[7:0];   gmem[base+1] = wd[15:8];
                gmem[base+2] = wd[23:16]; gmem[base+3] = wd[31:24];
            end
            default: ; // no store-unsigned variants
        endcase
    endtask

    // ------------------------------------------------------------------
    // Cycle drivers.
    // ------------------------------------------------------------------
    task automatic do_load(input [2:0] f3, input [31:0] a);
        logic [31:0] exp;
        @(negedge clk);
        mem_read  = 1'b1;
        mem_write = 1'b0;
        funct3    = f3;
        addr      = a;
        wdata     = 32'h0;
        #1;                              // settle combinational read
        exp = read_model(f3, a);
        checks = checks + 1;
        if (rdata !== exp) begin
            errors = errors + 1;
            $display("[FAIL] load f3=%b addr=%0d got=%h exp=%h",
                     f3, a, rdata, exp);
        end
        @(posedge clk);
        #1;
        mem_read = 1'b0;
    endtask

    task automatic do_store(input [2:0] f3, input [31:0] a, input [31:0] wd);
        @(negedge clk);
        mem_read  = 1'b0;
        mem_write = 1'b1;
        funct3    = f3;
        addr      = a;
        wdata     = wd;
        #1;                              // settle be / wlane
        @(posedge clk);                  // store commits here
        #1;
        apply_store_gold(f3, a, wd);     // advance golden to match
        mem_write = 1'b0;
    endtask

    task automatic reset_cycle();
        integer k;
        @(negedge clk);
        rst_n     = 1'b0;
        mem_read  = 1'b0;
        mem_write = 1'b0;
        funct3    = F3_W;
        addr      = 32'h0;
        wdata     = 32'h0;
        #1;
        @(posedge clk);                  // memory clears here
        #1;
        for (k = 0; k < NBYTES; k = k + 1)
            gmem[k] = 8'h0;
        rst_n = 1'b1;
    endtask

    integer i;
    logic [2:0]  rf3;
    logic [31:0] ra, rd;
    logic [2:0]  ldf3 [0:4];
    logic [2:0]  stf3 [0:2];

    initial begin
        $dumpfile("lsu.vcd");
        $dumpvars(0, tb_lsu);

        mem_read = 1'b0; mem_write = 1'b0; funct3 = F3_W;
        addr = 32'h0; wdata = 32'h0; rst_n = 1'b1;

        ldf3[0]=F3_B; ldf3[1]=F3_H; ldf3[2]=F3_W; ldf3[3]=F3_BU; ldf3[4]=F3_HU;
        stf3[0]=F3_B; stf3[1]=F3_H; stf3[2]=F3_W;

        // ---------------- Reset ----------------
        reset_cycle();
        do_load(F3_W, 32'd0);            // cleared memory reads 0

        // ---------------- Store-then-load showcase (drives the waveform) ----
        do_store(F3_W, 32'd16, 32'hDEAD_BEEF); // sw   [16] = DEADBEEF
        do_load (F3_W,  32'd16);               // lw   [16] -> DEADBEEF
        do_load (F3_B,  32'd16);               // lb   [16] -> FFFFFFEF (sext)
        do_load (F3_BU, 32'd16);               // lbu  [16] -> 000000EF
        do_load (F3_B,  32'd17);               // lb   [17] -> FFFFFFBE (adjacent)
        do_load (F3_H,  32'd16);               // lh   [16] -> FFFFBEEF (sext)
        do_load (F3_HU, 32'd18);               // lhu  [18] -> 0000DEAD (high half)

        // ---------------- Every byte offset within a word (lb/lbu) ----------
        do_store(F3_W, 32'd0, 32'h0302_0100);  // bytes 00 01 02 03
        do_load (F3_B,  32'd0); do_load(F3_B,  32'd1);
        do_load (F3_B,  32'd2); do_load(F3_B,  32'd3);
        do_load (F3_BU, 32'd0); do_load(F3_BU, 32'd1);
        do_load (F3_BU, 32'd2); do_load(F3_BU, 32'd3);

        // ---------------- Sign vs. zero extension corners -------------------
        do_store(F3_W, 32'd4, 32'hFFEE_DDCC);  // bytes CC DD EE FF
        do_load (F3_B,  32'd4);  do_load(F3_BU, 32'd4);   // FFFFFFCC / 000000CC
        do_load (F3_B,  32'd7);  do_load(F3_BU, 32'd7);   // FFFFFFFF / 000000FF
        do_load (F3_H,  32'd4);  do_load(F3_HU, 32'd4);   // FFFFDDCC / 0000DDCC
        do_load (F3_H,  32'd6);  do_load(F3_HU, 32'd6);   // FFFFFFEE / 0000FFEE
        do_load (F3_W,  32'd4);                           // FFEEDDCC

        // ---------------- Misalignment policy (no boundary crossing) --------
        do_load (F3_H, 32'd5);   // off=1 -> low half  == lh[4]  (FFFFDDCC)
        do_load (F3_H, 32'd7);   // off=3 -> high half == lh[6]  (FFFFFFEE)
        do_load (F3_W, 32'd5);   // off!=0 -> whole word[4]      (FFEEDDCC)
        do_load (F3_W, 32'd6);
        do_load (F3_W, 32'd7);

        // ---------------- Store byte to every offset, verify via lbu --------
        do_store(F3_W, 32'd8, 32'h0000_0000);
        do_store(F3_B, 32'd8,  32'h0000_00A0); do_load(F3_BU, 32'd8);
        do_store(F3_B, 32'd9,  32'h0000_00A1); do_load(F3_BU, 32'd9);
        do_store(F3_B, 32'd10, 32'h0000_00A2); do_load(F3_BU, 32'd10);
        do_store(F3_B, 32'd11, 32'h0000_00A3); do_load(F3_BU, 32'd11);
        do_load (F3_W, 32'd8);                 // A3A2A1A0

        // ---------------- Store half (aligned + policy-misaligned) ----------
        do_store(F3_W, 32'd12, 32'h0000_0000);
        do_store(F3_H, 32'd12, 32'h0000_1234); do_load(F3_HU, 32'd12); // low
        do_store(F3_H, 32'd14, 32'h0000_5678); do_load(F3_HU, 32'd14); // high
        do_load (F3_W, 32'd12);                                        // 56781234
        do_store(F3_H, 32'd13, 32'h0000_ABCD); do_load(F3_HU, 32'd12); // off1->low
        do_store(F3_H, 32'd15, 32'h0000_EF01); do_load(F3_HU, 32'd14); // off3->high
        do_load (F3_W, 32'd12);                                        // EF01ABCD

        // ---------------- Randomized fuzz: 350 store+load pairs -------------
        for (i = 0; i < 350; i = i + 1) begin
            rf3 = stf3[$urandom_range(0, 2)];
            ra  = {$urandom_range(0, WORDS-1), 2'b00} | $urandom_range(0, 3);
            rd  = {$random} ^ ($random << 1);
            do_store(rf3, ra, rd);
            ra  = {$urandom_range(0, WORDS-1), 2'b00} | $urandom_range(0, 3);
            do_load(ldf3[$urandom_range(0, 4)], ra);
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
