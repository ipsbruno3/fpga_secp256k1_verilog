//-----------------------------------------------------------------------------
// secp256k1_alu.v
// Shared ALU for secp256k1 field operations - Maximum area optimization
// Single 32-bit datapath handles: ADD, SUB, MUL (modular)
// Uses minimal resources: one 32x32 multiplier, one 32-bit adder
//-----------------------------------------------------------------------------

module secp256k1_alu (
    input  wire         clk,
    input  wire         rst_n,
    input  wire         start,
    input  wire [1:0]   op,          // 00=ADD, 01=SUB, 10=MUL
    input  wire [255:0] a,
    input  wire [255:0] b,
    output reg  [255:0] result,
    output reg          done
);

    // Operation codes
    localparam OP_ADD = 2'b00;
    localparam OP_SUB = 2'b01;
    localparam OP_MUL = 2'b10;

    // secp256k1 prime constants
    localparam [31:0] P0 = 32'hFFFFFC2F;
    localparam [31:0] P1 = 32'hFFFFFFFE;
    localparam [31:0] P_REST = 32'hFFFFFFFF;
    localparam [31:0] REDUCE_CONST = 32'd977;

    // Main state machine
    reg [4:0] state;
    localparam IDLE          = 5'd0;
    localparam LOAD          = 5'd1;
    // ADD/SUB states
    localparam ADDSUB_WORD   = 5'd2;
    localparam ADDSUB_CHECK  = 5'd3;
    localparam ADDSUB_NORM   = 5'd4;
    // MUL states
    localparam MUL_PARTIAL   = 5'd5;
    localparam MUL_ACCUM     = 5'd6;
    localparam MUL_NEXT_J    = 5'd7;
    localparam MUL_NEXT_I    = 5'd8;
    localparam MUL_PROP      = 5'd9;
    localparam MUL_REDUCE    = 5'd10;
    localparam MUL_RED_PROP  = 5'd11;
    localparam MUL_NORM      = 5'd12;
    // Common
    localparam DONE_STATE    = 5'd15;

    // Shared registers (8 words for operands, 16 for accumulator)
    reg [31:0] a_reg [0:7];
    reg [31:0] b_reg [0:7];
    reg [32:0] acc [0:15];    // 33-bit for carries
    reg [31:0] r_reg [0:7];   // Result words

    // Loop indices
    reg [3:0] i_idx, j_idx, k_idx;

    // Shared 32-bit arithmetic
    reg [31:0] alu_a, alu_b;
    reg [63:0] mul_out;
    reg [32:0] add_out;
    reg        carry_borrow;

    // Current operation
    reg [1:0] curr_op;

    // P word lookup
    function [31:0] get_p;
        input [2:0] idx;
        begin
            case (idx)
                3'd0: get_p = P0;
                3'd1: get_p = P1;
                default: get_p = P_REST;
            endcase
        end
    endfunction

    integer n;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            done <= 1'b0;
            state <= IDLE;
            result <= 256'd0;
            i_idx <= 4'd0;
            j_idx <= 4'd0;
            k_idx <= 4'd0;
            carry_borrow <= 1'b0;
            curr_op <= 2'b00;
            mul_out <= 64'd0;
            add_out <= 33'd0;

            for (n = 0; n < 8; n = n + 1) begin
                a_reg[n] <= 32'd0;
                b_reg[n] <= 32'd0;
                r_reg[n] <= 32'd0;
            end
            for (n = 0; n < 16; n = n + 1) begin
                acc[n] <= 33'd0;
            end
        end else begin
            case (state)
                IDLE: begin
                    done <= 1'b0;
                    if (start) begin
                        curr_op <= op;
                        state <= LOAD;
                    end
                end

                LOAD: begin
                    // Load operands into word registers
                    a_reg[0] <= a[31:0];    a_reg[1] <= a[63:32];
                    a_reg[2] <= a[95:64];   a_reg[3] <= a[127:96];
                    a_reg[4] <= a[159:128]; a_reg[5] <= a[191:160];
                    a_reg[6] <= a[223:192]; a_reg[7] <= a[255:224];

                    b_reg[0] <= b[31:0];    b_reg[1] <= b[63:32];
                    b_reg[2] <= b[95:64];   b_reg[3] <= b[127:96];
                    b_reg[4] <= b[159:128]; b_reg[5] <= b[191:160];
                    b_reg[6] <= b[223:192]; b_reg[7] <= b[255:224];

                    carry_borrow <= 1'b0;
                    i_idx <= 4'd0;
                    j_idx <= 4'd0;

                    // Clear accumulator for MUL
                    for (n = 0; n < 16; n = n + 1) acc[n] <= 33'd0;

                    case (op)
                        OP_ADD, OP_SUB: state <= ADDSUB_WORD;
                        OP_MUL: state <= MUL_PARTIAL;
                        default: state <= DONE_STATE;
                    endcase
                end

                //----------------------------------------------------------
                // ADD/SUB: Process 32 bits per cycle
                //----------------------------------------------------------
                ADDSUB_WORD: begin
                    alu_a <= a_reg[i_idx[2:0]];
                    alu_b <= b_reg[i_idx[2:0]];

                    if (curr_op == OP_ADD) begin
                        add_out <= {1'b0, a_reg[i_idx[2:0]]} + {1'b0, b_reg[i_idx[2:0]]} + {32'd0, carry_borrow};
                    end else begin
                        add_out <= {1'b0, a_reg[i_idx[2:0]]} - {1'b0, b_reg[i_idx[2:0]]} - {32'd0, carry_borrow};
                    end

                    r_reg[i_idx[2:0]] <= add_out[31:0];
                    carry_borrow <= add_out[32];

                    if (i_idx == 4'd7) begin
                        state <= ADDSUB_CHECK;
                    end else begin
                        i_idx <= i_idx + 1'b1;
                    end
                end

                ADDSUB_CHECK: begin
                    if (curr_op == OP_ADD) begin
                        // If carry or result >= p, subtract p
                        if (carry_borrow || ({r_reg[7], r_reg[6], r_reg[5], r_reg[4],
                                              r_reg[3], r_reg[2], r_reg[1], r_reg[0]} >=
                                             {P_REST, P_REST, P_REST, P_REST, P_REST, P_REST, P1, P0})) begin
                            i_idx <= 4'd0;
                            carry_borrow <= 1'b0;
                            curr_op <= OP_SUB;  // Reuse SUB logic
                            // Load p into b_reg
                            b_reg[0] <= P0; b_reg[1] <= P1;
                            b_reg[2] <= P_REST; b_reg[3] <= P_REST;
                            b_reg[4] <= P_REST; b_reg[5] <= P_REST;
                            b_reg[6] <= P_REST; b_reg[7] <= P_REST;
                            // Copy result to a_reg
                            for (n = 0; n < 8; n = n + 1) a_reg[n] <= r_reg[n];
                            state <= ADDSUB_NORM;
                        end else begin
                            state <= DONE_STATE;
                        end
                    end else begin  // SUB
                        // If borrow, add p
                        if (carry_borrow) begin
                            i_idx <= 4'd0;
                            carry_borrow <= 1'b0;
                            curr_op <= OP_ADD;  // Reuse ADD logic
                            b_reg[0] <= P0; b_reg[1] <= P1;
                            b_reg[2] <= P_REST; b_reg[3] <= P_REST;
                            b_reg[4] <= P_REST; b_reg[5] <= P_REST;
                            b_reg[6] <= P_REST; b_reg[7] <= P_REST;
                            for (n = 0; n < 8; n = n + 1) a_reg[n] <= r_reg[n];
                            state <= ADDSUB_NORM;
                        end else begin
                            state <= DONE_STATE;
                        end
                    end
                end

                ADDSUB_NORM: begin
                    // Normalize by add/sub p
                    if (curr_op == OP_ADD) begin
                        add_out <= {1'b0, a_reg[i_idx[2:0]]} + {1'b0, b_reg[i_idx[2:0]]} + {32'd0, carry_borrow};
                    end else begin
                        add_out <= {1'b0, a_reg[i_idx[2:0]]} - {1'b0, b_reg[i_idx[2:0]]} - {32'd0, carry_borrow};
                    end

                    r_reg[i_idx[2:0]] <= add_out[31:0];
                    carry_borrow <= add_out[32];

                    if (i_idx == 4'd7) begin
                        state <= DONE_STATE;
                    end else begin
                        i_idx <= i_idx + 1'b1;
                    end
                end

                //----------------------------------------------------------
                // MUL: 32x32 partial products (64 cycles for products)
                //----------------------------------------------------------
                MUL_PARTIAL: begin
                    // One 32x32 multiplication per cycle
                    mul_out <= {32'd0, a_reg[i_idx[2:0]]} * {32'd0, b_reg[j_idx[2:0]]};
                    state <= MUL_ACCUM;
                end

                MUL_ACCUM: begin
                    // Accumulate partial product
                    acc[i_idx + j_idx] <= acc[i_idx + j_idx] + {1'b0, mul_out[31:0]};
                    acc[i_idx + j_idx + 1] <= acc[i_idx + j_idx + 1] + {1'b0, mul_out[63:32]};
                    state <= MUL_NEXT_J;
                end

                MUL_NEXT_J: begin
                    if (j_idx == 4'd7) begin
                        j_idx <= 4'd0;
                        state <= MUL_NEXT_I;
                    end else begin
                        j_idx <= j_idx + 1'b1;
                        state <= MUL_PARTIAL;
                    end
                end

                MUL_NEXT_I: begin
                    if (i_idx == 4'd7) begin
                        k_idx <= 4'd0;
                        state <= MUL_PROP;
                    end else begin
                        i_idx <= i_idx + 1'b1;
                        state <= MUL_PARTIAL;
                    end
                end

                MUL_PROP: begin
                    // Propagate carries through accumulator
                    if (k_idx < 4'd15) begin
                        acc[k_idx + 1] <= acc[k_idx + 1] + {24'd0, acc[k_idx][32:32]};
                        acc[k_idx] <= {1'b0, acc[k_idx][31:0]};
                        k_idx <= k_idx + 1'b1;
                    end else begin
                        // Start reduction
                        i_idx <= 4'd0;
                        carry_borrow <= 1'b0;
                        // Low part to r_reg
                        for (n = 0; n < 8; n = n + 1) r_reg[n] <= acc[n][31:0];
                        // High part to a_reg (for reduction)
                        for (n = 0; n < 8; n = n + 1) a_reg[n] <= acc[n + 8][31:0];
                        state <= MUL_REDUCE;
                    end
                end

                MUL_REDUCE: begin
                    // Reduction: r += high * 977 + (high << 32)
                    // Process one word at a time
                    mul_out <= {32'd0, a_reg[i_idx[2:0]]} * {32'd0, REDUCE_CONST};

                    add_out <= {1'b0, r_reg[i_idx[2:0]]} + {1'b0, mul_out[31:0]} + {32'd0, carry_borrow};

                    if (i_idx > 4'd0) begin
                        // Add high[i-1] for the << 32 part
                        add_out <= add_out + {1'b0, a_reg[i_idx[2:0] - 1]};
                    end

                    r_reg[i_idx[2:0]] <= add_out[31:0];
                    carry_borrow <= add_out[32];

                    if (i_idx == 4'd7) begin
                        k_idx <= 4'd0;
                        // Handle final high word shift
                        add_out <= {1'b0, carry_borrow} + {1'b0, a_reg[7]};
                        carry_borrow <= add_out[32];
                        state <= MUL_RED_PROP;
                    end else begin
                        i_idx <= i_idx + 1'b1;
                    end
                end

                MUL_RED_PROP: begin
                    // Propagate any remaining overflow
                    if (carry_borrow) begin
                        add_out <= {1'b0, r_reg[0]} + {1'b0, REDUCE_CONST};
                        r_reg[0] <= add_out[31:0];
                        add_out <= {1'b0, r_reg[1]} + 1'b1 + {32'd0, add_out[32]};
                        r_reg[1] <= add_out[31:0];
                        // Continue propagation
                        for (n = 2; n < 8; n = n + 1) begin
                            add_out <= {1'b0, r_reg[n]} + {32'd0, add_out[32]};
                            r_reg[n] <= add_out[31:0];
                        end
                        carry_borrow <= add_out[32];
                    end
                    state <= MUL_NORM;
                end

                MUL_NORM: begin
                    // Check if >= p and subtract
                    if ({r_reg[7], r_reg[6], r_reg[5], r_reg[4],
                         r_reg[3], r_reg[2], r_reg[1], r_reg[0]} >=
                        {P_REST, P_REST, P_REST, P_REST, P_REST, P_REST, P1, P0}) begin
                        // Subtract p
                        add_out <= {1'b0, r_reg[0]} - {1'b0, P0};
                        r_reg[0] <= add_out[31:0];
                        carry_borrow <= add_out[32];
                        add_out <= {1'b0, r_reg[1]} - {1'b0, P1} - {32'd0, carry_borrow};
                        r_reg[1] <= add_out[31:0];
                        for (n = 2; n < 8; n = n + 1) begin
                            add_out <= {1'b0, r_reg[n]} - {1'b0, P_REST} - {32'd0, add_out[32]};
                            r_reg[n] <= add_out[31:0];
                        end
                    end
                    state <= DONE_STATE;
                end

                DONE_STATE: begin
                    result <= {r_reg[7], r_reg[6], r_reg[5], r_reg[4],
                              r_reg[3], r_reg[2], r_reg[1], r_reg[0]};
                    done <= 1'b1;
                    state <= IDLE;
                end

                default: state <= IDLE;
            endcase
        end
    end

endmodule
