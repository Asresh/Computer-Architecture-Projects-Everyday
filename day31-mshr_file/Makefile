# Makefile - Day31 Non-Blocking (Lockup-Free) Cache MSHR File
#
# Targets for the four common SystemVerilog simulators. Each elaborates the
# design + testbench, runs it, and produces mshr_file.vcd. Default = icarus.
#
#   make            # run with Icarus Verilog (iverilog + vvp)
#   make verilator  # run with Verilator
#   make vcs        # run with Synopsys VCS
#   make questa     # run with Siemens Questa/ModelSim
#   make waveform   # regenerate docs/mshr_file_waveform.png from the VCD
#   make clean
#
# mshr_file.sv is the MSHR file of a lockup-free cache; tb_mshr_file.sv plays
# the cache/core and the next-level memory (random latency, out-of-order
# tagged returns) and lock-steps the DUT against an independent behavioural
# golden model plus four end-to-end properties.

DESIGN := mshr_file.sv
TB     := tb_mshr_file.sv
TOP    := tb_mshr_file
VCD    := mshr_file.vcd

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
