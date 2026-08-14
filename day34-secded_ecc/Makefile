# Author: Asresh Kuricheti
# Day 34 SECDED ECC simulation flow
#
#  secded_ecc.sv + tb_secded_ecc.sv
#               |
#     simulator-selecting targets
#               |
#       PASS/FAIL + secded_ecc.vcd

DESIGN := secded_ecc.sv
TB := tb_secded_ecc.sv
TOP := tb_secded_ecc
VCD := secded_ecc.vcd

.PHONY: all icarus verilator vcs questa clean

all: icarus

icarus:
	iverilog -g2012 -Wall -o simv_icarus $(DESIGN) $(TB)
	vvp simv_icarus

verilator:
	verilator --binary -j 0 --trace -Wall --timing --top-module $(TOP) \
		$(DESIGN) $(TB) -o simv_verilator
	./obj_dir/simv_verilator

vcs:
	vcs -full64 -sverilog -debug_access+all +vcs+dumpvars -o simv_vcs \
		$(DESIGN) $(TB)
	./simv_vcs

questa:
	vlib work
	vlog -sv $(DESIGN) $(TB)
	vsim -c $(TOP) -do "run -all; quit"

clean:
	rm -rf simv_icarus simv_vcs obj_dir work transcript *.vcd \
		vsim.wlf csrc *.daidir ucli.key
