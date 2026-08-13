# Makefile - Day32 FR-FCFS DRAM Memory-Access Scheduler
#
# Targets for the four common SystemVerilog simulators. Each elaborates the
# design + testbench, runs it, and produces dram_scheduler.vcd. Default = icarus.
#
#   make            # run with Icarus Verilog (iverilog + vvp)
#   make verilator  # run with Verilator
#   make vcs        # run with Synopsys VCS
#   make questa     # run with Siemens Questa/ModelSim
#   make waveform   # regenerate docs/dram_scheduler_waveform.png from the VCD
#   make clean
#
# dram_scheduler.sv is the memory-controller scheduler; tb_dram_scheduler.sv
# plays the last-level cache on one side and the DRAM devices on the other,
# lock-stepping the DUT against an independent behavioural golden model, an
# independent DRAM-device protocol checker, a per-tag transaction tracker and
# a starvation bound.

DESIGN := dram_scheduler.sv
TB     := tb_dram_scheduler.sv
TOP    := tb_dram_scheduler
VCD    := dram_scheduler.vcd

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
