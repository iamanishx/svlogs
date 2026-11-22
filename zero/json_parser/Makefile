# make sim    - run the cocotb testbench (needs: pip install cocotb)
# make wave   - run it with waveform dumping, then open the waveform
# make lint   - strict style and width checks
# make synth  - turn the RTL into gates and print the cell count
# make clean

TOP = json_parser

SIM                 ?= icarus
TOPLEVEL_LANG       ?= verilog
VERILOG_SOURCES      = $(CURDIR)/$(TOP).sv
COCOTB_TOPLEVEL      = $(TOP)
COCOTB_TEST_MODULES  = test_$(TOP)

include $(shell cocotb-config --makefiles)/Makefile.sim

wave:
	$(MAKE) sim WAVES=1
	gtkwave sim_build/$(TOP).fst

lint:
	verilator --lint-only -Wall $(TOP).sv

synth:
	yosys -q -p "read_verilog -sv $(TOP).sv; synth -top $(TOP); tee -o synth_report.txt stat; write_verilog -noattr $(TOP)_gates.v"
	@cat synth_report.txt

clean::
	rm -rf sim_build results.xml synth_report.txt $(TOP)_gates.v __pycache__

.PHONY: wave lint synth
