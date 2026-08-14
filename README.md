# Computer Architecture Projects — Everyday

A daily series of self-contained computer-architecture projects in SystemVerilog. One documented, simulate-able architecture design per day.

Each day lives in its own folder containing a self-contained project with source, a self-checking testbench, a Makefile, a waveform image, and a README write-up.

## Index

| Day | Project | Description | Folder |
|-----|---------|--------------|--------|
| 1 | Single-Cycle RISC-V (RV32I) Integer ALU | A combinational ALU implementing the RV32I integer op set, with signed/unsigned compare and logical/arithmetic shifts. | [day01-integer_alu](day01-integer_alu/) |
| 2 | RV32I Register File (2R / 1W) | The processor's architectural register state: dual combinational read ports, synchronous write, `x0` hardwired to zero, and write-forwarding for same-cycle hazards. | [day02-register_file](day02-register_file/) |
| 3 | RV32I Instruction Decoder + Immediate Generator | Combinational control decode of opcode/funct3/funct7 into datapath control signals, plus I/S/B/U/J immediate generation. | [day03-instruction_decoder](day03-instruction_decoder/) |
| 4 | RV32I Load/Store Unit + Data Memory | A byte-addressable little-endian data memory supporting all RV32I load/store variants with byte-lane selection and sign/zero extension. | [day04-load_store_unit](day04-load_store_unit/) |
| 5 | Single-Cycle RV32I Core | The Day 1–4 blocks integrated into a working single-cycle processor, checked against an independent instruction-set-simulator golden trace. | [day05-single_cycle_core](day05-single_cycle_core/) |
| 6 | Bimodal 2-bit Saturating-Counter Branch Predictor | A dynamic branch predictor built from a PC-indexed Pattern History Table of 2-bit saturating counters — the classic bimodal baseline. | [day06-bimodal_branch_predictor](day06-bimodal_branch_predictor/) |
| 7 | Direct-Mapped Write-Back / Write-Allocate Data Cache | A textbook direct-mapped cache with a full miss-handling FSM, dirty-bit write-back, and write-allocate on store misses. | [day07-direct_mapped_cache](day07-direct_mapped_cache/) |
| 8 | Radix-4 (Modified) Booth Signed Sequential Multiplier | A parameterized signed multiplier using modified Booth recoding and an add/shift datapath with a start/busy/done handshake. | [day08-booth_multiplier](day08-booth_multiplier/) |
| 9 | Round-Robin (Rotating-Priority) Arbiter | An N-requester arbiter that grants a shared resource fairly cycle by cycle, with a provable no-starvation bound. | [day09-round_robin_arbiter](day09-round_robin_arbiter/) |
| 10 | Fully-Associative TLB with True-LRU Replacement | A parameterized TLB doing VPN→PPN translation via parallel CAM lookup, with true-LRU replacement and sfence support. | [day10-fully_associative_tlb](day10-fully_associative_tlb/) |
| 11 | Store Buffer with Store-to-Load Forwarding | An in-order store queue that lets stores retire before reaching memory and forwards data to younger matching loads. | [day11-store_buffer](day11-store_buffer/) |
| 12 | Reorder Buffer (Out-of-Order Complete, In-Order Retire) | The ROB structure that lets instructions execute out of order while committing architectural state strictly in program order. | [day12-reorder_buffer](day12-reorder_buffer/) |
| 13 | Output-Stationary Systolic Array (Matrix-Multiply MAC Grid) | An N×N grid of MAC processing elements computing a dense matrix product, the same dataflow behind GPU Tensor Cores and TPU MXUs. | [day13-systolic_array](day13-systolic_array/) |
| 14 | SIMT Reconvergence (PDOM) Stack | The post-dominator reconvergence stack that lets a GPU warp of lock-step threads execute divergent control flow correctly. | [day14-simt_reconvergence_stack](day14-simt_reconvergence_stack/) |
| 15 | GPU Memory Coalescing Unit | Collapses a warp's per-lane memory addresses into the minimum number of aligned memory transactions. | [day15-memory_coalescing_unit](day15-memory_coalescing_unit/) |
| 16 | GPU Shared-Memory Bank-Conflict Detector & Access Serializer | Models the arbitration logic deciding how many cycles a warp's shared-memory access takes, detecting bank conflicts and broadcasts. | [day16-bank_conflict_detector](day16-bank_conflict_detector/) |
| 17 | Pipelined Bitonic Sorting Network | A fully-pipelined Batcher bitonic sorting network that sorts one vector per cycle at fixed latency. | [day17-bitonic_sorter](day17-bitonic_sorter/) |
| 18 | Kogge-Stone Parallel Prefix-Sum (Scan) Unit | A fully-pipelined inclusive/exclusive prefix-sum network based on the Kogge-Stone parallel-prefix recurrence. | [day18-prefix_scan_unit](day18-prefix_scan_unit/) |
| 19 | Pipelined Argmax / Argmin Reduction Tree | A balanced binary reduction tree that returns both the extreme value and its lane index in one pipelined pass. | [day19-argmax_reduction_tree](day19-argmax_reduction_tree/) |
| 20 | Systolic Shift-Register Priority Queue | A single-cycle O(1) enqueue/extract-min hardware priority queue implemented as a sorted systolic shift register. | [day20-priority_queue](day20-priority_queue/) |
| 21 | Fully-Pipelined Dual-Mode CORDIC Engine | A multiplier-free CORDIC datapath computing sin/cos and magnitude/atan2 using only shifts, adds, and an atan ROM. | [day21-cordic_engine](day21-cordic_engine/) |
| 22 | Fully-Pipelined Newton-Raphson Fixed-Point Reciprocal Unit | A fixed-latency `1/x` reciprocal engine using range reduction, a seed ROM, and two Newton-Raphson refinement steps. | [day22-newton_raphson_reciprocal](day22-newton_raphson_reciprocal/) |
| 23 | N-Way Set-Associative Write-Back Cache with Tree-PLRU Replacement | An associative cache with per-set tree-based pseudo-LRU replacement, extending Day 7's direct-mapped design. | [day23-set_associative_cache](day23-set_associative_cache/) |
| 24 | gshare Correlating Branch Predictor | A dynamic predictor that XOR-folds global branch history with the PC to index a PHT, capturing inter-branch correlation. | [day24-gshare_branch_predictor](day24-gshare_branch_predictor/) |
| 25 | Classic 5-Stage Pipelined RV32I Core | A pipelined IF/ID/EX/MEM/WB RISC-V core with full data forwarding, load-use hazard stalls, and branch-misprediction flush. | [day25-pipelined_rv32i_core](day25-pipelined_rv32i_core/) |
| 26 | Branch Target Buffer (BTB) + Return Address Stack (RAS) | Fetch-stage target prediction: a BTB predicting branch/jump targets and a RAS predicting function-return addresses. | [day26-btb_and_ras](day26-btb_and_ras/) |
| 27 | Stride Prefetcher (Reference Prediction Table) | A PC-indexed prefetcher that learns constant-stride address patterns per load instruction and fetches ahead of demand misses. | [day27-stride_prefetcher](day27-stride_prefetcher/) |
| 28 | Explicit Register Renaming Unit (RAT + Free List) | A Register Alias Table plus free-list front-end that maps architectural registers to physical registers, eliminating false WAW/WAR hazards. | [day28-register_renaming_unit](day28-register_renaming_unit/) |
| 29 | Out-of-Order Issue Queue (Reservation Stations) | A Tomasulo-style scheduler with associative wakeup and age-matrix oldest-ready-first select for out-of-order instruction issue. | [day29-issue_queue](day29-issue_queue/) |
| 30 | MESI Snooping Cache-Coherence Controller | A per-core write-back cache implementing the four-state MESI snooping coherence protocol across a shared bus. | [day30-mesi_cache_coherence](day30-mesi_cache_coherence/) |
| 31 | Non-Blocking (Lockup-Free) Cache MSHR File | A Miss Status Holding Register file that turns a blocking cache into a lockup-free one, enabling memory-level parallelism. | [day31-mshr_file](day31-mshr_file/) |
| 32 | FR-FCFS DRAM Memory-Access Scheduler | A memory-controller scheduler implementing first-ready/first-come-first-served DRAM command ordering with a fairness bypass cap. | [day32-dram_scheduler](day32-dram_scheduler/) |
| 33 | Out-of-Order Load/Store Queue | A speculative memory-disambiguation engine with youngest-store forwarding, memory-order violation detection, and pointer-checkpoint recovery. | [day33-load_store_queue](day33-load_store_queue/) |
| 34 | Parameterized SECDED ECC Pipeline | An extended-Hamming encoder/decoder that corrects single-bit faults, detects double-bit faults, and protects cache, DRAM, and interconnect data. | [day34-secded_ecc](day34-secded_ecc/) |
