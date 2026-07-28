# Makefile - Day5 single-cycle RV32I core
#
# Targets for the four common SystemVerilog simulators. Each elaborates the
# design + testbench, runs it, and produces core.vcd. Default target = icarus.
#
#   make            # run with Icarus Verilog (iverilog + vvp)
#   make verilator  # run with Verilator
#   make vcs        # run with Synopsys VCS
#   make questa     # run with Siemens Questa/ModelSim
#   make waveform   # regenerate docs/core_waveform.png from the VCD
#   make clean
#
# The core is self-contained: alu.sv (Day1), regfile.sv (Day2), decoder.sv
# (Day3) and lsu.sv (Day4) are copied into this folder, plus imem.sv and
# core.sv added here.

DESIGN  := alu.sv regfile.sv decoder.sv lsu.sv imem.sv core.sv
TB      := tb_core.sv
TOP     := tb_core
VCD     := core.vcd

.PHONY: all icarus verilator vcs questa waveform clean

all: icarus

# ---- Icarus Verilog ----
icarus:
	iverilog -g2012 -Wall -o simv_icarus $(DESIGN) $(TB)
	vvp simv_icarus

# ---- Verilator ----
verilator:
	verilator --binary -j 0 --trace -Wall --timing --top-module $(TOP) \
		$(DESIGN) $(TB) -o simv_verilator
	./obj_dir/simv_verilator

# ---- Synopsys VCS ----
vcs:
	vcs -full64 -sverilog -debug_access+all +vcs+dumpvars -o simv_vcs \
		$(DESIGN) $(TB)
	./simv_vcs

# ---- Siemens Questa / ModelSim ----
questa:
	vlib work
	vlog -sv $(DESIGN) $(TB)
	vsim -c $(TOP) -do "run -all; quit"

# ---- Render the waveform PNG from the captured VCD ----
waveform:
	python3 render_waveform.py

clean:
	rm -rf simv_icarus simv_vcs obj_dir work transcript *.vcd \
		vsim.wlf csrc *.daidir ucli.key
