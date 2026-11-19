// muladd: x = a * b + c
//
// Pure combinational logic: no clock, no memory. The output follows the
// inputs continuously, like a calculator that is always calculating.
//
// a, b, c are signed 8-bit. The output is 17 bits so it can never overflow:
// a * b is at most 16384, and adding c keeps it inside 17 signed bits.

module muladd (
    input  logic signed [7:0]  a,
    input  logic signed [7:0]  b,
    input  logic signed [7:0]  c,
    output logic signed [16:0] x
);

    logic signed [15:0] product;   // int8 * int8 always fits in 16 bits

    assign product = a * b;
    assign x       = 17'(product) + 17'(c);   // widen both to 17 bits, then add

endmodule
