// Author: Asresh Kuricheti
//
// Burst DMA engine: copies a programmable number of full-width words without
// CPU intervention.  One read is outstanding at a time, so the returned word
// is safely buffered until the destination accepts it.
//
//   command -> [address/count control] -> read request
//                         ^                    |
//                         |                read response
//                         +-- [data buffer] ---+--> write request

module burst_dma_engine #(
    parameter int ADDR_WIDTH = 16,
    parameter int DATA_WIDTH = 32,
    parameter int LEN_WIDTH  = 8
) (
    input  logic                  clk,
    input  logic                  rst_n,

    input  logic                  cmd_valid,
    output logic                  cmd_ready,
    input  logic [ADDR_WIDTH-1:0] cmd_src_addr,
    input  logic [ADDR_WIDTH-1:0] cmd_dst_addr,
    input  logic [LEN_WIDTH-1:0]  cmd_length,

    output logic                  busy,
    output logic                  done,

    output logic                  read_req_valid,
    input  logic                  read_req_ready,
    output logic [ADDR_WIDTH-1:0] read_req_addr,
    input  logic                  read_rsp_valid,
    input  logic [DATA_WIDTH-1:0] read_rsp_data,

    output logic                  write_req_valid,
    input  logic                  write_req_ready,
    output logic [ADDR_WIDTH-1:0] write_req_addr,
    output logic [DATA_WIDTH-1:0] write_req_data
);

    localparam int ADDR_STEP = DATA_WIDTH / 8;

    typedef enum logic [1:0] {
        IDLE,
        ISSUE_READ,
        WAIT_READ,
        ISSUE_WRITE
    } state_t;

    state_t                  state_q;
    logic [ADDR_WIDTH-1:0]   src_addr_q;
    logic [ADDR_WIDTH-1:0]   dst_addr_q;
    logic [LEN_WIDTH-1:0]    beats_left_q;
    logic [DATA_WIDTH-1:0]   data_q;

    always_comb begin
        cmd_ready       = (state_q == IDLE);
        busy            = (state_q != IDLE);
        read_req_valid  = (state_q == ISSUE_READ);
        read_req_addr   = src_addr_q;
        write_req_valid = (state_q == ISSUE_WRITE);
        write_req_addr  = dst_addr_q;
        write_req_data  = data_q;
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state_q      <= IDLE;
            src_addr_q   <= '0;
            dst_addr_q   <= '0;
            beats_left_q <= '0;
            data_q       <= '0;
            done         <= 1'b0;
        end else begin
            done <= 1'b0;

            case (state_q)
                IDLE: begin
                    if (cmd_valid) begin
                        src_addr_q   <= cmd_src_addr;
                        dst_addr_q   <= cmd_dst_addr;
                        beats_left_q <= cmd_length;
                        if (cmd_length == '0) begin
                            // A zero-length copy is a legal no-op.
                            done <= 1'b1;
                        end else begin
                            state_q <= ISSUE_READ;
                        end
                    end
                end

                ISSUE_READ: begin
                    if (read_req_ready) begin
                        state_q <= WAIT_READ;
                    end
                end

                WAIT_READ: begin
                    if (read_rsp_valid) begin
                        data_q  <= read_rsp_data;
                        state_q <= ISSUE_WRITE;
                    end
                end

                ISSUE_WRITE: begin
                    if (write_req_ready) begin
                        if (beats_left_q == {{(LEN_WIDTH-1){1'b0}}, 1'b1}) begin
                            beats_left_q <= '0;
                            state_q      <= IDLE;
                            done         <= 1'b1;
                        end else begin
                            src_addr_q   <= src_addr_q + ADDR_STEP;
                            dst_addr_q   <= dst_addr_q + ADDR_STEP;
                            beats_left_q <= beats_left_q - 1'b1;
                            state_q      <= ISSUE_READ;
                        end
                    end
                end

                default: state_q <= IDLE;
            endcase
        end
    end

endmodule
