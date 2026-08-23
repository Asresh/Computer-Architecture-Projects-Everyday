// Author: Asresh Kuricheti
// Dual-clock FIFO: binary local pointer -> Gray code -> two-flop CDC -> status.
//
//   write clock domain                         read clock domain
//   data -> RAM[wr_addr]     dual-port RAM     RAM[rd_addr] -> data
//          wr_bin -> Gray === 2-FF sync =====> empty / read pointer
//          full  <========= 2-FF sync === Gray <- rd_bin
`timescale 1ns/1ps

module async_fifo #(
    parameter integer DATA_WIDTH = 32,
    parameter integer DEPTH      = 16,
    parameter integer ADDR_WIDTH = $clog2(DEPTH),
    parameter integer PTR_WIDTH  = ADDR_WIDTH + 1
) (
    input  wire                     wr_clk,
    input  wire                     wr_reset_n,
    input  wire                     wr_en,
    input  wire [DATA_WIDTH-1:0]    wr_data,
    output reg                      wr_full,
    output wire [PTR_WIDTH-1:0]     wr_level,

    input  wire                     rd_clk,
    input  wire                     rd_reset_n,
    input  wire                     rd_en,
    output reg  [DATA_WIDTH-1:0]    rd_data,
    output reg                      rd_valid,
    output reg                      rd_empty,
    output wire [PTR_WIDTH-1:0]     rd_level
);
    reg [DATA_WIDTH-1:0] memory [0:DEPTH-1];

    reg [PTR_WIDTH-1:0] wr_bin;
    reg [PTR_WIDTH-1:0] wr_gray;
    reg [PTR_WIDTH-1:0] rd_bin;
    reg [PTR_WIDTH-1:0] rd_gray;

    // ASYNC_REG is recognized by common FPGA/ASIC flows as a CDC synchronizer.
    (* ASYNC_REG = "TRUE" *) reg [PTR_WIDTH-1:0] rd_gray_wr_sync1;
    (* ASYNC_REG = "TRUE" *) reg [PTR_WIDTH-1:0] rd_gray_wr_sync2;
    (* ASYNC_REG = "TRUE" *) reg [PTR_WIDTH-1:0] wr_gray_rd_sync1;
    (* ASYNC_REG = "TRUE" *) reg [PTR_WIDTH-1:0] wr_gray_rd_sync2;

    wire wr_accept = wr_en && !wr_full;
    wire rd_accept = rd_en && !rd_empty;

    wire [PTR_WIDTH-1:0] wr_bin_next = wr_bin + wr_accept;
    wire [PTR_WIDTH-1:0] rd_bin_next = rd_bin + rd_accept;
    wire [PTR_WIDTH-1:0] wr_gray_next = (wr_bin_next >> 1) ^ wr_bin_next;
    wire [PTR_WIDTH-1:0] rd_gray_next = (rd_bin_next >> 1) ^ rd_bin_next;

    // For a power-of-two FIFO, full means the next write pointer has the same
    // address as the synchronized read pointer but the two wrap bits differ.
    wire wr_full_next =
        (wr_gray_next == {~rd_gray_wr_sync2[PTR_WIDTH-1:PTR_WIDTH-2],
                          rd_gray_wr_sync2[PTR_WIDTH-3:0]});
    wire rd_empty_next = (rd_gray_next == wr_gray_rd_sync2);

    function automatic [PTR_WIDTH-1:0] gray_to_bin;
        input [PTR_WIDTH-1:0] gray;
        integer bit_index;
        begin
            gray_to_bin[PTR_WIDTH-1] = gray[PTR_WIDTH-1];
            for (bit_index = PTR_WIDTH-2; bit_index >= 0; bit_index = bit_index-1)
                gray_to_bin[bit_index] = gray_to_bin[bit_index+1] ^ gray[bit_index];
        end
    endfunction

    // These are conservative domain-local occupancy estimates because the
    // opposite pointer takes two destination clocks to cross the CDC boundary.
    assign wr_level = wr_bin - gray_to_bin(rd_gray_wr_sync2);
    assign rd_level = gray_to_bin(wr_gray_rd_sync2) - rd_bin;

    always @(posedge wr_clk or negedge wr_reset_n) begin
        if (!wr_reset_n) begin
            wr_bin  <= {PTR_WIDTH{1'b0}};
            wr_gray <= {PTR_WIDTH{1'b0}};
            wr_full <= 1'b0;
        end else begin
            if (wr_accept)
                memory[wr_bin[ADDR_WIDTH-1:0]] <= wr_data;
            wr_bin  <= wr_bin_next;
            wr_gray <= wr_gray_next;
            wr_full <= wr_full_next;
        end
    end

    always @(posedge rd_clk or negedge rd_reset_n) begin
        if (!rd_reset_n) begin
            rd_bin   <= {PTR_WIDTH{1'b0}};
            rd_gray  <= {PTR_WIDTH{1'b0}};
            rd_data  <= {DATA_WIDTH{1'b0}};
            rd_valid <= 1'b0;
            rd_empty <= 1'b1;
        end else begin
            rd_valid <= rd_accept;
            if (rd_accept)
                rd_data <= memory[rd_bin[ADDR_WIDTH-1:0]];
            rd_bin   <= rd_bin_next;
            rd_gray  <= rd_gray_next;
            rd_empty <= rd_empty_next;
        end
    end

    always @(posedge wr_clk or negedge wr_reset_n) begin
        if (!wr_reset_n) begin
            rd_gray_wr_sync1 <= {PTR_WIDTH{1'b0}};
            rd_gray_wr_sync2 <= {PTR_WIDTH{1'b0}};
        end else begin
            rd_gray_wr_sync1 <= rd_gray;
            rd_gray_wr_sync2 <= rd_gray_wr_sync1;
        end
    end

    always @(posedge rd_clk or negedge rd_reset_n) begin
        if (!rd_reset_n) begin
            wr_gray_rd_sync1 <= {PTR_WIDTH{1'b0}};
            wr_gray_rd_sync2 <= {PTR_WIDTH{1'b0}};
        end else begin
            wr_gray_rd_sync1 <= wr_gray;
            wr_gray_rd_sync2 <= wr_gray_rd_sync1;
        end
    end
endmodule
