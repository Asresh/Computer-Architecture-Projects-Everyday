# Makefile - Day33 Out-of-Order Load/Store Queue
#
# Targets for the four common SystemVerilog simulators. Each elaborates the
# design + testbench, runs it, and produces load_store_queue.vcd.
# Default = icarus.
#
#   make            # run with Icarus Verilog (iverilog + vvp)
#   make verilator  # run with Verilator
#   make vcs        # run with Synopsys VCS
#   make questa     # run with Siemens Questa/ModelSim
#   make clean
#
# load_store_queue.sv is the LSQ; tb_load_store_queue.sv plays the dispatch,
# execute, commit and squash ports of an out-of-order core around it, and
# lock-steps the DUT against an independent sequence-number golden model plus
# an end-to-end architectural-value check, a recovery-checkpoint check and an
# in-order store-drain check.

DESIGN := load_store_queue.sv
TB     := tb_load_store_queue.sv
TOP    := tb_load_store_queue
VCD    := load_store_queue.vcd

.PHONY: all icarus verilator vcs questa clean

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

clean:
	rm -rf simv_icarus simv_vcs obj_dir work transcript *.vcd \
		vsim.wlf csrc *.daidir ucli.key
