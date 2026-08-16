# Author: Asresh Kuricheti
# Flow: SystemVerilog sources -> selected simulator -> self-checking PASS/FAIL + VCD
DESIGN := instruction_fetch_queue
TB := tb_instruction_fetch_queue
SOURCES := $(DESIGN).sv $(TB).sv

.PHONY: all icarus verilator vcs questa clean
all: icarus

icarus:
	iverilog -g2012 -Wall -s $(TB) -o simv $(SOURCES)
	vvp simv

verilator:
	verilator --binary --timing --trace --top-module $(TB) -Wall -Wno-fatal $(SOURCES)
	./obj_dir/V$(TB)

vcs:
	vcs -full64 -sverilog -debug_access+all -top $(TB) $(SOURCES) -o simv
	./simv

questa:
	vlib work
	vlog -sv $(SOURCES)
	vsim -c $(TB) -do "run -all; quit -f"

clean:
	rm -rf simv simv.daidir csrc ucli.key vc_hdrs.h obj_dir work transcript vsim.wlf *.vcd
