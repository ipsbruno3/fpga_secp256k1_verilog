`timescale 1ns / 1ps
module ripemd160_core (
    input  wire         clk,
    input  wire         rst_n,
    input  wire         start,
    input  wire [511:0] block,   // padded 64-byte block
    output reg  [31:0]  o0, o1, o2, o3, o4,
    output reg          done
);
    `include "rmd160_const.vh"
    reg [31:0] x [0:15];
    reg [31:0] al,bl,cl,dl,el, ar,br,cr,dr,er;
    reg [6:0]  jj;
    reg [1:0]  st;
    integer i;
    localparam IDLE=0, RUN=1, FIN=2;

    function [31:0] rol;
        input [31:0] xv; input [4:0] n;
        rol = (xv << n) | (xv >> (32 - n));
    endfunction
    function [31:0] fsel;
        input [31:0] xv, yv, zv;
        input [2:0]  idx;
        case (idx)
            0: fsel = xv ^ yv ^ zv;
            1: fsel = (xv & yv) | (~xv & zv);
            2: fsel = (xv | ~yv) ^ zv;
            3: fsel = (xv & zv) | (yv & ~zv);
            4: fsel = xv ^ (yv | ~zv);
            default: fsel = 0;
        endcase
    endfunction

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st <= IDLE; done <= 0; jj <= 7'd0;
        end else begin
            case (st)
                IDLE: begin
                    if (start) begin
                        for (i = 0; i < 16; i = i + 1)
                            x[i] <= {block[511 - 8*(4*i+3) -: 8],
                                     block[511 - 8*(4*i+2) -: 8],
                                     block[511 - 8*(4*i+1) -: 8],
                                     block[511 - 8*(4*i  ) -: 8]};
                        al <= 32'h67452301; bl <= 32'hEFCDAB89; cl <= 32'h98BADCFE;
                        dl <= 32'h10325476; el <= 32'hC3D2E1F0;
                        ar <= 32'h67452301; br <= 32'hEFCDAB89; cr <= 32'h98BADCFE;
                        dr <= 32'h10325476; er <= 32'hC3D2E1F0;
                        jj <= 7'd0; done <= 0; st <= RUN;
                    end
                end
                RUN: begin
                    al <= el;
                    bl <= rol(al + fsel(bl,cl,dl, jj>>4) + x[MLR[jj]] + KLR[jj>>4], RLR[jj]) + el;
                    cl <= bl;
                    dl <= rol(cl, 5'd10);
                    el <= dl;
                    ar <= er;
                    br <= rol(ar + fsel(br,cr,dr, 4-(jj>>4)) + x[MRR[jj]] + KRR[jj>>4], RRR[jj]) + er;
                    cr <= br;
                    dr <= rol(cr, 5'd10);
                    er <= dr;
                    if (jj == 79) st <= FIN;
                    else jj <= jj + 1;
                end
                FIN: begin
                    o0 <= 32'hEFCDAB89 + cl + dr;
                    o1 <= 32'h98BADCFE + dl + er;
                    o2 <= 32'h10325476 + el + ar;
                    o3 <= 32'hC3D2E1F0 + al + br;
                    o4 <= 32'h67452301 + bl + cr;
                    done <= 1; st <= IDLE;
                end
            endcase
        end
    end
endmodule