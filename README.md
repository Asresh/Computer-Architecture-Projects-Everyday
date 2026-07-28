# Computer Architecture Projects — Everyday

A daily series of self-contained computer-architecture projects in SystemVerilog. One documented, simulate-able architecture design per day.

Each day lives in its own folder (`DayN/`) containing a self-contained project with source, a self-checking testbench, a Makefile, a waveform image, and a README write-up.

## Index

| Day | Project | Key concepts | Folder |
|-----|---------|--------------|--------|
| 1 | Single-cycle RISC-V (RV32I) Integer ALU | Combinational ALU, RV32I ops, signed vs. unsigned compare, logical vs. arithmetic shift, zero flag | [Day1](Day1/) |
| 2 | RV32I Register File (2R / 1W) | Architectural register state, dual combinational read ports, synchronous write, x0 hardwired to zero, internal write-forwarding (WB→ID hazard) | [Day2](Day2/) |
