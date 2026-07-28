// -----------------------------------------------------------------------------
// lsu.sv - RV32I load/store unit + byte-addressable data memory
//
// A synthesizable data-memory subsystem for a single-cycle RISC-V core. It
// couples a little-endian, byte-addressable data memory with the lane logic
// that implements the RV32I load/store instructions:
//
//   loads : lb  (000)  lh  (001)  lw  (010)  lbu (100)  lhu (101)
//   stores: sb  (000)  sh  (001)  sw  (010)
//
// selected by funct3. The unit performs:
//   * address decode  -- word index = addr[.. :2], byte offset = addr[1:0];
//   * byte-lane / half selection on loads;
//   * sign- vs. zero-extension of sub-word loads (lb/lh signed, lbu/lhu zero);
//   * per-byte write enables on stores (a 4-bit byte-enable mask + a
//     lane-aligned store word), so a store touches only the addressed bytes.
//
// The memory is 32-bit-word storage internally with four byte lanes; from the
// programmer's view it is byte-addressed and little-endian (the byte at the
// lowest address is the least-significant byte of a word).
//
// Misalignment policy (documented, non-faulting): accesses are expected to be
// naturally aligned, but the unit never crosses a 32-bit word boundary and
// always produces a defined result:
//   * byte  : any offset 0..3 selects that lane;
//   * half  : addr[1] selects the half (offset 0/1 -> low [15:0],
//             offset 2/3 -> high [31:16]); addr[0] is ignored;
//   * word  : the whole word at addr[.. :2] is accessed; addr[1:0] is ignored.
//
// Reads are combinational; writes and the (active-low, synchronous) reset that
// clears the memory are on the rising clock edge. Lint-friendly:
// `default_nettype none, fully-driven outputs, field slicing kept out of the
// process sensitivity lists.
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps
`default_nettype none

module lsu #(
    parameter int unsigned DATA_W = 32,        // load/store data width
    parameter int unsigned WORDS  = 256        // memory depth in 32-bit words
) (
    input  wire              clk,
    input  wire              rst_n,            // active-low synchronous reset

    input  wire              mem_read,         // load enable
    input  wire              mem_write,        // store enable
    input  wire [2:0]        funct3,           // size/sign select (see header)
    input  wire [31:0]       addr,             // byte address (ALU result)
    input  wire [DATA_W-1:0] wdata,            // store data (rs2)
    output reg  [DATA_W-1:0] rdata             // load result, right-justified
);

    // funct3 encodings.
    localparam logic [2:0] F3_B  = 3'b000,  // lb  / sb
                           F3_H  = 3'b001,  // lh  / sh
                           F3_W  = 3'b010,  // lw  / sw
                           F3_BU = 3'b100,  // lbu
                           F3_HU = 3'b101;  // lhu

    localparam int unsigned IDXW = $clog2(WORDS);

    // 32-bit-word memory with four byte lanes.
    reg [31:0] mem [0:WORDS-1];

    // Address decode: word index and byte offset within the word.
    wire [IDXW-1:0] widx = addr[IDXW+1:2];
    wire [1:0]      off  = addr[1:0];

    integer i;

    // ------------------------------------------------------------------
    // Combinational read path.
    // ------------------------------------------------------------------
    wire [31:0] word = mem[widx];

    // Byte-lane and half selection (constant slices -> no variable part-select).
    wire [7:0]  b_lane = (off == 2'd0) ? word[7:0]   :
                         (off == 2'd1) ? word[15:8]  :
                         (off == 2'd2) ? word[23:16] :
                                         word[31:24];
    wire [15:0] h_lane = off[1] ? word[31:16] : word[15:0];

    // Sign bits pulled out into continuous assigns so the extension mux below
    // holds no bit-selects.
    wire b_sign = b_lane[7];
    wire h_sign = h_lane[15];

    always_comb begin
        case (funct3)
            F3_B   : rdata = {{24{b_sign}}, b_lane};   // sign-extend byte
            F3_BU  : rdata = {24'b0,        b_lane};   // zero-extend byte
            F3_H   : rdata = {{16{h_sign}}, h_lane};   // sign-extend half
            F3_HU  : rdata = {16'b0,        h_lane};   // zero-extend half
            F3_W   : rdata = word;                      // full word
            default: rdata = word;
        endcase
    end

    // ------------------------------------------------------------------
    // Store lane logic: 4-bit byte-enable mask + lane-aligned store word.
    // A store to a byte/half lands in the correct lane(s) via a shift; the
    // byte-enable then commits only those lanes.
    // ------------------------------------------------------------------
    reg [3:0]  be;
    reg [31:0] wlane;
    wire       off1 = off[1];                   // half-lane select (out of proc)

    always_comb begin
        be    = 4'b0000;
        wlane = 32'b0;
        if (mem_write) begin
            case (funct3)
                F3_B: begin
                    be    = 4'b0001 << off;             // one byte at 'off'
                    wlane = wdata << (8 * off);
                end
                F3_H: begin
                    be    = off1 ? 4'b1100 : 4'b0011;   // half at low/high lanes
                    wlane = off1 ? (wdata << 16) : wdata;
                end
                F3_W: begin
                    be    = 4'b1111;
                    wlane = wdata;
                end
                default: begin
                    be    = 4'b0000;                    // sbu/shu do not exist
                    wlane = 32'b0;
                end
            endcase
        end
    end

    // ------------------------------------------------------------------
    // Synchronous write / reset. Read-modify-write the addressed word under
    // the per-byte enables so untouched lanes keep their value.
    // ------------------------------------------------------------------
    reg [31:0] newword;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            for (i = 0; i < WORDS; i = i + 1)
                mem[i] <= '0;
        end
        else if (mem_write) begin
            newword = mem[widx];
            if (be[0]) newword[7:0]   = wlane[7:0];
            if (be[1]) newword[15:8]  = wlane[15:8];
            if (be[2]) newword[23:16] = wlane[23:16];
            if (be[3]) newword[31:24] = wlane[31:24];
            mem[widx] <= newword;
        end
    end

endmodule

`default_nettype wire
