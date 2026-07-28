// -----------------------------------------------------------------------------
// imem.sv - Instruction memory (ROM) for the single-cycle RV32I core
//
// A word-addressable, combinational-read instruction ROM preloaded with the
// Day 5 directed program. The program is a hand-written RV32I routine that was
// assembled by an independent Python assembler/ISS (see the README) which also
// produced the golden final architectural state the testbench checks against.
//
// The program (word index : disassembly) exercises the whole integer subset:
//   00 lui   x1,0x12345         01 addi  x1,x1,0x678
//   02 auipc x2,0x10            03 addi  x3,x0,100
//   04 addi  x4,x0,-50          05 add   x5,x3,x4
//   06 sub   x6,x3,x4           07 and   x7,x1,x3
//   08 or    x8,x3,x4           09 xor   x9,x3,x4
//   0A sll   x10,x3,x0          0B srl   x11,x1,x0
//   0C sra   x12,x4,x0          0D slt   x13,x4,x3
//   0E sltu  x14,x4,x3          0F slti  x15,x4,0
//   10 sltiu x16,x3,0x7FF       11 xori  x17,x3,-1
//   12 ori   x18,x3,0xF0        13 andi  x19,x1,0x7FF
//   14 slli  x20,x3,5           15 srli  x21,x1,12
//   16 srai  x22,x4,2           17 sw    x1,0(x0)
//   18 lw    x23,0(x0)          19 lbu   x24,0(x0)
//   1A lb    x25,3(x0)          1B sh    x3,8(x0)
//   1C lhu   x26,8(x0)          1D sb    x4,13(x0)
//   1E lbu   x27,13(x0)         1F addi  x28,x0,0
//   20 addi  x29,x0,1           21 addi  x30,x0,6
//   22 add   x28,x28,x29        23 addi  x29,x29,1        (loop body)
//   24 blt   x29,x30,loop(0x88) 25 beq   x29,x30,skip1
//   26 addi  x28,x0,999 (skip)  27 bne   x0,x0,skip2
//   28 addi  x31,x0,7           29 bge   x30,x29,skip3
//   2A addi  x31,x0,888 (skip)  2B bltu  x0,x30,skip4
//   2C addi  x31,x0,777 (skip)  2D bgeu  x30,x0,skip5
//   2E addi  x31,x0,666 (skip)  2F jal   x5,func(0xC8)
//   30 sw    x28,16(x0)         31 jal   x0,halt(0xC4)   (spin)
//   32 addi  x6,x0,42 (func)    33 jalr  x0,0(x5)        (return)
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps
`default_nettype none

module imem #(
    parameter int unsigned WORDS = 64             // ROM depth in 32-bit words
) (
    input  wire [31:0] addr,                      // byte address (the PC)
    output wire [31:0] instr                      // fetched instruction word
);

    localparam int unsigned IDXW = $clog2(WORDS);

    reg [31:0] rom [0:WORDS-1];

    integer i;
    initial begin
        for (i = 0; i < WORDS; i = i + 1)
            rom[i] = 32'h0000_0000;               // unused slots read as 0

        rom[ 0] = 32'h123450B7;   // 0x00  lui   x1,0x12345
        rom[ 1] = 32'h67808093;   // 0x04  addi  x1,x1,0x678
        rom[ 2] = 32'h00010117;   // 0x08  auipc x2,0x10
        rom[ 3] = 32'h06400193;   // 0x0C  addi  x3,x0,100
        rom[ 4] = 32'hFCE00213;   // 0x10  addi  x4,x0,-50
        rom[ 5] = 32'h004182B3;   // 0x14  add   x5,x3,x4
        rom[ 6] = 32'h40418333;   // 0x18  sub   x6,x3,x4
        rom[ 7] = 32'h0030F3B3;   // 0x1C  and   x7,x1,x3
        rom[ 8] = 32'h0041E433;   // 0x20  or    x8,x3,x4
        rom[ 9] = 32'h0041C4B3;   // 0x24  xor   x9,x3,x4
        rom[10] = 32'h00019533;   // 0x28  sll   x10,x3,x0
        rom[11] = 32'h0000D5B3;   // 0x2C  srl   x11,x1,x0
        rom[12] = 32'h40025633;   // 0x30  sra   x12,x4,x0
        rom[13] = 32'h003226B3;   // 0x34  slt   x13,x4,x3
        rom[14] = 32'h00323733;   // 0x38  sltu  x14,x4,x3
        rom[15] = 32'h00022793;   // 0x3C  slti  x15,x4,0
        rom[16] = 32'h7FF1B813;   // 0x40  sltiu x16,x3,0x7FF
        rom[17] = 32'hFFF1C893;   // 0x44  xori  x17,x3,-1
        rom[18] = 32'h0F01E913;   // 0x48  ori   x18,x3,0xF0
        rom[19] = 32'h7FF0F993;   // 0x4C  andi  x19,x1,0x7FF
        rom[20] = 32'h00519A13;   // 0x50  slli  x20,x3,5
        rom[21] = 32'h00C0DA93;   // 0x54  srli  x21,x1,12
        rom[22] = 32'h40225B13;   // 0x58  srai  x22,x4,2
        rom[23] = 32'h00102023;   // 0x5C  sw    x1,0(x0)
        rom[24] = 32'h00002B83;   // 0x60  lw    x23,0(x0)
        rom[25] = 32'h00004C03;   // 0x64  lbu   x24,0(x0)
        rom[26] = 32'h00300C83;   // 0x68  lb    x25,3(x0)
        rom[27] = 32'h00301423;   // 0x6C  sh    x3,8(x0)
        rom[28] = 32'h00805D03;   // 0x70  lhu   x26,8(x0)
        rom[29] = 32'h004006A3;   // 0x74  sb    x4,13(x0)
        rom[30] = 32'h00D04D83;   // 0x78  lbu   x27,13(x0)
        rom[31] = 32'h00000E13;   // 0x7C  addi  x28,x0,0
        rom[32] = 32'h00100E93;   // 0x80  addi  x29,x0,1
        rom[33] = 32'h00600F13;   // 0x84  addi  x30,x0,6
        rom[34] = 32'h01DE0E33;   // 0x88  add   x28,x28,x29   (loop)
        rom[35] = 32'h001E8E93;   // 0x8C  addi  x29,x29,1
        rom[36] = 32'hFFEECCE3;   // 0x90  blt   x29,x30,loop
        rom[37] = 32'h01EE8463;   // 0x94  beq   x29,x30,skip1
        rom[38] = 32'h3E700E13;   // 0x98  addi  x28,x0,999   (skipped)
        rom[39] = 32'h00001463;   // 0x9C  bne   x0,x0,skip2
        rom[40] = 32'h00700F93;   // 0xA0  addi  x31,x0,7
        rom[41] = 32'h01DF5463;   // 0xA4  bge   x30,x29,skip3
        rom[42] = 32'h37800F93;   // 0xA8  addi  x31,x0,888   (skipped)
        rom[43] = 32'h01E06463;   // 0xAC  bltu  x0,x30,skip4
        rom[44] = 32'h30900F93;   // 0xB0  addi  x31,x0,777   (skipped)
        rom[45] = 32'h000F7463;   // 0xB4  bgeu  x30,x0,skip5
        rom[46] = 32'h29A00F93;   // 0xB8  addi  x31,x0,666   (skipped)
        rom[47] = 32'h00C002EF;   // 0xBC  jal   x5,func
        rom[48] = 32'h01C02823;   // 0xC0  sw    x28,16(x0)
        rom[49] = 32'h0000006F;   // 0xC4  jal   x0,halt      (spin)
        rom[50] = 32'h02A00313;   // 0xC8  addi  x6,x0,42     (func)
        rom[51] = 32'h00028067;   // 0xCC  jalr  x0,0(x5)     (return)
    end

    assign instr = rom[addr[IDXW+1:2]];

endmodule

`default_nettype wire
