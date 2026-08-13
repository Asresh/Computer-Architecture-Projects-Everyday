// -----------------------------------------------------------------------------
// pipeline_rv32i.sv - Classic 5-stage pipelined RV32I core
//                     (IF / ID / EX / MEM / WB) with a full data-forwarding
//                     unit, a load-use hazard-detection stall, and EX-stage
//                     branch/jump resolution with control-hazard flush.
//
// This is the pipelined sibling of the Day 5 single-cycle core: the same RV32I
// integer datapath, but sliced into five stages separated by pipeline
// registers so (ideally) one instruction retires every cycle. The interesting
// architecture is everything that makes that *correct* in the presence of
// dependencies between in-flight instructions:
//
//   * Data hazards (RAW). The forwarding (bypass) unit routes a producer's
//     result straight from the EX/MEM or MEM/WB pipeline register back to the
//     EX-stage operand muxes, so a dependent instruction need not wait for the
//     producer to reach write-back. EX/MEM (younger) takes priority over
//     MEM/WB (older). The register file is *write-first* (WB writes in the
//     first half of the cycle, ID reads in the second), which resolves the
//     distance-3 hazard without an explicit bypass path.
//
//   * The one hazard forwarding cannot cover: the load-use hazard. A load's
//     data is not available until the end of MEM, so if the very next
//     instruction consumes it the hazard-detection unit inserts a single
//     bubble (freeze PC + IF/ID, squash ID/EX) so the load can reach MEM/WB
//     and then forward.
//
//   * Control hazards. Branches and jumps are resolved in EX. On a taken
//     redirect the two younger instructions already fetched (in IF/ID and
//     ID/EX) are flushed to bubbles and the PC is steered to the target.
//
// Supported: LUI, AUIPC, JAL, JALR, all six branches, the OP/OP-IMM integer
// ALU set, and LB/LH/LW/LBU/LHU + SB/SH/SW. Reuses the Day 1 `alu` module.
//
// Reset is active-low synchronous. Lint-friendly (`default_nettype none, every
// output driven). Internal arrays (`rom`, `xregs`, `dmem`) are exposed for a
// backdoor-load / final-state-compare testbench via hierarchical reference.
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps
`default_nettype none

module pipeline_rv32i #(
    parameter int unsigned IMEM_WORDS = 256,       // instruction ROM depth (words)
    parameter int unsigned DMEM_BYTES = 4096       // data memory depth (bytes)
) (
    input  wire        clk,
    input  wire        rst_n,

    // Debug / observation ports (used by the testbench and the waveform dump).
    output wire [31:0] dbg_pc_if,                   // PC in each stage (for the
    output wire [31:0] dbg_pc_id,                   //   pipeline diagram)
    output wire [31:0] dbg_pc_ex,
    output wire [31:0] dbg_pc_mem,
    output wire [31:0] dbg_pc_wb,
    output wire        dbg_stall,                   // load-use bubble inserted
    output wire        dbg_flush,                   // branch/jump redirect taken
    output wire [1:0]  dbg_fwd_a,                   // EX forwarding select A
    output wire [1:0]  dbg_fwd_b,                   //   00=RF 01=MEM/WB 10=EX/MEM
    output wire        dbg_wb_we,                   // a result retires this cycle
    output wire [4:0]  dbg_wb_rd,
    output wire [31:0] dbg_wb_data
);

    // ------------------------------------------------------------------
    // ALU operation encodings (mirror the Day 1 `alu`).
    // ------------------------------------------------------------------
    localparam logic [3:0] OP_ADD  = 4'b0000, OP_SUB  = 4'b0001,
                           OP_SLL  = 4'b0010, OP_SLT  = 4'b0011,
                           OP_SLTU = 4'b0100, OP_XOR  = 4'b0101,
                           OP_SRL  = 4'b0110, OP_SRA  = 4'b0111,
                           OP_OR   = 4'b1000, OP_AND  = 4'b1001;

    // RV32I opcodes.
    localparam logic [6:0] OPC_LUI   = 7'b0110111, OPC_AUIPC = 7'b0010111,
                           OPC_JAL   = 7'b1101111, OPC_JALR  = 7'b1100111,
                           OPC_BRANCH= 7'b1100011, OPC_LOAD  = 7'b0000011,
                           OPC_STORE = 7'b0100011, OPC_OPIMM = 7'b0010011,
                           OPC_OP    = 7'b0110011;

    localparam logic [31:0] NOP = 32'h0000_0013;    // addi x0,x0,0

    // ==================================================================
    // Architectural / memory state (backdoor-visible from the testbench)
    // ==================================================================
    localparam int unsigned IMIDX = $clog2(IMEM_WORDS);
    localparam int unsigned DMIDX = $clog2(DMEM_BYTES);

    reg [31:0] rom   [0:IMEM_WORDS-1];              // instruction ROM
    reg [31:0] xregs [0:31];                        // architectural registers
    reg [7:0]  dmem  [0:DMEM_BYTES-1];              // byte-addressable data mem

    integer k;
    initial begin
        for (k = 0; k < IMEM_WORDS; k = k + 1) rom[k]  = NOP;
        for (k = 0; k < 32;         k = k + 1) xregs[k] = 32'h0;
        for (k = 0; k < DMEM_BYTES; k = k + 1) dmem[k] = 8'h0;
    end

    // ==================================================================
    // IF - instruction fetch
    // ==================================================================
    reg  [31:0] pc_f;                               // program counter
    wire [31:0] instr_f = rom[pc_f[IMIDX+1:2]];

    // Redirect / stall wires are produced downstream (EX / ID); declared here.
    wire        redirect;                           // EX wants a new PC
    wire [31:0] redirect_pc;
    wire        stall;                              // load-use bubble

    wire [31:0] pc_plus4_f = pc_f + 32'd4;
    wire [31:0] pc_next    = redirect ? redirect_pc :
                             stall     ? pc_f       : pc_plus4_f;

    // ------------------------------------------------------------------
    // IF/ID pipeline register
    // ------------------------------------------------------------------
    reg [31:0] pc_d, instr_d;
    reg        valid_d;

    // ==================================================================
    // ID - decode, register read, immediate gen, hazard detect
    // ==================================================================
    wire [6:0] opcode_d = instr_d[6:0];
    wire [4:0] rs1_d    = instr_d[19:15];
    wire [4:0] rs2_d    = instr_d[24:20];
    wire [4:0] rd_d     = instr_d[11:7];
    wire [2:0] funct3_d = instr_d[14:12];
    wire       funct7b_d= instr_d[30];

    // Immediate generator (I / S / B / U / J).
    wire [31:0] imm_i = {{20{instr_d[31]}}, instr_d[31:20]};
    wire [31:0] imm_s = {{20{instr_d[31]}}, instr_d[31:25], instr_d[11:7]};
    wire [31:0] imm_b = {{19{instr_d[31]}}, instr_d[31], instr_d[7],
                         instr_d[30:25], instr_d[11:8], 1'b0};
    wire [31:0] imm_u = {instr_d[31:12], 12'b0};
    wire [31:0] imm_j = {{11{instr_d[31]}}, instr_d[31], instr_d[19:12],
                         instr_d[20], instr_d[30:21], 1'b0};

    reg  [31:0] imm_d;
    reg  [3:0]  alu_op_d;
    reg         reg_write_d, mem_read_d, mem_write_d, mem_to_reg_d;
    reg         alu_src_d, branch_d, jump_d, is_jalr_d, is_lui_d, is_auipc_d;

    always_comb begin
        // Safe defaults => an unrecognised opcode behaves as a NOP.
        imm_d        = imm_i;
        alu_op_d     = OP_ADD;
        reg_write_d  = 1'b0;
        mem_read_d   = 1'b0;
        mem_write_d  = 1'b0;
        mem_to_reg_d = 1'b0;
        alu_src_d    = 1'b1;     // default: operand B = immediate
        branch_d     = 1'b0;
        jump_d       = 1'b0;
        is_jalr_d    = 1'b0;
        is_lui_d     = 1'b0;
        is_auipc_d   = 1'b0;

        unique case (opcode_d)
            OPC_LUI: begin
                imm_d = imm_u; reg_write_d = 1'b1; is_lui_d = 1'b1;
            end
            OPC_AUIPC: begin
                imm_d = imm_u; reg_write_d = 1'b1; is_auipc_d = 1'b1;
            end
            OPC_JAL: begin
                imm_d = imm_j; reg_write_d = 1'b1; jump_d = 1'b1;
            end
            OPC_JALR: begin
                imm_d = imm_i; reg_write_d = 1'b1; jump_d = 1'b1;
                is_jalr_d = 1'b1;
            end
            OPC_BRANCH: begin
                imm_d = imm_b; branch_d = 1'b1; alu_src_d = 1'b0;
            end
            OPC_LOAD: begin
                imm_d = imm_i; reg_write_d = 1'b1; mem_read_d = 1'b1;
                mem_to_reg_d = 1'b1;
            end
            OPC_STORE: begin
                imm_d = imm_s; mem_write_d = 1'b1;
            end
            OPC_OPIMM: begin
                imm_d = imm_i; reg_write_d = 1'b1;
                unique case (funct3_d)
                    3'b000: alu_op_d = OP_ADD;                       // addi
                    3'b010: alu_op_d = OP_SLT;                       // slti
                    3'b011: alu_op_d = OP_SLTU;                      // sltiu
                    3'b100: alu_op_d = OP_XOR;                       // xori
                    3'b110: alu_op_d = OP_OR;                        // ori
                    3'b111: alu_op_d = OP_AND;                       // andi
                    3'b001: alu_op_d = OP_SLL;                       // slli
                    3'b101: alu_op_d = funct7b_d ? OP_SRA : OP_SRL;  // srai/srli
                    default: alu_op_d = OP_ADD;
                endcase
            end
            OPC_OP: begin
                reg_write_d = 1'b1; alu_src_d = 1'b0;
                unique case (funct3_d)
                    3'b000: alu_op_d = funct7b_d ? OP_SUB : OP_ADD;  // sub/add
                    3'b001: alu_op_d = OP_SLL;
                    3'b010: alu_op_d = OP_SLT;
                    3'b011: alu_op_d = OP_SLTU;
                    3'b100: alu_op_d = OP_XOR;
                    3'b101: alu_op_d = funct7b_d ? OP_SRA : OP_SRL;
                    3'b110: alu_op_d = OP_OR;
                    3'b111: alu_op_d = OP_AND;
                    default: alu_op_d = OP_ADD;
                endcase
            end
            default: /* keep NOP defaults */ ;
        endcase
    end

    // Register-file read with write-first (WB->ID same-cycle) forwarding.
    wire        wb_we;
    wire [4:0]  wb_rd;
    wire [31:0] wb_data;

    wire [31:0] rf_rdata1 = (rs1_d == 5'd0)                    ? 32'h0 :
                            (wb_we && (wb_rd == rs1_d))        ? wb_data :
                                                                 xregs[rs1_d];
    wire [31:0] rf_rdata2 = (rs2_d == 5'd0)                    ? 32'h0 :
                            (wb_we && (wb_rd == rs2_d))        ? wb_data :
                                                                 xregs[rs2_d];

    // ------------------------------------------------------------------
    // ID/EX pipeline register
    // ------------------------------------------------------------------
    reg [31:0] pc_e, imm_e, rdata1_e, rdata2_e;
    reg [4:0]  rs1_e, rs2_e, rd_e;
    reg [2:0]  funct3_e;
    reg [3:0]  alu_op_e;
    reg        valid_e, reg_write_e, mem_read_e, mem_write_e, mem_to_reg_e;
    reg        alu_src_e, branch_e, jump_e, is_jalr_e, is_lui_e, is_auipc_e;

    // ==================================================================
    // EX - forwarding, ALU, branch resolution
    // ==================================================================
    // Pipeline-register handles from later stages (declared below).
    wire        reg_write_m, mem_to_reg_m;
    wire [4:0]  rd_m;
    wire [31:0] alu_result_m;

    // Forwarding unit: 2'b10 = from EX/MEM, 2'b01 = from MEM/WB, else 2'b00.
    reg  [1:0]  fwd_a, fwd_b;
    always_comb begin
        fwd_a = 2'b00;
        if (reg_write_m && (rd_m != 5'd0) && (rd_m == rs1_e))
            fwd_a = 2'b10;                                   // EX/MEM (younger)
        else if (wb_we && (wb_rd != 5'd0) && (wb_rd == rs1_e))
            fwd_a = 2'b01;                                   // MEM/WB (older)

        fwd_b = 2'b00;
        if (reg_write_m && (rd_m != 5'd0) && (rd_m == rs2_e))
            fwd_b = 2'b10;
        else if (wb_we && (wb_rd != 5'd0) && (wb_rd == rs2_e))
            fwd_b = 2'b01;
    end

    reg [31:0] oper_a, oper_b_reg;                  // post-forwarding operands
    always_comb begin
        unique case (fwd_a)
            2'b10:   oper_a = alu_result_m;
            2'b01:   oper_a = wb_data;
            default: oper_a = rdata1_e;
        endcase
        unique case (fwd_b)
            2'b10:   oper_b_reg = alu_result_m;
            2'b01:   oper_b_reg = wb_data;
            default: oper_b_reg = rdata2_e;
        endcase
    end

    // ALU operand B: immediate for I-type/loads/stores, else forwarded rs2.
    wire [31:0] alu_b = alu_src_e ? imm_e : oper_b_reg;

    wire [31:0] alu_y;
    /* verilator lint_off PINMISSING */
    alu #(.WIDTH(32)) u_alu (
        .a      (oper_a),
        .b      (alu_b),
        .alu_op (alu_op_e),
        .result (alu_y),
        .zero   ()
    );
    /* verilator lint_on PINMISSING */

    // Branch comparator (uses forwarded rs1/rs2).
    reg branch_taken;
    always_comb begin
        unique case (funct3_e)
            3'b000:  branch_taken = (oper_a == oper_b_reg);              // beq
            3'b001:  branch_taken = (oper_a != oper_b_reg);              // bne
            3'b100:  branch_taken = ($signed(oper_a) <  $signed(oper_b_reg)); // blt
            3'b101:  branch_taken = ($signed(oper_a) >= $signed(oper_b_reg)); // bge
            3'b110:  branch_taken = (oper_a <  oper_b_reg);              // bltu
            3'b111:  branch_taken = (oper_a >= oper_b_reg);              // bgeu
            default: branch_taken = 1'b0;
        endcase
    end

    wire [31:0] pc_plus4_e = pc_e + 32'd4;
    wire [31:0] br_target  = pc_e + imm_e;                       // branch / jal
    wire [31:0] jalr_target= (oper_a + imm_e) & 32'hFFFF_FFFE;   // jalr

    // Redirect if a valid branch is taken or any jump executes.
    assign redirect    = valid_e && ((branch_e && branch_taken) || jump_e);
    assign redirect_pc = is_jalr_e ? jalr_target : br_target;

    // EX result mux (what will be written back / carried to MEM as an address).
    reg [31:0] result_e;
    always_comb begin
        if (is_lui_e)        result_e = imm_e;
        else if (is_auipc_e) result_e = pc_e + imm_e;
        else if (jump_e)     result_e = pc_plus4_e;     // link value
        else                 result_e = alu_y;          // ALU / load-store addr
    end

    // ------------------------------------------------------------------
    // EX/MEM pipeline register
    // ------------------------------------------------------------------
    reg [31:0] pc_m, alu_result_m_r, store_data_m;
    reg [4:0]  rd_m_r;
    reg [2:0]  funct3_m;
    reg        valid_m, reg_write_m_r, mem_read_m, mem_write_m, mem_to_reg_m_r;

    assign reg_write_m  = reg_write_m_r && valid_m;
    assign mem_to_reg_m = mem_to_reg_m_r;
    assign rd_m         = rd_m_r;
    assign alu_result_m = alu_result_m_r;

    // ==================================================================
    // MEM - data memory access
    // ==================================================================
    wire [DMIDX-1:0] mem_addr = alu_result_m_r[DMIDX-1:0];
    wire [31:0] mem_word = {dmem[mem_addr+3], dmem[mem_addr+2],
                            dmem[mem_addr+1], dmem[mem_addr+0]};   // little-endian
    wire [15:0] mem_half = {dmem[mem_addr+1], dmem[mem_addr+0]};
    wire [7:0]  mem_byte =  dmem[mem_addr+0];

    reg [31:0] load_data_m;
    always_comb begin
        unique case (funct3_m)
            3'b000:  load_data_m = {{24{mem_byte[7]}},  mem_byte};   // lb
            3'b001:  load_data_m = {{16{mem_half[15]}}, mem_half};   // lh
            3'b010:  load_data_m = mem_word;                         // lw
            3'b100:  load_data_m = {24'h0, mem_byte};                // lbu
            3'b101:  load_data_m = {16'h0, mem_half};                // lhu
            default: load_data_m = mem_word;
        endcase
    end

    // Synchronous store (little-endian byte lanes).
    always_ff @(posedge clk) begin
        if (mem_write_m && valid_m) begin
            dmem[mem_addr+0] <= store_data_m[7:0];
            if (funct3_m != 3'b000) // sh / sw write byte 1
                dmem[mem_addr+1] <= store_data_m[15:8];
            if (funct3_m == 3'b010) begin // sw writes bytes 2,3
                dmem[mem_addr+2] <= store_data_m[23:16];
                dmem[mem_addr+3] <= store_data_m[31:24];
            end
        end
    end

    // ------------------------------------------------------------------
    // MEM/WB pipeline register
    // ------------------------------------------------------------------
    reg [31:0] pc_w, alu_result_w, load_data_w;
    reg [4:0]  rd_w;
    reg        valid_w, reg_write_w, mem_to_reg_w;

    // ==================================================================
    // WB - write back
    // ==================================================================
    assign wb_data = mem_to_reg_w ? load_data_w : alu_result_w;
    assign wb_rd   = rd_w;
    assign wb_we   = reg_write_w && valid_w && (rd_w != 5'd0);

    // ==================================================================
    // Hazard-detection unit (load-use): stall one cycle if the instruction
    // in EX is a load whose rd is a source of the instruction in ID.
    // ==================================================================
    // rs1 is read by every format except LUI/AUIPC/JAL (whose instr[19:15]
    // bits are immediate, not a source register).
    wire use_rs1 = !((opcode_d == OPC_LUI) || (opcode_d == OPC_AUIPC) ||
                     (opcode_d == OPC_JAL));
    wire use_rs2 = (opcode_d == OPC_OP) || (opcode_d == OPC_BRANCH) ||
                   (opcode_d == OPC_STORE);
    assign stall = valid_e && mem_read_e && (rd_e != 5'd0) &&
                   ((use_rs1 && (rd_e == rs1_d)) ||
                    (use_rs2 && (rd_e == rs2_d)));

    // ==================================================================
    // Sequential state update (all pipeline registers + PC)
    // ==================================================================
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            pc_f    <= 32'h0;
            valid_d <= 1'b0; pc_d <= 32'h0; instr_d <= NOP;
            valid_e <= 1'b0;
            valid_m <= 1'b0;
            valid_w <= 1'b0;
        end else begin
            // -------- WB write into the register file (write-first) --------
            if (wb_we) xregs[wb_rd] <= wb_data;

            // -------- PC --------
            pc_f <= pc_next;

            // -------- IF/ID --------
            if (redirect) begin
                valid_d <= 1'b0; instr_d <= NOP; pc_d <= pc_f;   // flush
            end else if (stall) begin
                valid_d <= valid_d; instr_d <= instr_d; pc_d <= pc_d; // hold
            end else begin
                valid_d <= 1'b1; instr_d <= instr_f; pc_d <= pc_f;
            end

            // -------- ID/EX --------
            // Squash on a redirect (branch shadow) or when inserting a
            // load-use bubble; otherwise latch the decoded instruction.
            if (redirect || stall) begin
                valid_e     <= 1'b0;
                reg_write_e <= 1'b0; mem_read_e <= 1'b0; mem_write_e <= 1'b0;
                mem_to_reg_e<= 1'b0; branch_e   <= 1'b0; jump_e      <= 1'b0;
                is_jalr_e   <= 1'b0; is_lui_e   <= 1'b0; is_auipc_e  <= 1'b0;
                rd_e        <= 5'd0; rs1_e <= 5'd0; rs2_e <= 5'd0;
                alu_op_e    <= OP_ADD; alu_src_e <= 1'b1;
                pc_e        <= pc_d;  imm_e <= 32'h0;
                rdata1_e    <= 32'h0; rdata2_e <= 32'h0; funct3_e <= 3'b0;
            end else begin
                valid_e     <= valid_d;
                reg_write_e <= reg_write_d; mem_read_e  <= mem_read_d;
                mem_write_e <= mem_write_d; mem_to_reg_e<= mem_to_reg_d;
                branch_e    <= branch_d;    jump_e      <= jump_d;
                is_jalr_e   <= is_jalr_d;   is_lui_e    <= is_lui_d;
                is_auipc_e  <= is_auipc_d;
                alu_op_e    <= alu_op_d;    alu_src_e   <= alu_src_d;
                rd_e        <= rd_d;  rs1_e <= rs1_d; rs2_e <= rs2_d;
                funct3_e    <= funct3_d;
                pc_e        <= pc_d;  imm_e <= imm_d;
                rdata1_e    <= rf_rdata1;   rdata2_e    <= rf_rdata2;
            end

            // -------- EX/MEM --------
            // The instruction in EX is itself real (it produces the redirect);
            // only the two *younger* instructions (IF/ID, ID/EX) are flushed,
            // so the EX instruction advances to MEM normally.
            valid_m        <= valid_e;
            reg_write_m_r  <= reg_write_e;
            mem_read_m     <= mem_read_e;
            mem_write_m    <= mem_write_e;
            mem_to_reg_m_r <= mem_to_reg_e;
            rd_m_r         <= rd_e;
            funct3_m       <= funct3_e;
            pc_m           <= pc_e;
            alu_result_m_r <= result_e;
            store_data_m   <= oper_b_reg;     // forwarded store data

            // -------- MEM/WB --------
            valid_w      <= valid_m;
            reg_write_w  <= reg_write_m_r && valid_m;
            mem_to_reg_w <= mem_to_reg_m_r;
            rd_w         <= rd_m_r;
            pc_w         <= pc_m;
            alu_result_w <= alu_result_m_r;
            load_data_w  <= load_data_m;
        end
    end

    // ==================================================================
    // Debug taps
    // ==================================================================
    assign dbg_pc_if  = pc_f;
    assign dbg_pc_id  = pc_d;
    assign dbg_pc_ex  = pc_e;
    assign dbg_pc_mem = pc_m;
    assign dbg_pc_wb  = pc_w;
    assign dbg_stall  = stall;
    assign dbg_flush  = redirect;
    assign dbg_fwd_a  = fwd_a;
    assign dbg_fwd_b  = fwd_b;
    assign dbg_wb_we  = wb_we;
    assign dbg_wb_rd  = wb_rd;
    assign dbg_wb_data= wb_data;

endmodule

`default_nettype wire
