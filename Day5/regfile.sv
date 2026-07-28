// -----------------------------------------------------------------------------
// regfile.sv - RV32I register file (2 read ports, 1 write port)
//
// A synthesizable, parameterized register file modeling the architectural
// register set of a RISC-V core. It provides the two combinational read ports
// the decode stage needs to fetch rs1/rs2 and the one synchronous write port
// the write-back stage uses to retire a result.
//
// Two architecture details are baked in:
//   * x0 is hardwired to zero: writes to register 0 are dropped and reads of
//     register 0 always return 0, per the RISC-V ISA.
//   * Internal write-forwarding (parameter WRITE_FIRST): when a read port
//     addresses the register being written this cycle, the new write data is
//     forwarded to the read output. In a classic 5-stage pipeline the WB stage
//     writes in the first half of the cycle and ID reads in the second half;
//     modeling that as combinational read + same-cycle forwarding removes the
//     WB->ID read-after-write hazard without an external forwarding path.
//
// Reset (active-low, synchronous) clears every register to 0 so the block is
// reset-safe. Lint-friendly: `default_nettype none, fully-driven outputs.
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps
`default_nettype none

module regfile #(
    parameter int unsigned DATA_W      = 32,          // register width
    parameter int unsigned ADDR_W      = 5,           // -> 2**ADDR_W registers
    parameter bit          WRITE_FIRST = 1'b1         // 1: forward same-cycle write
) (
    input  wire                clk,
    input  wire                rst_n,                  // active-low synchronous reset

    // Write port (synchronous, from write-back stage).
    input  wire                we,                     // write enable
    input  wire [ADDR_W-1:0]   waddr,                  // destination register (rd)
    input  wire [DATA_W-1:0]   wdata,                  // data to write

    // Read port 1 (combinational, rs1).
    input  wire [ADDR_W-1:0]   raddr1,
    output wire [DATA_W-1:0]   rdata1,

    // Read port 2 (combinational, rs2).
    input  wire [ADDR_W-1:0]   raddr2,
    output wire [DATA_W-1:0]   rdata2
);

    localparam int unsigned NUM_REGS = (1 << ADDR_W);

    // The architectural register array. Index 0 (x0) is kept at 0 by never
    // writing it; the read path forces it to 0 regardless.
    reg [DATA_W-1:0] regs [0:NUM_REGS-1];

    integer i;

    // ------------------------------------------------------------------
    // Synchronous write / reset.
    // ------------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            for (i = 0; i < NUM_REGS; i = i + 1)
                regs[i] <= '0;
        end
        // Drop writes to x0; it must stay hardwired to zero.
        else if (we && (waddr != '0)) begin
            regs[waddr] <= wdata;
        end
    end

    // ------------------------------------------------------------------
    // Combinational read with x0 forcing and optional write-forwarding.
    // A write to x0 is never forwarded (x0 stays 0 on every path).
    // ------------------------------------------------------------------
    wire fwd1 = WRITE_FIRST && we && (waddr != '0) && (raddr1 == waddr);
    wire fwd2 = WRITE_FIRST && we && (waddr != '0) && (raddr2 == waddr);

    assign rdata1 = (raddr1 == '0) ? '0
                  :  fwd1           ? wdata
                  :                   regs[raddr1];

    assign rdata2 = (raddr2 == '0) ? '0
                  :  fwd2           ? wdata
                  :                   regs[raddr2];

endmodule

`default_nettype wire
