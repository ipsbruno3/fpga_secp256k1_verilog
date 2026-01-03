
//-----------------------------------------------------------------------------
// secp256k1_add_mod.v
// Modular addition for secp256k1: r = (a + b) mod p
// p = 0xFFFFFFFF_FFFFFFFF_FFFFFFFF_FFFFFFFF_FFFFFFFF_FFFFFFFF_FFFFFFFE_FFFFFC2F
//-----------------------------------------------------------------------------

module secp256k1_add_mod (
    input  wire         clk,
    input  wire         rst_n,
    input  wire         start,
    input  wire [255:0] a,
    input  wire [255:0] b,
    output reg  [255:0] result,
    output reg          done
);

    // secp256k1 prime: p = 2^256 - 2^32 - 977
    localparam [255:0] SECP256K1_P = 256'hFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEFFFFFC2F;

    // Internal signals
    reg  [256:0] sum;        // 257 bits to hold carry
    reg  [256:0] sum_minus_p;
    reg  [1:0]   state;

    localparam IDLE    = 2'd0;
    localparam COMPUTE = 2'd1;
    localparam DONE    = 2'd2;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            result <= 256'd0;
            done   <= 1'b0;
            state  <= IDLE;
            sum    <= 257'd0;
            sum_minus_p <= 257'd0;
        end else begin
            case (state)
                IDLE: begin
                    done <= 1'b0;
                    if (start) begin
                        // Compute a + b (257 bits to capture carry)
                        sum <= {1'b0, a} + {1'b0, b};
                        state <= COMPUTE;
                    end
                end

                COMPUTE: begin
                    // Compute sum - p
                    sum_minus_p <= sum - {1'b0, SECP256K1_P};

                    // If sum >= p (no borrow, meaning sum_minus_p[256] == 0), use sum - p
                    // Otherwise use sum
                    if (sum >= {1'b0, SECP256K1_P}) begin
                        result <= sum[255:0] - SECP256K1_P;
                    end else begin
                        result <= sum[255:0];
                    end
                    state <= DONE;
                end

                DONE: begin
                    done  <= 1'b1;
                    state <= IDLE;
                end

                default: state <= IDLE;
            endcase
        end
    end

endmodule
