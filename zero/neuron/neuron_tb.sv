// Self-checking testbench for neuron.
//
// It sends vectors into the design and, at the same time, computes the
// expected answer with ordinary integer maths (the "golden model").
// Every result the design produces is compared against that answer.

`timescale 1ns / 1ps

module neuron_tb;

    logic               clk = 0;
    logic               rst;
    logic               in_valid;
    logic               in_last;
    logic signed [7:0]  x;
    logic signed [7:0]  w;
    logic               out_valid;
    logic signed [23:0] y;

    neuron dut (.*);               // connect ports to same-named signals

    always #5 clk = ~clk;          // 10 ns period = 100 MHz

    int errors = 0;
    int checks = 0;

    // Send one vector of `n` pairs and check the result.
    //   mode 0: random values
    //   mode 1: every pair is (-128, -128)  -> largest positive sum
    //   mode 2: every pair is (127, -128)   -> most negative sum, ReLU gives 0
    //   gaps  : randomly drop in_valid between pairs, like a slow host
    task automatic send_vector(input int n, input int mode, input bit gaps);
        int expected = 0;
        int xi, wi;

        for (int i = 0; i < n; i++) begin
            // Optionally idle for a few cycles before this pair.
            if (gaps) begin
                while ($urandom_range(0, 2) == 0) begin
                    @(negedge clk);
                    in_valid = 0;
                    x = $urandom;          // garbage: must be ignored
                    w = $urandom;
                end
            end

            case (mode)
                1:       begin xi = -128; wi = -128; end
                2:       begin xi =  127; wi = -128; end
                default: begin
                    xi = $urandom_range(0, 255) - 128;
                    wi = $urandom_range(0, 255) - 128;
                end
            endcase
            expected += xi * wi;

            @(negedge clk);                // change inputs away from the rising edge
            in_valid = 1;
            in_last  = (i == n - 1);
            x        = xi[7:0];
            w        = wi[7:0];
        end

        @(negedge clk);                    // result was registered on the last posedge
        in_valid = 0;
        in_last  = 0;

        if (expected < 0) expected = 0;    // golden-model ReLU

        checks++;
        if (!out_valid) begin
            errors++;
            $display("FAIL n=%0d mode=%0d: out_valid did not pulse", n, mode);
        end else if (y !== expected[23:0]) begin
            errors++;
            $display("FAIL n=%0d mode=%0d: got %0d, expected %0d", n, mode, y, expected);
        end

        @(negedge clk);
        if (out_valid) begin
            errors++;
            $display("FAIL n=%0d mode=%0d: out_valid stayed high for 2 cycles", n, mode);
        end
    endtask

    initial begin
        $dumpfile("dump.vcd");
        $dumpvars(0, neuron_tb);

        in_valid = 0; in_last = 0; x = 0; w = 0;
        rst = 1;
        repeat (3) @(negedge clk);
        rst = 0;

        // Directed cases first: easy to follow in the waveform.
        send_vector(1,   0, 0);            // shortest possible vector
        send_vector(4,   0, 0);
        send_vector(256, 1, 0);            // 256 * 16384 = 4194304, the maximum
        send_vector(256, 2, 0);            // most negative, expect 0

        // Then random lengths, with and without gaps.
        for (int t = 0; t < 500; t++)
            send_vector($urandom_range(1, 256), 0, t[0]);

        // Reset in the middle of a vector must discard the partial sum.
        @(negedge clk); in_valid = 1; in_last = 0; x = 8'sd100; w = 8'sd100;
        @(negedge clk); in_valid = 0; rst = 1;
        @(negedge clk); rst = 0;
        send_vector(3, 0, 0);

        if (errors == 0) $display("PASS: %0d vectors checked", checks);
        else             $display("FAILED: %0d of %0d vectors wrong", errors, checks);
        $finish;
    end

endmodule
