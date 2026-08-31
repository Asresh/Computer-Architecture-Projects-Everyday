# Author: Asresh Kuricheti
#
# Source -> selected simulator -> self-checking PASS/FAIL + VCD

DESIGN := credit_based_vc_scheduler
RTL    := $(DESIGN).sv
TB     := tb_$(DESIGN).sv
TOP    := tb_$(DESIGN)

.PHONY: all icarus verilator vcs questa clean

all: icarus

icarus:
	iverilog -g2012 -Wall -s $(TOP) -o simv $(RTL) $(TB)
	vvp simv

verilator:
	verilator --binary --timing --trace --top-module $(TOP) -Wall -Wno-fatal $(RTL) $(TB)
	./obj_dir/V$(TOP)

vcs:
	vcs -full64 -sverilog -debug_access+all -top $(TOP) $(RTL) $(TB) -o simv
	./simv

questa:
	vlib work
	vlog -sv $(RTL) $(TB)
	vsim -c $(TOP) -do "run -all; quit -f"

clean:
	rm -rf simv simv.daidir csrc ucli.key vc_hdrs.h DVEfiles inter.vpd \
		work transcript vsim.wlf obj_dir *.vcd *.fst
