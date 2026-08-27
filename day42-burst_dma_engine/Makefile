# Author: Asresh Kuricheti
# Simulation flow: testbench -> selected simulator -> self-check + VCD

DESIGN := burst_dma_engine
RTL    := $(DESIGN).sv
TB     := tb_$(DESIGN).sv

.PHONY: all run icarus verilator vcs questa clean

all: icarus
run: icarus

icarus:
	iverilog -g2012 -s tb_$(DESIGN) -o simv $(RTL) $(TB)
	vvp simv

verilator:
	verilator --binary --timing --trace --assert -Wall -Wno-fatal \
		--top-module tb_$(DESIGN) $(RTL) $(TB)
	./obj_dir/Vtb_$(DESIGN)

vcs:
	vcs -full64 -sverilog -debug_access+all $(RTL) $(TB) -o simv
	./simv

questa:
	vlib work
	vlog -sv $(RTL) $(TB)
	vsim -c tb_$(DESIGN) -do "run -all; quit -f"

clean:
	rm -rf simv simv.daidir csrc ucli.key obj_dir work transcript \
		vsim.wlf burst_dma_engine.vcd
