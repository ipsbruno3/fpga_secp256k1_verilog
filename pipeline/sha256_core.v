// sha256_core.v -- single-block SHA-256 (message <= 55 bytes => 1 pad block)
module sha256_core (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        start,
    input  wire [511:0] block,   // byte i in bits [511-8*i -: 8], 64-byte padded block
    output reg  [255:0] digest,
    output reg          done
);
    `include "sha256_const.vh"
    reg [31:0] w [0:63];
    reg [31:0] a, b, c, d, e, f, g, h;
    reg [6:0]  t;
    reg        run;
    integer i;

    localparam IDLE = 0, RUN = 1, FIN = 2;
    reg [1:0] st;

    function [31:0] rot;
        input [31:0] x; input [4:0] n;
        rot = (x >> n) | (x << (32 - n));
    endfunction
    function [31:0] big_s0;
        input [31:0] x;
        big_s0 = rot(x,2) ^ rot(x,13) ^ rot(x,22);
    endfunction
    function [31:0] big_s1;
        input [31:0] x;
        big_s1 = rot(x,6) ^ rot(x,11) ^ rot(x,25);
    endfunction
    function [31:0] sm_s0;
        input [31:0] x;
        sm_s0 = rot(x,7) ^ rot(x,18) ^ (x >> 3);
    endfunction
    function [31:0] sm_s1;
        input [31:0] x;
        sm_s1 = rot(x,17) ^ rot(x,19) ^ (x >> 10);
    endfunction
    function [31:0] ch;
        input [31:0] x, y, z;
        ch = (x & y) ^ (~x & z);
    endfunction
    function [31:0] maj;
        input [31:0] x, y, z;
        maj = (x & y) ^ (x & z) ^ (y & z);
    endfunction

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st <= IDLE; done <= 0; t <= 7'd0;
        end else begin
            case (st)
                IDLE: begin
                    if (start) begin
                        for (i = 0; i < 16; i = i + 1)
                            w[i] <= block[511 - 32*i -: 32];
                        a <= HK[0]; b <= HK[1]; c <= HK[2]; d <= HK[3];
                        e <= HK[4]; f <= HK[5]; g <= HK[6]; h <= HK[7];
                        t <= 7'd0; done <= 0; st <= RUN;
                    end
                end
                RUN: begin
                    if (t >= 16)
                        w[t] <= sm_s1(w[t-2]) + w[t-7] + sm_s0(w[t-15]) + w[t-16];
                    if (t < 16) begin
                        h <= g; g <= f; f <= e;
                        e <= d + (h + big_s1(e) + ch(e,f,g) + KT[t] + w[t]);
                        d <= c; c <= b; b <= a;
                        a <= (h + big_s1(e) + ch(e,f,g) + KT[t] + w[t])
                             + big_s0(a) + maj(a,b,c);
                    end else begin
                        h <= g; g <= f; f <= e;
                        e <= d + (h + big_s1(e) + ch(e,f,g) + KT[t]
                                  + sm_s1(w[t-2]) + w[t-7] + sm_s0(w[t-15]) + w[t-16]);
                        d <= c; c <= b; b <= a;
                        a <= (h + big_s1(e) + ch(e,f,g) + KT[t]
                              + sm_s1(w[t-2]) + w[t-7] + sm_s0(w[t-15]) + w[t-16])
                             + big_s0(a) + maj(a,b,c);
                    end
                    if (t == 63) st <= FIN;
                    else t <= t + 1;
                end
                FIN: begin
                    digest <= {a+HK[0], b+HK[1], c+HK[2], d+HK[3],
                               e+HK[4], f+HK[5], g+HK[6], h+HK[7]};
                    done <= 1; st <= IDLE;
                end
            endcase
        end
    end
endmodule