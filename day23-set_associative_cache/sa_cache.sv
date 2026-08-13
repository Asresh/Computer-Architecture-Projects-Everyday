// sa_cache.sv - Day23
//
// N-way SET-ASSOCIATIVE, write-back, write-allocate data cache with
// tree-based PSEUDO-LRU (tree-PLRU) replacement -- the associative memory
// hierarchy that Day7's direct-mapped cache grows into, and the replacement
// policy real CPUs actually ship (Intel/ARM L1/L2 use a PLRU tree, not a full
// true-LRU age matrix, because the tree costs only WAYS-1 bits per set).
//
// The cache sits between a CPU (single word-wide request + ready handshake)
// and a slower main memory (one word per burst beat). Storage is NUM_SETS
// sets x WAYS ways, BLOCK_WORDS words per line. A word address is split as:
//
//     | tag ............ | index ...... | offset ... |
//      ADDR_BITS-1 ....             ....        1   0
//
//     offset = addr[OFFSET_BITS-1 : 0]              (word within a block)
//     index  = addr[OFFSET_BITS +: INDEX_BITS]      (which SET)
//     tag    = addr[OFFSET_BITS+INDEX_BITS +: TAG]  (identity within the set)
//
// Set-associative vs. direct-mapped: an address maps to one SET but may live
// in ANY of the set's WAYS. A lookup compares the tag against all WAYS in
// parallel (associative search). On a miss the cache must CHOOSE which way to
// evict -- that choice is the replacement policy.
//
// Tree-PLRU replacement (per set, WAYS-1 bits):
//   The WAYS lines are the leaves of a balanced binary tree; each of the
//   WAYS-1 internal nodes holds one bit that points toward the pseudo-LRU
//   subtree (0 = left, 1 = right).
//     * VICTIM  : walk root->leaf always following the node bit -> a leaf way.
//     * TOUCH w : walk root->leaf toward w, and at every node set the bit to
//                 point AWAY from w (marking w most-recently-used).
//   One tree walk (log2(WAYS) steps) does either job. Invalid ways are filled
//   before any valid way is evicted (cold-miss preference).
//
// Policies (same family as Day7): write-allocate (a store miss fetches the
// block first, then writes the word) and write-back (a store only sets dirty;
// the block is flushed lazily on eviction).
//
// Miss-handling FSM (one main-memory word per beat):
//
//     IDLE -> LOOKUP -+-- hit -----------------------------> IDLE (ready, hit=1)
//                     |
//                     +-- miss, victim clean --> ALLOCATE --+
//                     |                                      |
//                     +-- miss, victim dirty --> WRITEBACK --+-> ALLOCATE -> LOOKUP
//
// After ALLOCATE the block is resident, so the FSM re-enters LOOKUP, which now
// hits and completes the original access (ready, hit=0 -- the access missed).
//
// Synthesizable, reset-safe, parameterized, and lint clean. No variable
// bit-selects on the tree (fixed-node walk unrolled by a genvar-free loop over
// a constant number of levels).

`timescale 1ns/1ps

module sa_cache #(
    parameter int ADDR_BITS   = 12, // CPU / main-memory WORD address width
    parameter int WORD_BITS   = 32, // data word width
    parameter int BLOCK_WORDS = 4,  // words per line   (>= 2, power of 2)
    parameter int NUM_SETS    = 4,  // number of sets   (power of 2)
    parameter int WAYS        = 4   // associativity    (>= 2, power of 2)
) (
    input  logic                 clk,
    input  logic                 rst_n,

    // ---- CPU side (word request + ready handshake) ----
    input  logic                 cpu_req,   // pulse: start an access when IDLE
    input  logic                 cpu_we,    // 1 = store, 0 = load
    input  logic [ADDR_BITS-1:0] cpu_addr,  // word address
    input  logic [WORD_BITS-1:0] cpu_wdata, // store data
    output logic [WORD_BITS-1:0] cpu_rdata, // load data (valid with cpu_ready)
    output logic                 cpu_ready, // 1-cycle pulse: access complete
    output logic                 cpu_hit,   // with cpu_ready: 1 = hit, 0 = miss

    // ---- Main-memory side (word-at-a-time burst port) ----
    output logic                 mem_req,   // request a beat
    output logic                 mem_we,    // 1 = write-back beat, 0 = refill
    output logic [ADDR_BITS-1:0] mem_addr,  // word address of this beat
    output logic [WORD_BITS-1:0] mem_wdata, // write-back data (mem_we=1)
    input  logic [WORD_BITS-1:0] mem_rdata, // refill data     (mem_we=0)
    input  logic                 mem_ready, // beat accepted / data valid

    // ---- Debug / observability (for the waveform) ----
    output logic [1:0]           dbg_state, // 0 IDLE 1 LOOKUP 2 WR-BACK 3 ALLOC
    output logic [7:0]           dbg_way    // way hit or allocated this access
);

    // ---------------- derived address geometry ----------------
    localparam int OFFSET_BITS = (BLOCK_WORDS <= 1) ? 1 : $clog2(BLOCK_WORDS);
    localparam int INDEX_BITS  = (NUM_SETS    <= 1) ? 1 : $clog2(NUM_SETS);
    localparam int WAY_BITS    = (WAYS        <= 1) ? 1 : $clog2(WAYS);
    localparam int TAG_BITS    = ADDR_BITS - INDEX_BITS - OFFSET_BITS;
    localparam int LAST_BEAT   = BLOCK_WORDS - 1;

    // ---------------- FSM state encoding ----------------
    localparam logic [1:0] S_IDLE = 2'd0,
                           S_LOOK = 2'd1,
                           S_WB   = 2'd2,
                           S_ALLOC= 2'd3;

    // ---------------- cache storage ----------------
    logic                 valid [NUM_SETS][WAYS];
    logic                 dirty [NUM_SETS][WAYS];
    logic [TAG_BITS-1:0]  tag_a [NUM_SETS][WAYS];
    logic [WORD_BITS-1:0] data_a[NUM_SETS][WAYS][BLOCK_WORDS];
    logic [WAYS-2:0]      plru  [NUM_SETS];              // tree-PLRU node bits

    // ---------------- latched request + FSM regs ----------------
    logic [1:0]            state;
    logic                  req_we;
    logic [ADDR_BITS-1:0]  req_addr;
    logic [WORD_BITS-1:0]  req_wdata;
    logic [WAY_BITS-1:0]   victim_way;   // way being (evicted &) refilled
    logic                  miss_seen;    // this access took the miss path
    logic [OFFSET_BITS:0]  beat;         // burst beat counter (0..BLOCK_WORDS)
    logic [TAG_BITS-1:0]   wb_tag;       // tag of the dirty victim being flushed

    // ---------------- request field slices ----------------
    logic [OFFSET_BITS-1:0] req_off;
    logic [INDEX_BITS-1:0]  req_idx;
    logic [TAG_BITS-1:0]    req_tag;
    assign req_off = req_addr[OFFSET_BITS-1:0];
    assign req_idx = req_addr[OFFSET_BITS +: INDEX_BITS];
    assign req_tag = req_addr[OFFSET_BITS+INDEX_BITS +: TAG_BITS];

    // ================= combinational lookup =================
    logic                hit;
    logic [WAY_BITS-1:0] hit_way;
    always_comb begin
        hit     = 1'b0;
        hit_way = '0;
        for (int w = 0; w < WAYS; w++) begin
            if (valid[req_idx][w] && (tag_a[req_idx][w] == req_tag)) begin
                hit     = 1'b1;
                hit_way = w[WAY_BITS-1:0];
            end
        end
    end

    // ================= tree-PLRU helpers =================
    // Victim = walk root->leaf following each node bit (0 left, 1 right).
    function automatic logic [WAY_BITS-1:0] plru_victim(input logic [WAYS-2:0] tr);
        int node;
        logic [WAY_BITS-1:0] w;
        logic b;
        node = 0;
        w    = '0;
        for (int lvl = 0; lvl < WAY_BITS; lvl++) begin
            b    = tr[node];
            w    = (w << 1) | b;            // path bits (MSB first) = leaf index
            node = 2*node + 1 + (b ? 1 : 0);
        end
        return w;
    endfunction

    // Touch = walk toward way `w`, set every node on the path AWAY from w.
    function automatic logic [WAYS-2:0] plru_touch(input logic [WAYS-2:0] tr,
                                                   input logic [WAY_BITS-1:0] w);
        int node;
        logic b;
        logic [WAYS-2:0] nt;
        nt   = tr;
        node = 0;
        for (int lvl = 0; lvl < WAY_BITS; lvl++) begin
            b        = w[WAY_BITS-1-lvl];   // 0 = go left, 1 = go right
            nt[node] = ~b;                  // point victim path away from w
            node     = 2*node + 1 + (b ? 1 : 0);
        end
        return nt;
    endfunction

    // Victim choice: fill an invalid way first, else PLRU pseudo-LRU way.
    logic                have_free;
    logic [WAY_BITS-1:0] free_way;
    logic [WAY_BITS-1:0] sel_victim;
    always_comb begin
        have_free = 1'b0;
        free_way  = '0;
        for (int w = 0; w < WAYS; w++) begin
            if (!valid[req_idx][w] && !have_free) begin
                have_free = 1'b1;
                free_way  = w[WAY_BITS-1:0];
            end
        end
        sel_victim = have_free ? free_way : plru_victim(plru[req_idx]);
    end

    // Word address of the first beat of a block, given set index + tag.
    function automatic logic [ADDR_BITS-1:0] block_base(input logic [TAG_BITS-1:0] t);
        logic [ADDR_BITS-1:0] a;
        a = '0;
        a[OFFSET_BITS +: INDEX_BITS]           = req_idx;
        a[OFFSET_BITS+INDEX_BITS +: TAG_BITS]  = t;
        return a;
    endfunction

    // ================= memory-port outputs (comb) =================
    always_comb begin
        mem_req   = 1'b0;
        mem_we    = 1'b0;
        mem_addr  = '0;
        mem_wdata = '0;
        unique case (state)
            S_WB: begin
                mem_req   = 1'b1;
                mem_we    = 1'b1;
                mem_addr  = block_base(wb_tag) + beat;
                mem_wdata = data_a[req_idx][victim_way][beat[OFFSET_BITS-1:0]];
            end
            S_ALLOC: begin
                mem_req  = 1'b1;
                mem_we   = 1'b0;
                mem_addr = block_base(req_tag) + beat;
            end
            default: ; // IDLE / LOOKUP drive nothing on the memory port
        endcase
    end

    assign dbg_state = state;

    // ================= sequential control =================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state      <= S_IDLE;
            cpu_ready  <= 1'b0;
            cpu_hit    <= 1'b0;
            cpu_rdata  <= '0;
            miss_seen  <= 1'b0;
            beat       <= '0;
            victim_way <= '0;
            wb_tag     <= '0;
            dbg_way    <= '0;
            req_we     <= 1'b0;
            req_addr   <= '0;
            req_wdata  <= '0;
            for (int s = 0; s < NUM_SETS; s++) begin
                plru[s] <= '0;
                for (int w = 0; w < WAYS; w++) begin
                    valid[s][w] <= 1'b0;
                    dirty[s][w] <= 1'b0;
                    tag_a[s][w] <= '0;
                    for (int k = 0; k < BLOCK_WORDS; k++)
                        data_a[s][w][k] <= '0;
                end
            end
        end else begin
            cpu_ready <= 1'b0; // default: single-cycle pulse

            unique case (state)
                // -------- accept a new CPU request --------
                S_IDLE: begin
                    if (cpu_req) begin
                        req_we    <= cpu_we;
                        req_addr  <= cpu_addr;
                        req_wdata <= cpu_wdata;
                        miss_seen <= 1'b0;
                        state     <= S_LOOK;
                    end
                end

                // -------- associative tag compare --------
                S_LOOK: begin
                    if (hit) begin
                        // Complete the access on the hitting way.
                        dbg_way        <= {{(8-WAY_BITS){1'b0}}, hit_way};
                        plru[req_idx]  <= plru_touch(plru[req_idx], hit_way);
                        if (req_we) begin
                            data_a[req_idx][hit_way][req_off] <= req_wdata;
                            dirty[req_idx][hit_way]           <= 1'b1;
                        end else begin
                            cpu_rdata <= data_a[req_idx][hit_way][req_off];
                        end
                        cpu_hit   <= ~miss_seen;
                        cpu_ready <= 1'b1;
                        state     <= S_IDLE;
                    end else begin
                        // Miss: pick a victim, flush it if dirty, else refill.
                        miss_seen  <= 1'b1;
                        victim_way <= sel_victim;
                        beat       <= '0;
                        if (valid[req_idx][sel_victim] &&
                            dirty[req_idx][sel_victim]) begin
                            wb_tag <= tag_a[req_idx][sel_victim];
                            state  <= S_WB;
                        end else begin
                            state  <= S_ALLOC;
                        end
                    end
                end

                // -------- flush dirty victim to memory --------
                S_WB: begin
                    if (mem_ready) begin
                        if (beat == LAST_BEAT[OFFSET_BITS:0]) begin
                            beat  <= '0;
                            state <= S_ALLOC;
                        end else begin
                            beat <= beat + 1'b1;
                        end
                    end
                end

                // -------- refill the requested block --------
                S_ALLOC: begin
                    if (mem_ready) begin
                        data_a[req_idx][victim_way][beat[OFFSET_BITS-1:0]] <= mem_rdata;
                        if (beat == LAST_BEAT[OFFSET_BITS:0]) begin
                            // block now resident: install tag, clean & valid.
                            tag_a[req_idx][victim_way] <= req_tag;
                            valid[req_idx][victim_way] <= 1'b1;
                            dirty[req_idx][victim_way] <= 1'b0;
                            beat                       <= '0;
                            state                      <= S_LOOK; // re-lookup -> hit
                        end else begin
                            beat <= beat + 1'b1;
                        end
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
