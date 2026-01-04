//-----------------------------------------------------------------------------
// secp256k1_mul_mod_serial.v
// Serial modular multiplication for secp256k1 - Area optimized
// Uses single 32x32 multiplier, processes in 64+ cycles
// Trades area for latency: ~100 cycles vs ~7 cycles, but uses ~1/10 LUTs
//-----------------------------------------------------------------------------

module secp256k1_mul_mod_serial (
    input  wire         clk,
    input  wire         rst_n,
    input  wire         start,
    input  wire [255:0] a,
    input  wire [255:0] b,
    output reg  [255:0] result,
    output reg          done
);

    // secp256k1 prime
    localparam [255:0] SECP256K1_P = 256'hFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEFFFFFC2F;
    localparam [31:0]  REDUCTION_CONST = 32'd977;

    // State machine
    reg [3:0] state;
    localparam IDLE         = 4'd0;
    localparam LOAD         = 4'd1;
    localparam MULTIPLY     = 4'd2;
    localparam ACCUMULATE   = 4'd3;
    localparam NEXT_J       = 4'd4;
    localparam NEXT_I       = 4'd5;
    localparam PROPAGATE    = 4'd6;
    localparam REDUCE1      = 4'd7;
    localparam REDUCE2      = 4'd8;
    localparam REDUCE3      = 4'd9;
    localparam NORMALIZE    = 4'd10;
    localparam DONE_STATE   = 4'd11;

    // Input registers (8 x 32-bit words each)
    reg [31:0] a_words [0:7];
    reg [31:0] b_words [0:7];

    // Accumulator for 512-bit product (16 x 33-bit to hold carries)
    reg [32:0] acc [0:15];

    // Loop counters
    reg [3:0] i, j;

    // Single 32x32 multiplier
    reg [31:0] mul_a, mul_b;
    reg [63:0] mul_result;

    // Reduction registers
    reg [287:0] reduced;
    reg [31:0]  high_words [0:7];
    reg [3:0]   reduce_idx;
    reg [64:0]  reduce_acc;

    // Propagation
    reg [3:0]   prop_idx;
    reg [32:0]  carry;

    // Final result words
    reg [31:0] r_words [0:7];

    integer k;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            done <= 1'b0;
            state <= IDLE;
            result <= 256'd0;
            i <= 4'd0;
            j <= 4'd0;
            mul_a <= 32'd0;
            mul_b <= 32'd0;
            mul_result <= 64'd0;
            reduce_idx <= 4'd0;
            reduce_acc <= 65'd0;
            prop_idx <= 4'd0;
            carry <= 33'd0;
            reduced <= 288'd0;

            for (k = 0; k < 8; k = k + 1) begin
                a_words[k] <= 32'd0;
                b_words[k] <= 32'd0;
                high_words[k] <= 32'd0;
                r_words[k] <= 32'd0;
            end
            for (k = 0; k < 16; k = k + 1) begin
                acc[k] <= 33'd0;
            end
        end else begin
            case (state)
                IDLE: begin
                    done <= 1'b0;
                    if (start) begin
                        // Load inputs into word arrays
                        a_words[0] <= a[31:0];
                        a_words[1] <= a[63:32];
                        a_words[2] <= a[95:64];
                        a_words[3] <= a[127:96];
                        a_words[4] <= a[159:128];
                        a_words[5] <= a[191:160];
                        a_words[6] <= a[223:192];
                        a_words[7] <= a[255:224];

                        b_words[0] <= b[31:0];
                        b_words[1] <= b[63:32];
                        b_words[2] <= b[95:64];
                        b_words[3] <= b[127:96];
                        b_words[4] <= b[159:128];
                        b_words[5] <= b[191:160];
                        b_words[6] <= b[223:192];
                        b_words[7] <= b[255:224];

                        // Clear accumulator
                        for (k = 0; k < 16; k = k + 1) begin
                            acc[k] <= 33'd0;
                        end

                        i <= 4'd0;
                        j <= 4'd0;
                        state <= LOAD;
                    end
                end

                LOAD: begin
                    // Load operands for multiplication
                    mul_a <= a_words[i];
                    mul_b <= b_words[j];
                    state <= MULTIPLY;
                end

                MULTIPLY: begin
                    // Perform 32x32 multiplication
                    mul_result <= {32'd0, mul_a} * {32'd0, mul_b};
                    state <= ACCUMULATE;
                end

                ACCUMULATE: begin
                    // Add partial product to accumulator
                    acc[i + j] <= acc[i + j] + {1'b0, mul_result[31:0]};
                    acc[i + j + 1] <= acc[i + j + 1] + {1'b0, mul_result[63:32]};
                    state <= NEXT_J;
                end

                NEXT_J: begin
                    if (j == 4'd7) begin
                        j <= 4'd0;
                        state <= NEXT_I;
                    end else begin
                        j <= j + 1'b1;
                        state <= LOAD;
                    end
                end

                NEXT_I: begin
                    if (i == 4'd7) begin
                        // Done with multiplication, propagate carries
                        prop_idx <= 4'd0;
                        carry <= 33'd0;
                        state <= PROPAGATE;
                    end else begin
                        i <= i + 1'b1;
                        state <= LOAD;
                    end
                end

                PROPAGATE: begin
                    // Propagate carries through accumulator
                    if (prop_idx < 4'd15) begin
                        acc[prop_idx] <= {1'b0, acc[prop_idx][31:0]};
                        acc[prop_idx + 1] <= acc[prop_idx + 1] + acc[prop_idx][32:32];
                        prop_idx <= prop_idx + 1'b1;
                    end else begin
                        // Extract high and low parts
                        high_words[0] <= acc[8][31:0];
                        high_words[1] <= acc[9][31:0];
                        high_words[2] <= acc[10][31:0];
                        high_words[3] <= acc[11][31:0];
                        high_words[4] <= acc[12][31:0];
                        high_words[5] <= acc[13][31:0];
                        high_words[6] <= acc[14][31:0];
                        high_words[7] <= acc[15][31:0];

                        r_words[0] <= acc[0][31:0];
                        r_words[1] <= acc[1][31:0];
                        r_words[2] <= acc[2][31:0];
                        r_words[3] <= acc[3][31:0];
                        r_words[4] <= acc[4][31:0];
                        r_words[5] <= acc[5][31:0];
                        r_words[6] <= acc[6][31:0];
                        r_words[7] <= acc[7][31:0];

                        reduce_idx <= 4'd0;
                        reduce_acc <= 65'd0;
                        state <= REDUCE1;
                    end
                end

                REDUCE1: begin
                    // Reduction: r = low + high * 977 + (high << 32)
                    // Process one word at a time
                    if (reduce_idx < 4'd8) begin
                        // Compute: r[idx] += high[idx] * 977
                        mul_a <= high_words[reduce_idx];
                        mul_b <= REDUCTION_CONST;
                        state <= REDUCE2;
                    end else begin
                        // Propagate final carries
                        prop_idx <= 4'd0;
                        carry <= 33'd0;
                        state <= REDUCE3;
                    end
                end

                REDUCE2: begin
                    // Add high[idx] * 977 to r[idx]
                    // And add high[idx-1] to r[idx] (the << 32 part)
                    mul_result <= {32'd0, mul_a} * {32'd0, mul_b};

                    if (reduce_idx == 4'd0) begin
                        reduce_acc <= {1'b0, r_words[0]} + mul_result + reduce_acc[64:32];
                    end else begin
                        reduce_acc <= {1'b0, r_words[reduce_idx]} + mul_result +
                                     {1'b0, high_words[reduce_idx - 1]} + reduce_acc[64:32];
                    end

                    r_words[reduce_idx] <= reduce_acc[31:0];
                    reduce_idx <= reduce_idx + 1'b1;
                    state <= REDUCE1;
                end

                REDUCE3: begin
                    // Final carry propagation
                    if (prop_idx < 4'd8) begin
                        if (prop_idx == 4'd0) begin
                            carry <= {1'b0, r_words[0]};
                        end else begin
                            carry <= {1'b0, r_words[prop_idx]} + {32'd0, carry[32]};
                        end
                        r_words[prop_idx] <= carry[31:0];
                        prop_idx <= prop_idx + 1'b1;
                    end else begin
                        // Handle any remaining overflow
                        if (carry[32]) begin
                            // Add 977 + (1 << 32) for overflow
                            reduce_acc <= {1'b0, r_words[0]} + REDUCTION_CONST;
                            r_words[0] <= reduce_acc[31:0];
                            reduce_acc <= {1'b0, r_words[1]} + 1'b1 + reduce_acc[64:32];
                            r_words[1] <= reduce_acc[31:0];
                            // Continue propagation if needed
                        end
                        state <= NORMALIZE;
                    end
                end

                NORMALIZE: begin
                    // Assemble result
                    result <= {r_words[7], r_words[6], r_words[5], r_words[4],
                              r_words[3], r_words[2], r_words[1], r_words[0]};

                    // Check if >= p and subtract if needed
                    if ({r_words[7], r_words[6], r_words[5], r_words[4],
                         r_words[3], r_words[2], r_words[1], r_words[0]} >= SECP256K1_P) begin
                        result <= {r_words[7], r_words[6], r_words[5], r_words[4],
                                  r_words[3], r_words[2], r_words[1], r_words[0]} - SECP256K1_P;
                    end

                    state <= DONE_STATE;
                end

                DONE_STATE: begin
                    done <= 1'b1;
                    state <= IDLE;
                end

                default: state <= IDLE;
            endcase
        end
    end

endmodule
