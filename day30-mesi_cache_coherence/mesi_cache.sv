// -----------------------------------------------------------------------------
// Day30 - MESI Snooping Cache-Coherence Controller
// -----------------------------------------------------------------------------
// A per-core write-back / write-allocate L1 data cache that keeps itself
// COHERENT with the other caches on a shared snooping bus, using the classic
// four-state MESI protocol (Illinois protocol).
//
//   I - Invalid    : no copy here.
//   S - Shared     : clean copy; other caches may also hold it; memory is up to date.
//   E - Exclusive  : clean copy and the ONLY cached copy; memory is up to date.
//   M - Modified   : the only cached copy, dirty; memory is STALE.
//
// The whole point of the E state is that a store to a line in E needs NO bus
// traffic at all: the core already knows nobody else has a copy, so it can go
// E -> M silently. A three-state MSI protocol has to broadcast an invalidate on
// every first store to a private line - which is most stores in real, mostly
// private, single-threaded working sets.
//
// Two independent request paths share the tag/state/data arrays:
//
//   * the LOCAL (CPU) path  - loads/stores from this core, which may miss, may
//     have to write a dirty victim back, and may have to upgrade S -> M;
//   * the SNOOP (bus) path  - transactions issued by OTHER caches, observed on
//     the shared bus, which may downgrade or invalidate our lines and may force
//     us to supply (flush) dirty data.
//
// Ordering rules implemented here (see README for the full rationale):
//
//   1. The snoop port owns the arrays. A CPU access whose SET is being snooped
//      this cycle is deferred one cycle (cpu_ready stays low; the core retries).
//      That removes every array write conflict in the IDLE state and gives the
//      bus transaction the earlier position in the coherence order.
//   2. This is a SPLIT-TRANSACTION bus: snoops keep arriving while our own
//      request is outstanding. A replacement therefore invalidates its victim
//      BEFORE the fill starts, so we never answer a snoop for a line we have
//      already given up.
//   3. An invalidating snoop (BusRdX / BusUpgr) that hits the line of an
//      in-flight BusUpgr makes us LOSE the upgrade race. The upgrade completes
//      on the bus but is not honoured locally; it is retried as a BusRdX. This
//      is the one genuinely racy corner of MESI and it is modelled explicitly.
//
// Block size is one word so the protocol - not the burst plumbing - is the
// subject; the Day7 / Day23 caches already cover multi-word line fills, and the
// two are orthogonal.
//
// Fully synthesizable: no variable bit-selects, single always_ff per state
// element, synchronous-write / combinational-read arrays, reset-safe.
// -----------------------------------------------------------------------------

`timescale 1ns / 1ps

module mesi_cache #(
    parameter int ADDR_W = 32,      // byte address width
    parameter int DATA_W = 32,      // word width == coherence block size
    parameter int LINES  = 8,       // direct-mapped lines (power of two)
    // ---- derived; do not override ----
    parameter int IDX_W  = $clog2(LINES),
    parameter int TAG_W  = ADDR_W - IDX_W - 2
) (
    input  logic                     clk,
    input  logic                     rst_n,

    // ---------------- CPU side (one outstanding access, held until ready) ----
    input  logic                     cpu_req,
    input  logic                     cpu_we,
    input  logic [ADDR_W-1:0]        cpu_addr,
    input  logic [DATA_W-1:0]        cpu_wdata,
    output logic [DATA_W-1:0]        cpu_rdata,   // value of the word at completion
    output logic                     cpu_ready,   // high in the completing cycle

    // ---------------- Bus master side (this cache requesting) ---------------
    output logic                     bus_req,
    output logic [1:0]               bus_cmd,     // CMD_RD / RDX / UPGR / WB
    output logic [ADDR_W-1:0]        bus_addr,
    output logic [DATA_W-1:0]        bus_wdata,   // write-back data (CMD_WB)
    input  logic                     bus_done,    // transaction completes this cycle
    input  logic [DATA_W-1:0]        bus_rdata,   // fill data (CMD_RD / CMD_RDX)
    input  logic                     bus_shared,  // another cache holds a copy

    // ---------------- Snoop side (other caches' transactions) ---------------
    input  logic                     snp_valid,
    input  logic [1:0]               snp_cmd,
    input  logic [ADDR_W-1:0]        snp_addr,
    output logic                     snp_hit,     // I hold this line
    output logic                     snp_shared,  // -> requester must take S, not E
    output logic                     snp_flush,   // I am supplying dirty data
    output logic [DATA_W-1:0]        snp_data,

    // ---------------- Observability (verification / waveform only) ----------
    output logic [2*LINES-1:0]       dbg_state,
    output logic [TAG_W*LINES-1:0]   dbg_tag,
    output logic [DATA_W*LINES-1:0]  dbg_data,
    output logic [1:0]               dbg_fsm
);

    // ---- MESI line states ----
    localparam logic [1:0] ST_I = 2'b00;
    localparam logic [1:0] ST_S = 2'b01;
    localparam logic [1:0] ST_E = 2'b10;
    localparam logic [1:0] ST_M = 2'b11;

    // ---- Bus commands ----
    localparam logic [1:0] CMD_RD   = 2'b00;   // read, want a (shared or excl.) copy
    localparam logic [1:0] CMD_RDX  = 2'b01;   // read-for-ownership (write miss)
    localparam logic [1:0] CMD_UPGR = 2'b10;   // I already have S, invalidate the rest
    localparam logic [1:0] CMD_WB   = 2'b11;   // dirty write-back to memory

    // ---- Miss-handling FSM ----
    localparam logic [1:0] F_IDLE = 2'b00;
    localparam logic [1:0] F_WB   = 2'b01;     // flushing the dirty victim
    localparam logic [1:0] F_FILL = 2'b10;     // BusRd / BusRdX outstanding
    localparam logic [1:0] F_UPGR = 2'b11;     // BusUpgr outstanding

    // -------------------------------------------------------------------------
    // Arrays
    // -------------------------------------------------------------------------
    logic [1:0]        st_q  [0:LINES-1];
    logic [TAG_W-1:0]  tag_q [0:LINES-1];
    logic [DATA_W-1:0] dat_q [0:LINES-1];

    // -------------------------------------------------------------------------
    // Miss-handling state
    // -------------------------------------------------------------------------
    logic [1:0]        fsm_q;
    logic [ADDR_W-1:0] pend_addr_q;    // address of the access being serviced
    logic [DATA_W-1:0] pend_wdata_q;   // store data being serviced
    logic              pend_we_q;      // 1 = store (needs ownership)
    logic              upgr_lost_q;    // an in-flight BusUpgr lost its race
    logic [ADDR_W-1:0] wb_addr_q;      // dirty victim address
    logic [DATA_W-1:0] wb_data_q;      // dirty victim data

    // -------------------------------------------------------------------------
    // Address decode (all constant part-selects)
    // -------------------------------------------------------------------------
    logic [IDX_W-1:0] c_idx, p_idx, s_idx;
    logic [TAG_W-1:0] c_tag, p_tag, s_tag;

    assign c_idx = cpu_addr   [IDX_W+1:2];
    assign c_tag = cpu_addr   [ADDR_W-1:IDX_W+2];
    assign p_idx = pend_addr_q[IDX_W+1:2];
    assign p_tag = pend_addr_q[ADDR_W-1:IDX_W+2];
    assign s_idx = snp_addr   [IDX_W+1:2];
    assign s_tag = snp_addr   [ADDR_W-1:IDX_W+2];

    // -------------------------------------------------------------------------
    // Snoop response - purely combinational from the arrays.
    //
    //   snp_shared tells the requester of a BusRd "somebody else has it", which
    //   is exactly the wire that decides whether THEY end up in E or in S.
    //   snp_flush means we are the sole owner of dirty data and must supply it;
    //   a BusUpgr can never hit an M line (its issuer was in S, so no other
    //   cache can be in M), so upgrades never provoke a flush.
    // -------------------------------------------------------------------------
    logic       s_coh;          // a coherence transaction (write-backs are ignored)
    logic       s_line_hit;
    logic [1:0] s_st;

    assign s_coh      = snp_valid && (snp_cmd != CMD_WB);
    assign s_st       = st_q[s_idx];
    assign s_line_hit = s_coh && (s_st != ST_I) && (tag_q[s_idx] == s_tag);

    assign snp_hit    = s_line_hit;
    assign snp_shared = s_line_hit && (snp_cmd == CMD_RD);
    assign snp_flush  = s_line_hit && (s_st == ST_M) && (snp_cmd != CMD_UPGR);
    assign snp_data   = dat_q[s_idx];

    // -------------------------------------------------------------------------
    // Local lookup
    // -------------------------------------------------------------------------
    logic [1:0] c_st;
    logic       c_hit;
    logic       cpu_blocked;   // rule 1: the snoop port owns this set this cycle
    logic       upgr_killed;   // rule 3: our pending upgrade just lost the race

    assign c_st        = st_q[c_idx];
    assign c_hit       = (c_st != ST_I) && (tag_q[c_idx] == c_tag);
    assign cpu_blocked = s_line_hit && (s_idx == c_idx);
    assign upgr_killed = s_line_hit && (snp_cmd != CMD_RD) && (s_idx == p_idx);

    // -------------------------------------------------------------------------
    // Combinational outputs
    // -------------------------------------------------------------------------
    always_comb begin
        bus_req   = 1'b0;
        bus_cmd   = CMD_RD;
        bus_addr  = '0;
        bus_wdata = '0;
        cpu_ready = 1'b0;
        cpu_rdata = '0;

        case (fsm_q)
            // A hit completes in the access cycle. A store hit needs write
            // permission: M and E already have it (E -> M is silent), S does not.
            F_IDLE: begin
                if (cpu_req && !cpu_blocked && c_hit &&
                    (!cpu_we || (c_st != ST_S))) begin
                    cpu_ready = 1'b1;
                    cpu_rdata = cpu_we ? cpu_wdata : dat_q[c_idx];
                end
            end

            F_WB: begin
                bus_req   = 1'b1;
                bus_cmd   = CMD_WB;
                bus_addr  = wb_addr_q;
                bus_wdata = wb_data_q;
            end

            F_FILL: begin
                bus_req  = 1'b1;
                bus_cmd  = pend_we_q ? CMD_RDX : CMD_RD;
                bus_addr = pend_addr_q;
                if (bus_done) begin
                    cpu_ready = 1'b1;
                    cpu_rdata = pend_we_q ? pend_wdata_q : bus_rdata;
                end
            end

            F_UPGR: begin
                bus_req  = 1'b1;
                bus_cmd  = CMD_UPGR;
                bus_addr = pend_addr_q;
                if (bus_done && !(upgr_lost_q || upgr_killed)) begin
                    cpu_ready = 1'b1;
                    cpu_rdata = pend_wdata_q;
                end
            end

            default: ;
        endcase
    end

    // -------------------------------------------------------------------------
    // State update
    //
    // The snoop transition is written FIRST and the local transition second, so
    // on the one reachable collision (a BusRd downgrade landing in the same
    // cycle a BusUpgr completes) the local completion wins and the line becomes
    // M. That is the correct outcome: our upgrade is later in the bus order and
    // invalidates the copy the snooper just took.
    // -------------------------------------------------------------------------
    integer i;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (i = 0; i < LINES; i = i + 1) begin
                st_q [i] <= ST_I;
                tag_q[i] <= '0;
                dat_q[i] <= '0;
            end
            fsm_q        <= F_IDLE;
            pend_addr_q  <= '0;
            pend_wdata_q <= '0;
            pend_we_q    <= 1'b0;
            upgr_lost_q  <= 1'b0;
            wb_addr_q    <= '0;
            wb_data_q    <= '0;
        end else begin
            // ---- 1. snoop: remote transaction observed on the bus ----------
            //   BusRd  : M -> S (after flushing), E -> S, S -> S
            //   BusRdX : any -> I
            //   BusUpgr: any -> I
            if (s_line_hit) begin
                if (snp_cmd == CMD_RD) st_q[s_idx] <= ST_S;
                else                   st_q[s_idx] <= ST_I;
            end

            // ---- 2. local access ------------------------------------------
            case (fsm_q)
                F_IDLE: begin
                    if (cpu_req && !cpu_blocked) begin
                        if (c_hit) begin
                            if (cpu_we) begin
                                if (c_st == ST_S) begin
                                    // shared copy: must invalidate the others
                                    pend_addr_q  <= cpu_addr;
                                    pend_wdata_q <= cpu_wdata;
                                    pend_we_q    <= 1'b1;
                                    upgr_lost_q  <= 1'b0;
                                    fsm_q        <= F_UPGR;
                                end else begin
                                    // E or M: write in place, E -> M silently
                                    dat_q[c_idx] <= cpu_wdata;
                                    st_q [c_idx] <= ST_M;
                                end
                            end
                            // load hit: no state change (S/E/M all serve reads)
                        end else begin
                            // miss: the replacement invalidates its victim now,
                            // so no snoop can hit a line we are giving up.
                            pend_addr_q  <= cpu_addr;
                            pend_wdata_q <= cpu_wdata;
                            pend_we_q    <= cpu_we;
                            st_q[c_idx]  <= ST_I;
                            if (c_st == ST_M) begin
                                wb_addr_q <= {tag_q[c_idx], c_idx, 2'b00};
                                wb_data_q <= dat_q[c_idx];
                                fsm_q     <= F_WB;
                            end else begin
                                fsm_q     <= F_FILL;
                            end
                        end
                    end
                end

                F_WB: begin
                    if (bus_done) fsm_q <= F_FILL;
                end

                F_FILL: begin
                    if (bus_done) begin
                        tag_q[p_idx] <= p_tag;
                        dat_q[p_idx] <= pend_we_q ? pend_wdata_q : bus_rdata;
                        // A store fill owns the line outright. A load fill takes
                        // E when no other cache answered, S when one did - the
                        // Illinois-protocol distinction that makes E possible.
                        st_q [p_idx] <= pend_we_q ? ST_M
                                                  : (bus_shared ? ST_S : ST_E);
                        fsm_q        <= F_IDLE;
                    end
                end

                F_UPGR: begin
                    if (bus_done) begin
                        if (upgr_lost_q || upgr_killed) begin
                            // somebody invalidated us first: the upgrade is void,
                            // retry as a read-for-ownership (pend_we_q is set).
                            upgr_lost_q <= 1'b0;
                            fsm_q       <= F_FILL;
                        end else begin
                            dat_q[p_idx] <= pend_wdata_q;
                            st_q [p_idx] <= ST_M;
                            fsm_q        <= F_IDLE;
                        end
                    end else if (upgr_killed) begin
                        upgr_lost_q <= 1'b1;
                    end
                end

                default: ;
            endcase
        end
    end

    // -------------------------------------------------------------------------
    // Flattened observability
    // -------------------------------------------------------------------------
    genvar gi;
    generate
        for (gi = 0; gi < LINES; gi = gi + 1) begin : g_dbg
            assign dbg_state[2*gi      +: 2]      = st_q [gi];
            assign dbg_tag  [TAG_W*gi  +: TAG_W]  = tag_q[gi];
            assign dbg_data [DATA_W*gi +: DATA_W] = dat_q[gi];
        end
    endgenerate

    assign dbg_fsm = fsm_q;

endmodule
