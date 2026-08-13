// -----------------------------------------------------------------------------
// alu.sv - Single-cycle RISC-V (RV32I) integer ALU
//
// A synthesizable, parameterized combinational ALU implementing the integer
// operations needed by the RV32I base ISA. The ALU takes two operands and a
// 4-bit operation select and produces a result plus a zero flag (used by the
// branch-comparison logic in a RISC-V datapath).
//
// Purely combinational: no clock, no reset. Reset-safety is therefore trivial
// (there is no state), and the block is lint-friendly (all outputs driven on
// every path via a default assignment).
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps
`default_nettype none

module alu #(
    parameter int unsigned WIDTH = 32
) (
    input  wire [WIDTH-1:0]  a,        // operand A (e.g. rs1)
    input  wire [WIDTH-1:0]  b,        // operand B (e.g. rs2 or immediate)
    input  wire [3:0]        alu_op,   // operation select (see localparams)
    output reg  [WIDTH-1:0]  result,   // ALU result
    output wire              zero      // 1 when result == 0 (for BEQ/BNE)
);

    // ------------------------------------------------------------------
    // Operation encodings. These mirror a typical RV32I ALU control ROM.
    // ------------------------------------------------------------------
    localparam logic [3:0] OP_ADD  = 4'b0000; // a + b
    localparam logic [3:0] OP_SUB  = 4'b0001; // a - b
    localparam logic [3:0] OP_SLL  = 4'b0010; // a << b[4:0]
    localparam logic [3:0] OP_SLT  = 4'b0011; // signed   (a < b) ? 1 : 0
    localparam logic [3:0] OP_SLTU = 4'b0100; // unsigned (a < b) ? 1 : 0
    localparam logic [3:0] OP_XOR  = 4'b0101; // a ^ b
    localparam logic [3:0] OP_SRL  = 4'b0110; // a >> b[4:0]  (logical)
    localparam logic [3:0] OP_SRA  = 4'b0111; // a >>> b[4:0] (arithmetic)
    localparam logic [3:0] OP_OR   = 4'b1000; // a | b
    localparam logic [3:0] OP_AND  = 4'b1001; // a & b

    // Shift amount is the low log2(WIDTH) bits of operand B, per RISC-V.
    localparam int unsigned SHAMT_W = $clog2(WIDTH);
    wire [SHAMT_W-1:0] shamt = b[SHAMT_W-1:0];

    always_comb begin
        // Default keeps the block fully assigned and avoids latches.
        result = '0;
        unique case (alu_op)
            OP_ADD : result = a + b;
            OP_SUB : result = a - b;
            OP_SLL : result = a << shamt;
            OP_SLT : result = {{(WIDTH-1){1'b0}},
                               ($signed(a) < $signed(b))};
            OP_SLTU: result = {{(WIDTH-1){1'b0}}, (a < b)};
            OP_XOR : result = a ^ b;
            OP_SRL : result = a >> shamt;
            OP_SRA : result = $unsigned($signed(a) >>> shamt);
            OP_OR  : result = a | b;
            OP_AND : result = a & b;
            default: result = '0;
        endcase
    end

    assign zero = (result == '0);

endmodule

`default_nettype wire
