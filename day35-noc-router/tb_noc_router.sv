// Author: Asresh Kuricheti
// Self-checking directed and randomized verification for the Day 35 NoC router.
`timescale 1ns/1ps

module tb_noc_router;
    localparam int PORTS = 5;
    localparam int COORD_W = 2;
    localparam int PAYLOAD_W = 24;
    localparam int FLIT_W = PAYLOAD_W + 2 * COORD_W;
    localparam int FIFO_DEPTH = 2;
    localparam int COUNT_W = $clog2(FIFO_DEPTH + 1);
    localparam int PORT_W = $clog2(PORTS);
    localparam int CYCLES = 400;
    localparam int LOCAL = 0, NORTH = 1, EAST = 2, SOUTH = 3, WEST = 4;

    logic clk = 0;
    logic rst_n = 0;
    logic [PORTS-1:0] in_valid, in_ready;
    logic [FLIT_W-1:0] in_flit [PORTS];
    logic [PORTS-1:0] out_valid, out_ready;
    logic [FLIT_W-1:0] out_flit [PORTS];
    wire [PORTS*FLIT_W-1:0] in_flit_trace;
    wire [PORTS*FLIT_W-1:0] out_flit_trace;
    wire [PORTS*COUNT_W-1:0] count_trace;
    wire [PORTS*PORT_W-1:0] route_trace;
    wire [PORTS*PORTS-1:0] request_trace;
    wire [PORTS*PORTS-1:0] grant_trace;
    logic [FLIT_W-1:0] model_mem [PORTS][FIFO_DEPTH];
    int unsigned model_rd [PORTS];
    int unsigned model_wr [PORTS];
    int unsigned model_count [PORTS];
    int unsigned rr_model [PORTS];
    int errors = 0;
    int accepted = 0;
    int delivered = 0;
    int unsigned seed = 32'h35a5_2026;

    noc_router #(.X_COORD(1), .Y_COORD(1), .COORD_W(COORD_W),
                 .PAYLOAD_W(PAYLOAD_W), .FIFO_DEPTH(FIFO_DEPTH)) dut (.*);
    generate
        for (genvar p = 0; p < PORTS; p++) begin : gen_trace
            assign in_flit_trace[p*FLIT_W +: FLIT_W] = in_flit[p];
            assign out_flit_trace[p*FLIT_W +: FLIT_W] = out_flit[p];
            assign count_trace[p*COUNT_W +: COUNT_W] = dut.count[p];
            assign route_trace[p*PORT_W +: PORT_W] = dut.route[p];
            assign request_trace[p*PORTS +: PORTS] = dut.request[p];
            assign grant_trace[p*PORTS +: PORTS] = dut.grant[p];
        end
    endgenerate
    always #5 clk = ~clk;

    function automatic int route_of(input logic [FLIT_W-1:0] flit);
        int dx, dy;
        dx = flit[FLIT_W-1 -: COORD_W];
        dy = flit[FLIT_W-COORD_W-1 -: COORD_W];
        if (dx > 1) return EAST;
        if (dx < 1) return WEST;
        if (dy > 1) return NORTH;
        if (dy < 1) return SOUTH;
        return LOCAL;
    endfunction

    function automatic logic [FLIT_W-1:0] make_flit(input int dx, input int dy, input int payload);
        return {dx[COORD_W-1:0], dy[COORD_W-1:0], payload[PAYLOAD_W-1:0]};
    endfunction

    task automatic drive_idle;
        in_valid = '0;
        for (int i = 0; i < PORTS; i++) in_flit[i] = '0;
        out_ready = '1;
    endtask

    task automatic model_and_check;
        int winner [PORTS];
        for (int o = 0; o < PORTS; o++) begin
            winner[o] = -1;
            for (int off = 0; off < PORTS; off++) begin
                int cand;
                cand = (rr_model[o] + off) % PORTS;
                if ((winner[o] < 0) && (model_count[cand] != 0) &&
                    (route_of(model_mem[cand][model_rd[cand]]) == o)) winner[o] = cand;
            end
            if (out_valid[o] !== (winner[o] >= 0)) begin
                $error("output %0d valid mismatch", o); errors++;
            end else if ((winner[o] >= 0) &&
                         (out_flit[o] !== model_mem[winner[o]][model_rd[winner[o]]])) begin
                $error("output %0d data mismatch got=%h expected=%h", o,
                       out_flit[o], model_mem[winner[o]][model_rd[winner[o]]]); errors++;
            end
        end
        for (int i = 0; i < PORTS; i++) begin
            bit will_pop;
            bit expected_ready;
            will_pop = 0;
            for (int o = 0; o < PORTS; o++)
                if ((winner[o] == i) && out_ready[o]) will_pop = 1;
            expected_ready = (model_count[i] < FIFO_DEPTH) || will_pop;
            if (in_ready[i] !== expected_ready) begin
                $error("input %0d ready mismatch", i); errors++;
            end
        end
        for (int o = 0; o < PORTS; o++) begin
            if ((winner[o] >= 0) && out_ready[o]) begin
                model_rd[winner[o]] = (model_rd[winner[o]] + 1) % FIFO_DEPTH;
                model_count[winner[o]]--;
                rr_model[o] = (winner[o] + 1) % PORTS;
                delivered++;
            end
        end
        for (int i = 0; i < PORTS; i++) begin
            if (in_valid[i] && in_ready[i]) begin
                model_mem[i][model_wr[i]] = in_flit[i];
                model_wr[i] = (model_wr[i] + 1) % FIFO_DEPTH;
                model_count[i]++;
                accepted++;
            end
        end
    endtask

    initial begin
        $dumpfile("noc_router.vcd");
        $dumpvars(0, tb_noc_router);
        drive_idle();
        for (int i = 0; i < PORTS; i++) begin
            model_rd[i] = 0;
            model_wr[i] = 0;
            model_count[i] = 0;
            rr_model[i] = 0;
        end
        repeat (3) @(posedge clk);
        @(negedge clk); rst_n = 1;
        @(negedge clk);
        in_valid = 5'b1_1111;
        in_flit[0] = make_flit(1, 1, 'h10);
        in_flit[1] = make_flit(1, 3, 'h11);
        in_flit[2] = make_flit(3, 1, 'h12);
        in_flit[3] = make_flit(1, 0, 'h13);
        in_flit[4] = make_flit(0, 1, 'h14);
        @(posedge clk); model_and_check(); #1;
        @(negedge clk);
        in_valid = 5'b0_1011;
        in_flit[0] = make_flit(2, 0, 'h20);
        in_flit[1] = make_flit(2, 3, 'h21);
        in_flit[3] = make_flit(2, 2, 'h23);
        out_ready[EAST] = 0;
        @(posedge clk); model_and_check(); #1;
        for (int cycle = 0; cycle < CYCLES; cycle++) begin
            @(negedge clk);
            for (int i = 0; i < PORTS; i++) begin
                in_valid[i] = ($urandom(seed) % 100) < 60;
                in_flit[i] = make_flit($urandom(seed) % 4, $urandom(seed) % 4,
                                       (cycle << 4) | i);
                out_ready[i] = ($urandom(seed) % 100) < 75;
            end
            @(posedge clk); model_and_check(); #1;
        end
        @(negedge clk); in_valid = '0; out_ready = '1;
        repeat (30) begin @(posedge clk); model_and_check(); #1; end
        for (int i = 0; i < PORTS; i++)
            if (model_count[i] != 0) begin $error("input %0d did not drain", i); errors++; end
        if ((errors == 0) && (accepted == delivered)) begin
            $display("Accepted %0d flits and delivered %0d flits", accepted, delivered);
            $display("RESULT: *** PASS ***");
        end else begin
            $display("RESULT: *** FAIL *** errors=%0d accepted=%0d delivered=%0d",
                     errors, accepted, delivered);
            $fatal(1);
        end
        $finish;
    end
    initial begin #100000; $fatal(1, "TIMEOUT"); end
endmodule
