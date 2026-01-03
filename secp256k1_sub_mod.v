
//-----------------------------------------------------------------------------
// secp256k1_sub_mod.v
// Modular subtraction for secp256k1: r = (a - b) mod p
// p = 0xFFFFFFFF_FFFFFFFF_FFFFFFFF_FFFFFFFF_FFFFFFFF_FFFFFFFF_FFFFFFFE_FFFFFC2F
//-----------------------------------------------------------------------------

module secp256k1_sub_mod (
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
    reg  [256:0] diff;       // 257 bits to detect borrow
    reg  [1:0]   state;

    localparam IDLE    = 2'd0;
    localparam COMPUTE = 2'd1;
    localparam DONE    = 2'd2;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            result <= 256'd0;
            done   <= 1'b0;
            state  <= IDLE;
            diff   <= 257'd0;
        end else begin
            case (state)
                IDLE: begin
                    done <= 1'b0;
                    if (start) begin
                        // Compute a - b (257 bits for borrow detection)
                        diff <= {1'b0, a} - {1'b0, b};
                        state <= COMPUTE;
                    end
                end

                COMPUTE: begin
                    // If borrow occurred (diff[256] == 1), add p
                    if (diff[256]) begin
                        result <= diff[255:0] + SECP256K1_P;
                    end else begin
                        result <= diff[255:0];
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
