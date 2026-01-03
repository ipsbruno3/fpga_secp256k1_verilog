//-----------------------------------------------------------------------------
// secp256k1_wnaf_tb.v
// Testbench for secp256k1 wNAF scalar point multiplication
//
// Description:
//   Comprehensive testbench for verifying the secp256k1_point_mul_wnaf module
//   Tests various scalar values including edge cases:
//   - k = 1 (generator point)
//   - k = 2, 3, 7, 8 (small scalars)
//   - k = 0 (point at infinity)
//   - k = 255 (full window test)
//   - Large 256-bit scalar
//
// Usage:
//   iverilog -o sim.vvp secp256k1_wnaf_tb.v [all other .v files]
//   vvp sim.vvp
//   gtkwave secp256k1_wnaf_tb.vcd
//
// Author: Bruno Silva (bsbruno@proton.me)
//-----------------------------------------------------------------------------

`timescale 1ns / 1ps

module secp256k1_wnaf_tb;

    // Clock and reset
    reg clk;
    reg rst_n;

    // DUT signals
    reg         start;
    reg  [255:0] k;
    reg  [255:0] px;
    reg  [255:0] py;
    reg         use_g;
    wire [255:0] qx;
    wire [255:0] qy;
    wire        done;
    wire        point_at_inf;

    // secp256k1 generator point G
        // secp256k1 prime p e ordem n (pra testes clássicos)
    localparam [255:0] CURVE_P = 256'hFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEFFFFFC2F;
    localparam [255:0] CURVE_N = 256'hFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;

    // secp256k1 generator point G
    localparam [255:0] GX = 256'h79BE667EF9DCBBAC55A06295CE870B07029BFCDB2DCE28D959F2815B16F81798;
    localparam [255:0] GY = 256'h483ADA7726A3C4655DA4FBFC0E1108A8FD17B448A68554199C47D08FFB10D4B8;

    // -G = (GX, p - GY)
    localparam [255:0] NEG_GY = 256'hB7C52588D95C3B9AA25B0403F1EEF75702E84BB7597AABE663B82F6F04EF2777;

    // k=1: 1*G = G
    localparam [255:0] K1_X = GX;
    localparam [255:0] K1_Y = GY;

    // k=2: 2*G  (CORRIGIDO)
    localparam [255:0] K2_X = 256'hC6047F9441ED7D6D3045406E95C07CD85C778E4B8CEF3CA7ABAC09B95C709EE5;
    localparam [255:0] K2_Y = 256'h1AE168FEA63DC339A3C58419466CEAEEF7F632653266D0E1236431A950CFE52A;

    // k=3: 3*G
    localparam [255:0] K3_X = 256'hF9308A019258C31049344F85F89D5229B531C845836F99B08601F113BCE036F9;
    localparam [255:0] K3_Y = 256'h388F7B0F632DE8140FE337E62A37F3566500A99934C2231B6CB9FD7584B8E672;

    // k=7: 7*G  (CORRIGIDO)
    localparam [255:0] K7_X = 256'h5CBDF0646E5DB4EAA398F365F2EA7A0E3D419B7E0330E39CE92BDDEDCAC4F9BC;
    localparam [255:0] K7_Y = 256'h6AEBCA40BA255960A3178D6D861A54DBA813D0B813FDE7B5A5082628087264DA;

    // k=8: 8*G
    localparam [255:0] K8_X = 256'h2F01E5E15CCA351DAFF3843FB70F3C2F0A1BDD05E5AF888A67784EF3E10A2A01;
    localparam [255:0] K8_Y = 256'h5C4DA8A741539949293D082A132D13B4C2E213D6BA5B7617B5DA2CB76CBDE904;

    // k=255: 255*G  (CORRIGIDO)
    localparam [255:0] K255_X = 256'h1B38903A43F7F114ED4500B4EAC7083FDEFECE1CF29C63528D563446F972C180;
    localparam [255:0] K255_Y = 256'h4036EDC931A60AE889353F77FD53DE4A2708B26B6F5DA72AD3394119DAF408F9;


    // DUT instantiation - using window size 4 for faster simulation
    secp256k1_point_mul_wnaf #(
      .W(4)  // Window size 4 for testing (faster), use 8 for production
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .start(start),
        .k(k),
        .px(px),
        .py(py),
        .use_g(use_g),
        .qx(qx),
        .qy(qy),
        .done(done),
        .point_at_inf(point_at_inf)
    );

    // Clock generation (100 MHz)
    initial begin
        clk = 0;
        forever #5 clk = ~clk;
    end

    // Test sequence
    integer test_num;
    integer pass_count;
    integer fail_count;
    integer timeout_count;
    integer cycle_count;

    initial begin
        // Initialize
        rst_n = 0;
        start = 0;
        k = 256'd0;
        px = 256'd0;
        py = 256'd0;
        use_g = 1;
        test_num = 0;
        pass_count = 0;
        fail_count = 0;
        timeout_count = 0;

        $display("==============================================");
        $display("secp256k1 wNAF Point Multiplication Testbench");
        $display("==============================================");
        $display("Window size: 4 (8 precomputed points)");
        $display("");

        // Reset sequence
        #100;
        rst_n = 1;
        #100;

        // Test 1: k = 1, expect G
        run_test(256'd1, K1_X, K1_Y, "k=1 (expect G)");

        // Test 2: k = 2, expect 2*G
        run_test(256'd2, K2_X, K2_Y, "k=2 (expect 2*G)");

        // Test 3: k = 3, expect 3*G
        run_test(256'd3, K3_X, K3_Y, "k=3 (expect 3*G)");

        // Test 4: k = 0, expect point at infinity
        test_num = test_num + 1;
        $display("Test %0d: k=0 (expect point at infinity)", test_num);
        k = 256'd0;
        use_g = 1;
        start = 1;
        #10;
        start = 0;
        wait_for_done(500000);

        if (done) begin
            if (point_at_inf) begin
                $display("  PASS: Result is point at infinity");
                pass_count = pass_count + 1;
            end else begin
                $display("  FAIL: Expected point at infinity");
                fail_count = fail_count + 1;
            end
        end
        #100;

        // Test 5: k = 7
        run_test(256'd7, K7_X, K7_Y, "k=7");

        // Test 6: k = 8
        run_test(256'd8, K8_X, K8_Y, "k=8");

        // Test 7: k = 255 (full window test)
        run_test(256'd255, K255_X, K255_Y, "k=255 (full window)");

        // Test 8: Larger scalar
        test_num = test_num + 1;
        $display("Test %0d: Large scalar (0x1234...)", test_num);
        k = 256'h1234567890ABCDEF1234567890ABCDEF1234567890ABCDEF1234567890ABCDEF;
        use_g = 1;
        start = 1;
        #10;
        start = 0;
        wait_for_done(5000000);  // Longer timeout for large scalar

        if (done && !point_at_inf) begin
            $display("  PASS: Computation completed successfully");
            $display("  Result X: %h", qx);
            $display("  Result Y: %h", qy);
            pass_count = pass_count + 1;
        end else if (!done) begin
            $display("  FAIL: Timeout");
            fail_count = fail_count + 1;
        end else begin
            $display("  FAIL: Unexpected infinity");
            fail_count = fail_count + 1;
        end
        #100;

        // Summary
        $display("");
        $display("==============================================");
        $display("Test Summary:");
        $display("  Total Tests: %0d", test_num);
        $display("  Passed: %0d", pass_count);
        $display("  Failed: %0d", fail_count);
        $display("  Timeouts: %0d", timeout_count);
        $display("==============================================");

        if (fail_count == 0 && timeout_count == 0)
            $display("ALL TESTS PASSED!");
        else
            $display("SOME TESTS FAILED!");

        #1000;
        $finish;
    end

    // Task to run a single test
    task run_test;
        input [255:0] scalar;
        input [255:0] expected_x;
        input [255:0] expected_y;
        input [256*8-1:0] description;
        begin
            test_num = test_num + 1;
            $display("Test %0d: %0s", test_num, description);
            k = scalar;
            use_g = 1;
            start = 1;
            #10;
            start = 0;
            wait_for_done(2000000);

            if (done) begin
                if (qx == expected_x && qy == expected_y && !point_at_inf) begin
                    $display("  PASS");
                    pass_count = pass_count + 1;
                end else begin
                    $display("  FAIL: Result mismatch");
                    $display("  Expected X: %h", expected_x);
                    $display("  Got X:      %h", qx);
                    $display("  Expected Y: %h", expected_y);
                    $display("  Got Y:      %h", qy);
                    fail_count = fail_count + 1;
                end
            end
            #100;
        end
    endtask

    // Wait for done with timeout
    task wait_for_done;
        input integer max_cycles;
        begin
            cycle_count = 0;
            while (!done && cycle_count < max_cycles) begin
                @(posedge clk);
                cycle_count = cycle_count + 1;
            end
            if (cycle_count >= max_cycles) begin
                $display("  TIMEOUT after %0d cycles", max_cycles);
                timeout_count = timeout_count + 1;
            end else begin
                $display("  Completed in %0d cycles", cycle_count);
            end
        end
    endtask

    // Dump waveforms
    initial begin
        $dumpfile("secp256k1_wnaf_tb.vcd");
        $dumpvars(0, secp256k1_wnaf_tb);
    end

endmodule
