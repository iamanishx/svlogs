// Testbench for muladd: try inputs, compare against plain integer maths.

`timescale 1ns / 1ps

module muladd_tb;

    logic signed [7:0]  a, b, c;
    logic signed [16:0] x;

    muladd dut (.a(a), .b(b), .c(c), .x(x));

    int errors = 0;
    int checks = 0;

    // Apply one set of inputs and check the output.
    task automatic check(input int ai, input int bi, input int ci);
        int expected = ai * bi + ci;
        a = ai[7:0];
        b = bi[7:0];
        c = ci[7:0];
        #10;                               // give the logic time to settle
        checks++;
        if (x !== expected[16:0]) begin
            errors++;
            $display("FAIL: %0d * %0d + %0d = %0d, expected %0d", a, b, c, x, expected);
        end
    endtask

    initial begin
        $dumpfile("dump.vcd");
        $dumpvars(0, muladd_tb);

        // A few by hand, printed so you can see it working.
        check(3, 4, 5);       $display("%0d * %0d + %0d = %0d", a, b, c, x);
        check(-3, 4, 5);      $display("%0d * %0d + %0d = %0d", a, b, c, x);
        check(-128, -128, 127); $display("%0d * %0d + %0d = %0d", a, b, c, x);
        check(127, -128, -128); $display("%0d * %0d + %0d = %0d", a, b, c, x);

        // Then 1000 random ones.
        for (int i = 0; i < 1000; i++)
            check($urandom_range(0, 255) - 128,
                  $urandom_range(0, 255) - 128,
                  $urandom_range(0, 255) - 128);

        if (errors == 0) $display("PASS: %0d checks", checks);
        else             $display("FAILED: %0d of %0d wrong", errors, checks);
        $finish;
    end

endmodule
