// dm_cache.sv - Day7
//
// Direct-mapped, write-back, write-allocate data cache with an explicit
// miss-handling FSM -- the canonical textbook cache every memory-hierarchy
// chapter builds first.
//
// The cache sits between a CPU (single word-wide request port with a ready
// handshake) and a slower main memory (word-at-a-time burst port). It holds
// NUM_LINES lines of BLOCK_WORDS words each. A word address is split as:
//
//     | tag ............ | index ...... | offset ... |
//      ADDR_BITS-1 ....             ....        1   0
//
//     offset = addr[OFFSET_BITS-1 : 0]              (word within a block)
//     index  = addr[OFFSET_BITS +: INDEX_BITS]      (which line)
//     tag    = addr[OFFSET_BITS+INDEX_BITS +: TAG]  (identity check)
//
// Policies:
//   * Direct-mapped     - each address maps to exactly one line (index).
//   * Write-allocate    - a store that misses first fetches the block, then
//                         writes the word into the cache (never straight to
//                         memory).
//   * Write-back        - a store only marks the line dirty; the block is
//                         flushed to memory lazily, when it is evicted.
//
// Miss-handling FSM (one main-memory word per beat):
//
//     IDLE -> LOOKUP -+-- hit ----------------------------> IDLE (assert ready)
//                     |
//                     +-- miss, victim clean --> ALLOCATE --+
//                     |                                      |
//                     +-- miss, victim dirty --> WRITEBACK --+--> ALLOCATE --> LOOKUP
//
// After ALLOCATE the line is present, so the FSM re-enters LOOKUP, which now
// hits and completes the original access (read data out, or store the word
// and set dirty). Write-back happens only for a valid+dirty victim.
//
// The main-memory port is combinational-address / registered-write and works
// with a single-cycle-ready memory (mem_ready held while mem_req) but also
// tolerates a memory that stalls mem_ready.
//
// Synthesizable, reset-safe, parameterized, and lint clean.

`timescale 1ns/1ps

module dm_cache #(
    parameter int ADDR_BITS   = 12, // CPU/main-memory WORD address width
    parameter int WORD_BITS   = 32, // data word width
    parameter int BLOCK_WORDS = 4,  // words per cache line (>= 2, power of 2)
    parameter int NUM_LINES   = 8   // number of lines (power of 2)
) (
    input  logic                 clk,
    input  logic                 rst_n,

    // ---- CPU side (word request + ready handshake) ----
    input  logic                 cpu_req,    // pulse: start an access when in IDLE
    input  logic                 cpu_we,     // 1 = store, 0 = load
    input  logic [ADDR_BITS-1:0] cpu_addr,   // word address
    input  logic [WORD_BITS-1:0] cpu_wdata,  // store data
    output logic [WORD_BITS-1:0] cpu_rdata,  // load data (valid with cpu_ready)
    output logic                 cpu_ready,  // 1-cycle pulse: access complete
    output logic                 cpu_hit,    // last completed access hit in cache

    // ---- Main-memory side (word burst) ----
    output logic                 mem_req,    // request active
    output logic                 mem_we,     // 1 = write-back beat, 0 = refill beat
    output logic [ADDR_BITS-1:0] mem_addr,   // word address of the current beat
    output logic [WORD_BITS-1:0] mem_wdata,  // write-back data
    input  logic [WORD_BITS-1:0] mem_rdata,  // refill data
    input  logic                 mem_ready,  // memory accepted/produced this beat

    // ---- Debug / observation taps (for waveform + verification) ----
    output logic [1:0]           dbg_state
);

    // ---- Derived geometry ----
    localparam int OFFSET_BITS = $clog2(BLOCK_WORDS);
    localparam int INDEX_BITS  = $clog2(NUM_LINES);
    localparam int TAG_BITS    = ADDR_BITS - INDEX_BITS - OFFSET_BITS;

    // ---- Storage arrays ----
    logic [WORD_BITS-1:0] data  [NUM_LINES-1:0][BLOCK_WORDS-1:0];
    logic [TAG_BITS-1:0]  tags  [NUM_LINES-1:0];
    logic                 valid [NUM_LINES-1:0];
    logic                 dirty [NUM_LINES-1:0];

    // ---- Latched request (stable for the whole transaction) ----
    logic [ADDR_BITS-1:0] req_addr;
    logic                 req_we;
    logic [WORD_BITS-1:0] req_wdata;

    wire [OFFSET_BITS-1:0] req_off = req_addr[OFFSET_BITS-1:0];
    wire [INDEX_BITS-1:0]  req_idx = req_addr[OFFSET_BITS +: INDEX_BITS];
    wire [TAG_BITS-1:0]    req_tag = req_addr[OFFSET_BITS+INDEX_BITS +: TAG_BITS];

    // ---- Beat counter for burst write-back / refill ----
    logic [OFFSET_BITS:0] cnt;
    wire [OFFSET_BITS-1:0] beat = cnt[OFFSET_BITS-1:0]; // word-within-block
    wire  last_beat = (cnt == BLOCK_WORDS - 1);

    // Remembers whether the in-flight access needed miss handling, so that
    // cpu_hit reports the ORIGINAL access outcome (not the post-allocate
    // re-lookup, which always hits).
    logic miss_seen;

    // ---- FSM ----
    localparam logic [1:0] S_IDLE      = 2'd0,
                           S_LOOKUP    = 2'd1,
                           S_WRITEBACK = 2'd2,
                           S_ALLOCATE  = 2'd3;
    logic [1:0] state;
    assign dbg_state = state;

    // Hit when the indexed line is valid and its tag matches the request.
    wire hit = valid[req_idx] && (tags[req_idx] == req_tag);

    // ---- Main-memory port (combinational address, per-state) ----
    always_comb begin
        mem_req   = 1'b0;
        mem_we    = 1'b0;
        mem_addr  = '0;
        mem_wdata = '0;
        unique case (state)
            S_WRITEBACK: begin
                // Flush the victim block to its OLD address {victim tag,index}.
                mem_req   = 1'b1;
                mem_we    = 1'b1;
                mem_addr  = {tags[req_idx], req_idx, beat};
                mem_wdata = data[req_idx][beat];
            end
            S_ALLOCATE: begin
                // Refill the requested block from {req tag, index}.
                mem_req   = 1'b1;
                mem_we    = 1'b0;
                mem_addr  = {req_tag, req_idx, beat};
            end
            default: begin
                mem_req = 1'b0;
            end
        endcase
    end

    // ---- Sequential control + storage update ----
    integer i;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state     <= S_IDLE;
            cpu_ready <= 1'b0;
            cpu_hit   <= 1'b0;
            cpu_rdata <= '0;
            cnt       <= '0;
            miss_seen <= 1'b0;
            req_addr  <= '0;
            req_we    <= 1'b0;
            req_wdata <= '0;
            for (i = 0; i < NUM_LINES; i = i + 1) begin
                valid[i] <= 1'b0;
                dirty[i] <= 1'b0;
                tags[i]  <= '0;
            end
        end else begin
            cpu_ready <= 1'b0; // default: single-cycle completion pulse
            unique case (state)
                // ---- Wait for a CPU request ----
                S_IDLE: begin
                    if (cpu_req) begin
                        req_addr  <= cpu_addr;
                        req_we    <= cpu_we;
                        req_wdata <= cpu_wdata;
                        miss_seen <= 1'b0;
                        state     <= S_LOOKUP;
                    end
                end

                // ---- Compare tag; complete on hit, else start a miss ----
                S_LOOKUP: begin
                    if (hit) begin
                        cpu_hit <= ~miss_seen; // true only if no refill was needed
                        if (req_we) begin
                            data[req_idx][req_off] <= req_wdata;
                            dirty[req_idx]         <= 1'b1;
                            cpu_rdata              <= req_wdata;
                        end else begin
                            cpu_rdata <= data[req_idx][req_off];
                        end
                        cpu_ready <= 1'b1;
                        state     <= S_IDLE;
                    end else begin
                        miss_seen <= 1'b1;
                        cnt       <= '0;
                        // Dirty victim must be written back before refill.
                        if (valid[req_idx] && dirty[req_idx])
                            state <= S_WRITEBACK;
                        else
                            state <= S_ALLOCATE;
                    end
                end

                // ---- Burst the dirty victim out to memory ----
                S_WRITEBACK: begin
                    if (mem_ready) begin
                        if (last_beat) begin
                            cnt   <= '0;
                            state <= S_ALLOCATE;
                        end else begin
                            cnt <= cnt + 1'b1;
                        end
                    end
                end

                // ---- Burst the requested block in from memory ----
                S_ALLOCATE: begin
                    if (mem_ready) begin
                        data[req_idx][beat] <= mem_rdata;
                        if (last_beat) begin
                            valid[req_idx] <= 1'b1;
                            tags[req_idx]  <= req_tag;
                            dirty[req_idx] <= 1'b0;
                            cnt            <= '0;
                            // Line is present now: re-lookup and complete.
                            state          <= S_LOOKUP;
                        end else begin
                            cnt <= cnt + 1'b1;
                        end
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
