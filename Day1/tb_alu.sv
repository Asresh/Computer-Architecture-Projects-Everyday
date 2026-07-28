// -----------------------------------------------------------------------------
// tb_alu.sv - Self-checking testbench for the single-cycle RISC-V ALU
//
// Strategy:
//   * A pure-software golden reference model (golden()) recomputes the expected
//     result for every (a, b, op) triple.
//   * Directed stimulus exercises corner cases: zero, all-ones, signed/unsigned
//     boundaries, overflow wrap, shift by 0 and by WIDTH-1, arithmetic vs.
//     logical shift of a negative number.
//   * Randomized stimulus fuzzes all 10 operations with random operands.
//   * A watchdog timeout guards against a hung simulation.
//   * A VCD waveform is dumped for inspection / rendering.
//
// On success the TB prints exactly:  RESULT: *** PASS ***
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps
`default_nettype none

module tb_alu;

    localparam int unsigned WIDTH = 32;

    // Mirror the DUT's operation encodings.
    localparam logic [3:0] OP_ADD  = 4'b0000;
    localparam logic [3:0] OP_SUB  = 4'b0001;
    localparam logic [3:0] OP_SLL  = 4'b0010;
    localparam logic [3:0] OP_SLT  = 4'b0011;
    localparam logic [3:0] OP_SLTU = 4'b0100;
    localparam logic [3:0] OP_XOR  = 4'b0101;
    localparam logic [3:0] OP_SRL  = 4'b0110;
    localparam logic [3:0] OP_SRA  = 4'b0111;
    localparam logic [3:0] OP_OR   = 4'b1000;
    localparam logic [3:0] OP_AND  = 4'b1001;

    // DUT interface.
    logic [WIDTH-1:0] a, b;
    logic [3:0]       alu_op;
    logic [WIDTH-1:0] result;
    logic             zero;

    // A free-running clock is not required by the combinational DUT, but we
    // drive one so the VCD has a recognizable time base for the waveform image.
    logic clk = 1'b0;
    always #5 clk = ~clk;

    integer errors = 0;
    integer checks = 0;

    alu #(.WIDTH(WIDTH)) dut (
        .a      (a),
        .b      (b),
        .alu_op (alu_op),
        .result (result),
        .zero   (zero)
    );

    // ------------------------------------------------------------------
    // Golden reference model.
    // ------------------------------------------------------------------
    function automatic [WIDTH-1:0] golden(input [WIDTH-1:0] ga,
                                          input [WIDTH-1:0] gb,
                                          input [3:0]       gop);
        logic [$clog2(WIDTH)-1:0] sh;
        sh = gb[$clog2(WIDTH)-1:0];
        case (gop)
            OP_ADD : golden = ga + gb;
            OP_SUB : golden = ga - gb;
            OP_SLL : golden = ga << sh;
            OP_SLT : golden = {{(WIDTH-1){1'b0}}, ($signed(ga) < $signed(gb))};
            OP_SLTU: golden = {{(WIDTH-1){1'b0}}, (ga < gb)};
            OP_XOR : golden = ga ^ gb;
            OP_SRL : golden = ga >> sh;
            OP_SRA : golden = $unsigned($signed(ga) >>> sh);
            OP_OR  : golden = ga | gb;
            OP_AND : golden = ga & gb;
            default: golden = '0;
        endcase
    endfunction

    // Apply one vector, settle combinational logic, and check.
    task automatic check(input [WIDTH-1:0] ta,
                         input [WIDTH-1:0] tb,
                         input [3:0]       top);
        logic [WIDTH-1:0] exp;
        a      = ta;
        b      = tb;
        alu_op = top;
        #1;                       // let combinational logic settle
        exp = golden(ta, tb, top);
        checks = checks + 1;
        if (result !== exp) begin
            errors = errors + 1;
            $display("[FAIL] op=%b a=%h b=%h  got=%h exp=%h",
                     top, ta, tb, result, exp);
        end
        // Independently validate the zero flag.
        if (zero !== (exp == '0)) begin
            errors = errors + 1;
            $display("[FAIL] zero flag op=%b a=%h b=%h got=%b exp=%b",
                     top, ta, tb, zero, (exp == '0));
        end
        #1;
    endtask

    integer i;
    logic [3:0] ops [0:9];

    initial begin
        $dumpfile("alu.vcd");
        $dumpvars(0, tb_alu);

        ops[0]=OP_ADD; ops[1]=OP_SUB; ops[2]=OP_SLL; ops[3]=OP_SLT;
        ops[4]=OP_SLTU; ops[5]=OP_XOR; ops[6]=OP_SRL; ops[7]=OP_SRA;
        ops[8]=OP_OR;  ops[9]=OP_AND;

        a = '0; b = '0; alu_op = OP_ADD;

        // ---------------- Directed corner cases ----------------
        check(32'd0,          32'd0,          OP_ADD);  // zero result -> zero flag
        check(32'hFFFF_FFFF,  32'h0000_0001,  OP_ADD);  // overflow wrap to 0
        check(32'd7,          32'd7,          OP_SUB);  // equal -> zero (BEQ)
        check(32'd5,          32'd9,          OP_SUB);  // negative result
        check(32'hFFFF_FFFF,  32'd1,          OP_SLTU); // large unsigned
        check(32'hFFFF_FFFF,  32'd1,          OP_SLT);  // -1 <  1 signed
        check(32'd1,          32'hFFFF_FFFF,  OP_SLT);  //  1 < -1 signed = 0
        check(32'h0000_0001,  32'd31,         OP_SLL);  // shift into MSB
        check(32'h8000_0000,  32'd0,          OP_SLL);  // shift by zero
        check(32'h8000_0000,  32'd4,          OP_SRL);  // logical  shift, MSB set
        check(32'h8000_0000,  32'd4,          OP_SRA);  // arith    shift, sign-extend
        check(32'hF0F0_F0F0,  32'h0F0F_0F0F,  OP_XOR);  // full toggle
        check(32'hF0F0_F0F0,  32'h0F0F_0F0F,  OP_OR);   // all-ones
        check(32'hF0F0_F0F0,  32'h0F0F_0F0F,  OP_AND);  // zero via AND

        // ---------------- Randomized fuzz ----------------
        for (i = 0; i < 2000; i = i + 1)
            check($random, $random, ops[$urandom_range(0, 9)]);

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
        #2_000_000;
        $display("RESULT: *** FAIL *** (timeout)");
        $finish;
    end

endmodule

`default_nettype wire
