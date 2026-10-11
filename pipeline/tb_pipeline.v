`timescale 1ns / 1ps
// tb_pipeline.v -- full address-derivation pipeline:
//   key -> k*G (repo wNAF) -> pubkey(comp) -> SHA-256 -> RIPEMD-160 -> hash160
// Test vector: puzzle #3 (key=7) -> 19ZewH8Kk1PDbSNdJ97FP4EiCjTRaZMZQA
module tb_pipeline;
    reg clk = 0, rst_n = 0;
    always #5 clk = ~clk;

    reg  [319:0] msg = 320'd0;
    reg  [5:0]   nbytes = 0;
    reg          le = 0;
    wire [511:0] blk;
    reg          start_s = 0, start_r = 0;
    wire         done_s, done_r;
    wire [255:0] dig_s;
    wire [31:0]  r0, r1, r2, r3, r4;

    pad_block pd (.msg(msg), .nbytes(nbytes), .le_len(le), .blk(blk));
    sha256_core s (.clk(clk), .rst_n(rst_n), .start(start_s), .block(blk),
                   .digest(dig_s), .done(done_s));
    ripemd160_core r160 (.clk(clk), .rst_n(rst_n), .start(start_r), .block(blk),
                         .o0(r0), .o1(r1), .o2(r2), .o3(r3), .o4(r4), .done(done_r));

    reg          mul_start = 0;
    reg  [255:0] kscalar = 0;
    wire [255:0] qx, qy;
    wire         wnaf_done;
    wire         pinf;
    secp256k1_point_mul_wnaf #(.W(4)) dut (
        .clk(clk), .rst_n(rst_n), .start(mul_start), .k(kscalar),
        .px(256'd0), .py(256'd0), .use_g(1'b1),
        .qx(qx), .qy(qy), .done(wnaf_done), .point_at_inf(pinf));

    localparam [255:0] E_SHA_ABC = 256'hba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad;
    localparam [255:0] E_SHA_PUB = 256'ha2039429ca2d2f2bcc0725a1682aeeeb3ac1b8e77248c34fa57fcdef29d01c53;
    localparam E_R0A=32'hf708b28e, E_R1A=32'h7a985de0, E_R2A=32'h8e4a049b,
               E_R3A=32'h87b0c698, E_R4A=32'hfc0b5af1;
    localparam E_H0=32'hf9fbed5d, E_H1=32'hd49d59ea, E_H2=32'h806acae3,
               E_H3=32'h72c433b3, E_H4=32'h693f0bfd;

    // hit detection (bloom/compare)
    reg          hit_rdy = 0;
    wire         hit;
    wire [7:0]   hid;
    hit_detect hd (.clk(clk), .rst_n(rst_n),
                   .hash({r4,r3,r2,r1,r0}), .valid(hit_rdy),
                   .hit(hit), .hit_id(hid));

    integer pass = 0, fail = 0;

    // hierarchical FSM probes
    wire [1:0] sha_st = s.st;
    wire [1:0] rmd_st = r160.st;

    initial begin
        #2000000
        $display("WATCHDOG: travou! t=%0t sha_st=%b rmd_st=%b", $time, sha_st, rmd_st);
        $finish;
    end

    initial begin
        $monitor("t=%0t clk=%b rst=%b start_s=%b sha_st=%b done_s=%b blk=%08h...",
                 $time, clk, rst_n, start_s, sha_st, done_s, blk[511:384]);
    end

    initial begin
        $display("===== Pipeline key -> hash160 (puzzle #3, key=7) =====");
        rst_n = 0; #40 rst_n = 1;

        // TEST 1: SHA-256("abc")
        msg = {24'h616263, 296'd0}; nbytes = 6'd3; le = 1'b0;
        #10 start_s = 1; #10 start_s = 0;
        wait (done_s); #2;
        $display("[t1/SHA] done_s=1");
        if (dig_s == E_SHA_ABC) begin $display("SHA-256('abc')  PASS"); pass++; end
        else begin $display("SHA-256('abc')  FAIL got %h", dig_s); fail++; end
        #20;

        // TEST 2: RIPEMD-160("abc")
        le = 1'b1;
        #10 start_r = 1; #10 start_r = 0;
        wait (done_r); #2;
        if ({r0,r1,r2,r3,r4} == {E_R0A,E_R1A,E_R2A,E_R3A,E_R4A}) begin
            $display("RIPEMD-160('abc') PASS  %h%h%h%h%h", r0,r1,r2,r3,r4); pass++;
        end else begin
            $display("RIPEMD-160('abc') FAIL %h%h%h%h%h", r0,r1,r2,r3,r4); fail++;
        end
        #20;

        // TEST 3: EC(7) -> pub -> sha -> ripemd
        kscalar = 256'd7;
        #10 mul_start = 1; #10 mul_start = 0;
        wait (wnaf_done);
        $display("[t3/EC] 7*G done qx=%h qy=%h", qx, qy);
        msg = (qy[0] == 1'b0) ? {8'h02, qx, 56'd0} : {8'h03, qx, 56'd0};
        nbytes = 6'd33; le = 1'b0;
        #10 start_s = 1; #10 start_s = 0;
        wait (done_s); #2;
        $display("[t3/SHA] sha256(pub)=%h", dig_s);
        if (dig_s == E_SHA_PUB) begin $display("  SHA-256(pub)  PASS"); pass++; end
        else begin $display("  SHA-256(pub)  FAIL"); fail++; end
        #20;

        msg = {dig_s, 64'd0}; nbytes = 6'd32; le = 1'b1;
        #10 start_r = 1; #10 start_r = 0;
        wait (done_r); #2;
        if ({r0,r1,r2,r3,r4} == {E_H0,E_H1,E_H2,E_H3,E_H4}) begin
            $display("PIPELINE  PASS: hash160 = %h%h%h%h%h", r0,r1,r2,r3,r4);
            $display("                endereco = 19ZewH8Kk1PDbSNdJ97FP4EiCjTRaZMZQA");
            pass++;
        end else begin
            $display("PIPELINE  FAIL: hash160 = %h%h%h%h%h", r0,r1,r2,r3,r4);
            fail++;
        end
        #20;

        // TEST 4: HIT detect no hash160 do key=7 (esperado HIT=1, id=0)
        hit_rdy = 1; #10 hit_rdy = 0;
        if (hit) begin $display("HIT-DETECT PASS: key=7 -> hit=1 (id=%0d)", hid); pass++; end
        else begin $display("HIT-DETECT FAIL: key=7 nao acusou hit"); fail++; end
        #20;

        // TEST 5: uma chave QUE NAO E a correta nao pode bater (key=8)
        kscalar = 256'd8;
        #10 mul_start = 1; #10 mul_start = 0;
        wait (wnaf_done);
        msg = (qy[0] == 1'b0) ? {8'h02, qx, 56'd0} : {8'h03, qx, 56'd0};
        nbytes = 6'd33; le = 1'b0;
        #10 start_s = 1; #10 start_s = 0;
        wait (done_s); #2;
        msg = {dig_s, 64'd0}; nbytes = 6'd32; le = 1'b1;
        #10 start_r = 1; #10 start_r = 0;
        wait (done_r); #2;
        hit_rdy = 1; #10 hit_rdy = 0;
        if (!hit) begin $display("HIT-DETECT NEG PASS: key=8 nao bateu (hash=%h%h%h%h%h)", r0,r1,r2,r3,r4); pass++; end
        else begin $display("HIT-DETECT NEG FAIL: key=8 bateu?! hash=%h%h%h%h%h", r0,r1,r2,r3,r4); fail++; end
        #20;

        #50;
        $display("===== RESUMO: pass=%0d  fail=%0d =====", pass, fail);
        $finish;
    end
endmodule