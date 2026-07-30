# Computer Architecture Projects — Everyday

A daily series of self-contained computer-architecture projects in SystemVerilog. One documented, simulate-able architecture design per day.

Each day lives in its own folder (`DayN/`) containing a self-contained project with source, a self-checking testbench, a Makefile, a waveform image, and a README write-up.

## Index

| Day | Project | Key concepts | Folder |
|-----|---------|--------------|--------|
| 1 | Single-cycle RISC-V (RV32I) Integer ALU | Combinational ALU, RV32I ops, signed vs. unsigned compare, logical vs. arithmetic shift, zero flag | [Day1](Day1/) |
| 2 | RV32I Register File (2R / 1W) | Architectural register state, dual combinational read ports, synchronous write, x0 hardwired to zero, internal write-forwarding (WB→ID hazard) | [Day2](Day2/) |
| 3 | RV32I Instruction Decoder + Immediate Generator | Combinational control decode (opcode/funct3/funct7), datapath control lines, ALU-control mapping, I/S/B/U/J immediate generation, safe NOP default | [Day3](Day3/) |
| 4 | RV32I Load/Store Unit + Data Memory | Byte-addressable little-endian memory, lb/lh/lw/lbu/lhu/sb/sh/sw, byte-lane selection, sign vs. zero extension, per-byte write enables, within-word misalignment policy | [Day4](Day4/) |
| 5 | Single-Cycle RV32I Core (integer subset) | Full integration (ALU + regfile + decoder + LSU + PC/imem), operand & write-back muxes, ALU-reuse branch resolution, jal/jalr next-PC, directed program checked vs. an independent ISS golden trace | [Day5](Day5/) |
| 6 | Bimodal 2-bit Saturating-Counter Branch Predictor | Dynamic branch prediction, PC-indexed Pattern History Table, 2-bit saturating-counter FSM, hysteresis / single-mispredict loop-exit tolerance, independent predict (fetch) & update (resolve) ports, per-PC independence | [Day6](Day6/) |
| 7 | Direct-Mapped Write-Back / Write-Allocate Data Cache | Memory hierarchy, direct-mapped placement (tag/index/offset), valid & dirty bits, write-back + write-allocate policy, conflict-miss eviction with dirty write-back, miss-handling FSM (LOOKUP→WRITEBACK→ALLOCATE), word-burst memory port, CPU ready handshake | [Day7](Day7/) |
| 8 | Radix-4 (Modified) Booth Signed Sequential Multiplier | Integer multiply datapath, modified Booth recoding (2 bits/cycle), signed two's-complement multiply with no sign-correction, add/shift accumulator with arithmetic right shift, ±M/±2M partial-multiple selection, WIDTH/2-iteration latency, start/busy/done handshake FSM | [Day8](Day8/) |
| 9 | Round-Robin (Rotating-Priority) Arbiter | On-chip resource arbitration, rotating-priority fairness, provable no-starvation bound (grant within N cycles), one-hot grant + binary index, mask/isolate-lowest-set-bit priority pick (no variable bit-selects), single registered rotate pointer | [Day9](Day9/) |
| 10 | Fully-Associative TLB with True-LRU Replacement | Virtual memory & address translation, VPN→PPN mapping with page-offset passthrough, fully-associative CAM lookup (parallel tag compare), hit/miss & single-cycle response, true-LRU replacement via an N×N reference (age) matrix, refill priority (overwrite→free-slot→LRU victim), single-page invalidate & full flush (sfence) | [Day10](Day10/) |
| 11 | Store Buffer with Store-to-Load Forwarding | Store retirement decoupling, in-order circular-FIFO store queue, store-to-load forwarding of the youngest matching store, load-miss fall-through, program-order drain to memory, simultaneous push+drain, full/empty backpressure handshakes, relative-age youngest-match select (no variable bit-selects) | [Day11](Day11/) |
