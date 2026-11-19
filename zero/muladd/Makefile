# make sim    - run the testbench
# make wave   - run it, then open the waveform
# make lint   - strict style and width checks
# make synth  - turn the RTL into gates and print the cell count
# make clean

TOP = muladd

sim:
	iverilog -g2012 -Wall -o $(TOP)_sim $(TOP)_tb.sv $(TOP).sv
	vvp $(TOP)_sim

wave: sim
	gtkwave dump.vcd

lint:
	verilator --lint-only -Wall $(TOP).sv

synth:
	yosys -q -p "read_verilog -sv $(TOP).sv; synth -top $(TOP); tee -o synth_report.txt stat; write_verilog -noattr $(TOP)_gates.v"
	@cat synth_report.txt

clean:
	rm -f $(TOP)_sim dump.vcd synth_report.txt $(TOP)_gates.v

.PHONY: sim wave lint synth clean
