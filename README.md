# svlogs

Learning chip design by building small blocks in SystemVerilog, working up to an accelerator for a small language model.

## Designs

| Folder | What it is | Gates |
|---|---|---|
| `zero/muladd/` | `x = a * b + c` on signed 8-bit inputs. Combinational, no clock. | 518 |
| `zero/neuron/` | One neuron: `y = ReLU(sum of x[i] * w[i])`, fed one pair per clock cycle. | 902 |

Start with `muladd`, then read `neuron`.

## Tools

```bash
sudo apt install iverilog verilator yosys gtkwave
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
