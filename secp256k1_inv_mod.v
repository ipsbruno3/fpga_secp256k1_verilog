//-----------------------------------------------------------------------------
// secp256k1_inv_mod.v
// Modular inversion for secp256k1 elliptic curve
//
// Description:
//   Computes r = a^(-1) mod p where:
//   - a is a 256-bit unsigned integer (non-zero)
//   - p = 2^256 - 2^32 - 977 (secp256k1 prime)
//
// Algorithm: Binary Extended Euclidean Algorithm (BEEA)
//   Uses the property: if gcd(a, p) = 1, then a*x ≡ 1 (mod p)
//
//   While u ≠ 1 and v ≠ 1:
//     1. While u is even: u = u/2; x1 = (x1+p)/2 if x1 odd, else x1/2
//     2. While v is even: v = v/2; x2 = (x2+p)/2 if x2 odd, else x2/2
//     3. If u > v: u = u-v; x1 = x1-x2 (mod p)
//        Else: v = v-u; x2 = x2-x1 (mod p)
//
// Latency: ~768 clock cycles (worst case)
// Throughput: Variable, depends on input
// Note: This is the most expensive operation - used only for Jacobian→Affine
//
// Author: Bruno Silva (bsbruno@proton.me)
//-----------------------------------------------------------------------------

module secp256k1_inv_mod (
    input  wire         clk,
    input  wire         rst_n,
    input  wire         start,
    input  wire [255:0] a,
    output reg  [255:0] result,
    output reg          done
);

    // secp256k1 prime
    localparam [255:0] SECP256K1_P = 256'hFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEFFFFFC2F;

    // State machine
    reg [3:0] state;
    localparam IDLE       = 4'd0;
    localparam INIT       = 4'd1;
    localparam LOOP_CHECK = 4'd2;
    localparam EVEN_U     = 4'd3;
    localparam EVEN_V     = 4'd4;
    localparam COMPARE    = 4'd5;
    localparam SUB_U_V    = 4'd6;
    localparam SUB_V_U    = 4'd7;
    localparam FINISH     = 4'd8;
    localparam DONE_STATE = 4'd9;

    // Algorithm variables
    reg [255:0] u, v;      // Working values
    reg [255:0] x1, x2;    // Bezout coefficients

    // Temporary registers for operations
    reg [256:0] temp_add;
    reg [255:0] temp_sub;

    // Helper signals
    wire u_is_one, v_is_one;
    wire u_even, v_even;
    wire u_gt_v;

    assign u_is_one = (u == 256'd1);
    assign v_is_one = (v == 256'd1);
    assign u_even   = ~u[0];
    assign v_even   = ~v[0];
    assign u_gt_v   = (u > v);

    // Iteration counter to prevent infinite loops
    reg [9:0] iter_count;
    localparam MAX_ITER = 10'd768;  // ~3 * 256 iterations max

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            result     <= 256'd0;
            done       <= 1'b0;
            state      <= IDLE;
            u          <= 256'd0;
            v          <= 256'd0;
            x1         <= 256'd0;
            x2         <= 256'd0;
            temp_add   <= 257'd0;
            temp_sub   <= 256'd0;
            iter_count <= 10'd0;
        end else begin
            case (state)
                IDLE: begin
                    done <= 1'b0;
                    if (start) begin
                        state <= INIT;
                    end
                end

                INIT: begin
                    // Initialize: u = a, v = p, x1 = 1, x2 = 0
                    u  <= a;
                    v  <= SECP256K1_P;
                    x1 <= 256'd1;
                    x2 <= 256'd0;
                    iter_count <= 10'd0;
                    state <= LOOP_CHECK;
                end

                LOOP_CHECK: begin
                    iter_count <= iter_count + 1'b1;

                    if (u_is_one) begin
                        result <= x1;
                        state <= DONE_STATE;
                    end else if (v_is_one) begin
                        result <= x2;
                        state <= DONE_STATE;
                    end else if (iter_count >= MAX_ITER) begin
                        // Safety exit
                        result <= x1;
                        state <= DONE_STATE;
                    end else if (u_even) begin
                        state <= EVEN_U;
                    end else if (v_even) begin
                        state <= EVEN_V;
                    end else begin
                        state <= COMPARE;
                    end
                end

                EVEN_U: begin
                    // u = u >> 1
                    u <= {1'b0, u[255:1]};

                    // if x1 is odd, x1 = (x1 + p) >> 1, else x1 = x1 >> 1
                    if (x1[0]) begin
                        temp_add <= {1'b0, x1} + {1'b0, SECP256K1_P};
                        x1 <= ({1'b0, x1} + {1'b0, SECP256K1_P}) >> 1;
                    end else begin
                        x1 <= {1'b0, x1[255:1]};
                    end
                    state <= LOOP_CHECK;
                end

                EVEN_V: begin
                    // v = v >> 1
                    v <= {1'b0, v[255:1]};

                    // if x2 is odd, x2 = (x2 + p) >> 1, else x2 = x2 >> 1
                    if (x2[0]) begin
                        x2 <= ({1'b0, x2} + {1'b0, SECP256K1_P}) >> 1;
                    end else begin
                        x2 <= {1'b0, x2[255:1]};
                    end
                    state <= LOOP_CHECK;
                end

                COMPARE: begin
                    if (u_gt_v) begin
                        state <= SUB_U_V;
                    end else begin
                        state <= SUB_V_U;
                    end
                end

                SUB_U_V: begin
                    // u = u - v
                    u <= u - v;

                    // x1 = x1 - x2 (mod p)
                    if (x1 >= x2) begin
                        x1 <= x1 - x2;
                    end else begin
                        x1 <= x1 + SECP256K1_P - x2;
                    end
                    state <= LOOP_CHECK;
                end

                SUB_V_U: begin
                    // v = v - u
                    v <= v - u;

                    // x2 = x2 - x1 (mod p)
                    if (x2 >= x1) begin
                        x2 <= x2 - x1;
                    end else begin
                        x2 <= x2 + SECP256K1_P - x1;
                    end
                    state <= LOOP_CHECK;
                end

                DONE_STATE: begin
                    done  <= 1'b1;
                    state <= IDLE;
                end

                default: state <= IDLE;
            endcase
        end
    end

endmodule
