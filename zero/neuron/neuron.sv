// neuron: a one-neuron accelerator.
//
// Computes  y = ReLU( x[0]*w[0] + x[1]*w[1] + ... + x[n-1]*w[n-1] )
//
// The host feeds one (x, w) pair per clock cycle while in_valid is high,
// and raises in_last together with the final pair. One cycle later the
// result appears on y and out_valid pulses high for a single cycle.
//
// x and w are signed 8-bit (int8), like a quantized neural network.
// The accumulator is 24 bits, which is enough for 256 pairs without
// overflow: 256 * (128 * 128) = 2^22, and signed 24-bit holds up to 2^23 - 1.

module neuron (
    input  logic               clk,
    input  logic               rst,        // synchronous, active high

    input  logic               in_valid,   // x and w are meaningful this cycle
    input  logic               in_last,    // this is the final pair of the vector
    input  logic signed [7:0]  x,          // activation
    input  logic signed [7:0]  w,          // weight

    output logic               out_valid,  // y is meaningful this cycle
    output logic signed [23:0] y           // ReLU(dot product)
);

    logic signed [15:0] product;   // int8 * int8 always fits in 16 bits
    logic signed [23:0] acc;       // running sum (the only real state)
    logic signed [23:0] sum;       // acc plus this cycle's product

    // Combinational datapath: one multiplier and one adder.
    always_comb begin
        product = x * w;
        sum     = acc + 24'(product);   // sign-extend the product to 24 bits
    end

    // Sequential logic: what gets stored on each rising clock edge.
    always_ff @(posedge clk) begin
        out_valid <= 1'b0;                       // default: no result this cycle

        if (rst) begin
            acc <= '0;
            y   <= '0;
        end else if (in_valid) begin
            if (in_last) begin
                y         <= sum[23] ? 24'sd0 : sum;   // ReLU: negative becomes 0
                out_valid <= 1'b1;
                acc       <= '0;                       // ready for the next vector
            end else begin
                acc <= sum;
            end
        end
    end

endmodule
