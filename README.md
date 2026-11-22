# svlogs

Learning chip design by building small blocks in SystemVerilog, working up to an accelerator for a small language model.

## Designs

| Folder | What it is | Gates |
|---|---|---|
| `zero/muladd/` | `x = a * b + c` on signed 8-bit inputs. Combinational, no clock. | 518 |
| `zero/neuron/` | One neuron: `y = ReLU(sum of x[i] * w[i])`, fed one pair per clock cycle. | 902 |
| `zero/json_parser/` | Streaming JSON parser: one byte in per clock, a stream of events out. | 1,922 |

Start with `muladd`, then read `neuron`. `json_parser` is a separate track: a state machine and a stack, with no arithmetic beyond reading integers.

## Tools

```bash
sudo apt install iverilog verilator yosys gtkwave
pip install cocotb        # only needed for json_parser
```

- **Icarus Verilog** (`iverilog`, `vvp`): runs the simulation.
- **Verilator**: strict lint checks.
- **Yosys**: turns the RTL into logic gates.
- **GTKWave**: shows signals over time.

## Usage

Every design folder has the same Makefile. From inside one:

```bash
make sim     # run the testbench
make wave    # run it, then open the waveform
make lint    # style and width checks
make synth   # RTL -> gates, prints the cell count
make clean   # remove generated files
```

## Layout of a design

```text
name.sv       the design
name_tb.sv    testbench that checks it against plain integer maths
Makefile      the commands above
```

`json_parser` has a Python testbench instead (`test_json_parser.py`, run by cocotb), which checks the hardware against Python's own `json` module.
