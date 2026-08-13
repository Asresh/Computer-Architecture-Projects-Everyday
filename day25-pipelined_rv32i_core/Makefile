# Makefile - Day25 5-stage pipelined RV32I core
#
# Targets for the four common SystemVerilog simulators. Each elaborates the
# design + testbench, runs it, and produces pipeline.vcd. Default = icarus.
#
#   make            # run with Icarus Verilog (iverilog + vvp)
#   make verilator  # run with Verilator
#   make vcs        # run with Synopsys VCS
#   make questa     # run with Siemens Questa/ModelSim
#   make waveform   # regenerate docs/pipeline_waveform.png from the VCD
#   make clean
#
# The core reuses the Day 1 ALU (alu.sv, copied here); pipeline_rv32i.sv adds
# the pipeline registers, forwarding unit, hazard-detection stall, and
# branch-flush control. tb_pipeline_rv32i.sv self-checks the final
# architectural state against an independent in-testbench sequential ISS.

DESIGN := alu.sv pipeline_rv32i.sv
TB     := tb_pipeline_rv32i.sv
TOP    := tb_pipeline_rv32i
VCD    := pipeline.vcd

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
