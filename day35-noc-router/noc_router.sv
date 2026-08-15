// Author: Asresh Kuricheti
// Day 35: Five-port wormhole NoC router with XY routing and round-robin arbitration.
`timescale 1ns/1ps

module noc_router #(
    parameter int unsigned X_COORD    = 1,
    parameter int unsigned Y_COORD    = 1,
    parameter int unsigned COORD_W    = 2,
    parameter int unsigned PAYLOAD_W  = 24,
    parameter int unsigned FIFO_DEPTH = 2,
    parameter int unsigned PORTS      = 5,
    localparam int unsigned FLIT_W    = PAYLOAD_W + (2 * COORD_W),
    localparam int unsigned PTR_W     = (FIFO_DEPTH <= 1) ? 1 : $clog2(FIFO_DEPTH),
    localparam int unsigned COUNT_W   = $clog2(FIFO_DEPTH + 1),
    localparam int unsigned PORT_W    = (PORTS <= 1) ? 1 : $clog2(PORTS)
) (
    input  logic                         clk,
    input  logic                         rst_n,
    input  logic [PORTS-1:0]             in_valid,
    output logic [PORTS-1:0]             in_ready,
    input  logic [FLIT_W-1:0]            in_flit [PORTS],
    output logic [PORTS-1:0]             out_valid,
    input  logic [PORTS-1:0]             out_ready,
    output logic [FLIT_W-1:0]            out_flit [PORTS]
);
    localparam int unsigned LOCAL = 0;
    localparam int unsigned NORTH = 1;
    localparam int unsigned EAST  = 2;
    localparam int unsigned SOUTH = 3;
    localparam int unsigned WEST  = 4;

    logic [FLIT_W-1:0] fifo_mem [PORTS][FIFO_DEPTH];
    logic [PTR_W-1:0] rd_ptr [PORTS];
    logic [PTR_W-1:0] wr_ptr [PORTS];
    logic [COUNT_W-1:0] count [PORTS];
    logic [FLIT_W-1:0] head_flit [PORTS];
    logic [PORT_W-1:0] route [PORTS];
    logic [PORT_W-1:0] rr_ptr [PORTS];
    logic [PORTS-1:0] request [PORTS];
    logic [PORTS-1:0] grant [PORTS];
    logic [PORTS-1:0] pop;

    function automatic logic [PTR_W-1:0] ptr_next(input logic [PTR_W-1:0] ptr);
        if (ptr == FIFO_DEPTH - 1) ptr_next = '0;
        else                       ptr_next = ptr + 1'b1;
    endfunction

    function automatic logic [PORT_W-1:0] port_next(input logic [PORT_W-1:0] port);
        if (port == PORTS - 1) port_next = '0;
        else                   port_next = port + 1'b1;
    endfunction

    always_comb begin
        pop = '0;
        out_valid = '0;
        for (int unsigned o = 0; o < PORTS; o++) begin
            request[o] = '0;
            grant[o] = '0;
            out_flit[o] = '0;
        end
        for (int unsigned i = 0; i < PORTS; i++) begin
            head_flit[i] = fifo_mem[i][rd_ptr[i]];
            if (head_flit[i][FLIT_W-1 -: COORD_W] > X_COORD)      route[i] = EAST[PORT_W-1:0];
            else if (head_flit[i][FLIT_W-1 -: COORD_W] < X_COORD) route[i] = WEST[PORT_W-1:0];
            else if (head_flit[i][FLIT_W-COORD_W-1 -: COORD_W] > Y_COORD) route[i] = NORTH[PORT_W-1:0];
            else if (head_flit[i][FLIT_W-COORD_W-1 -: COORD_W] < Y_COORD) route[i] = SOUTH[PORT_W-1:0];
            else route[i] = LOCAL[PORT_W-1:0];
            if (count[i] != 0) request[route[i]][i] = 1'b1;
        end
        for (int unsigned o = 0; o < PORTS; o++) begin
            logic found;
            found = 1'b0;
            for (int unsigned offset = 0; offset < PORTS; offset++) begin
                int unsigned candidate;
                candidate = rr_ptr[o] + offset;
                if (candidate >= PORTS) candidate = candidate - PORTS;
                if (!found && request[o][candidate]) begin
                    grant[o][candidate] = 1'b1;
                    out_valid[o] = 1'b1;
                    out_flit[o] = head_flit[candidate];
                    if (out_ready[o]) pop[candidate] = 1'b1;
                    found = 1'b1;
                end
            end
        end
        for (int unsigned i = 0; i < PORTS; i++)
            in_ready[i] = (count[i] < FIFO_DEPTH) || pop[i];
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int unsigned i = 0; i < PORTS; i++) begin
                rd_ptr[i] <= '0;
                wr_ptr[i] <= '0;
                count[i] <= '0;
                rr_ptr[i] <= '0;
            end
        end else begin
            for (int unsigned i = 0; i < PORTS; i++) begin
                logic push;
                push = in_valid[i] && in_ready[i];
                if (push) begin
                    fifo_mem[i][wr_ptr[i]] <= in_flit[i];
                    wr_ptr[i] <= ptr_next(wr_ptr[i]);
                end
                if (pop[i]) rd_ptr[i] <= ptr_next(rd_ptr[i]);
                case ({push, pop[i]})
                    2'b10: count[i] <= count[i] + 1'b1;
                    2'b01: count[i] <= count[i] - 1'b1;
                    default: count[i] <= count[i];
                endcase
            end
            for (int unsigned o = 0; o < PORTS; o++) begin
                for (int unsigned i = 0; i < PORTS; i++)
                    if (grant[o][i] && out_ready[o]) rr_ptr[o] <= port_next(i[PORT_W-1:0]);
            end
        end
    end

    initial begin
        if (PORTS != 5) $error("noc_router requires five ports");
        if (FIFO_DEPTH < 1) $error("FIFO_DEPTH must be at least one");
    end
endmodule
