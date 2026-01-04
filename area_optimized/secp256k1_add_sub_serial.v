//-----------------------------------------------------------------------------
// secp256k1_add_sub_serial.v
// Serial modular addition and subtraction for secp256k1 - Area optimized
// Processes 32 bits per cycle (8 cycles + normalization)
// Combines add and sub in one module to share resources
//-----------------------------------------------------------------------------

module secp256k1_add_mod_serial (
    input  wire         clk,
    input  wire         rst_n,
    input  wire         start,
    input  wire [255:0] a,
    input  wire [255:0] b,
    output reg  [255:0] result,
    output reg          done
);

    // secp256k1 prime (word-by-word)
    localparam [31:0] P0 = 32'hFFFFFC2F;
    localparam [31:0] P1 = 32'hFFFFFFFE;
    localparam [31:0] P2 = 32'hFFFFFFFF;
    localparam [31:0] P3 = 32'hFFFFFFFF;
    localparam [31:0] P4 = 32'hFFFFFFFF;
    localparam [31:0] P5 = 32'hFFFFFFFF;
    localparam [31:0] P6 = 32'hFFFFFFFF;
    localparam [31:0] P7 = 32'hFFFFFFFF;

    // State machine
    reg [2:0] state;
    localparam IDLE      = 3'd0;
    localparam ADD_WORD  = 3'd1;
    localparam CHECK_GE  = 3'd2;
    localparam SUB_P     = 3'd3;
    localparam DONE_ST   = 3'd4;

    // Working registers
    reg [31:0] a_word, b_word, p_word;
    reg [31:0] sum_words [0:7];
    reg [32:0] word_sum;
    reg        carry;
    reg [3:0]  word_idx;
    reg        need_sub;

    // P lookup
    function [31:0] get_p_word;
        input [2:0] idx;
        begin
            case (idx)
                3'd0: get_p_word = P0;
                3'd1: get_p_word = P1;
                default: get_p_word = 32'hFFFFFFFF;
            endcase
        end
    endfunction

    integer i;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            done <= 1'b0;
            result <= 256'd0;
            state <= IDLE;
            carry <= 1'b0;
            word_idx <= 4'd0;
            need_sub <= 1'b0;
            word_sum <= 33'd0;
            for (i = 0; i < 8; i = i + 1) sum_words[i] <= 32'd0;
        end else begin
            case (state)
                IDLE: begin
                    done <= 1'b0;
                    if (start) begin
                        word_idx <= 4'd0;
                        carry <= 1'b0;
                        state <= ADD_WORD;
                    end
                end

                ADD_WORD: begin
                    // Extract current words
                    case (word_idx[2:0])
                        3'd0: begin a_word <= a[31:0];    b_word <= b[31:0];    end
                        3'd1: begin a_word <= a[63:32];   b_word <= b[63:32];   end
                        3'd2: begin a_word <= a[95:64];   b_word <= b[95:64];   end
                        3'd3: begin a_word <= a[127:96];  b_word <= b[127:96];  end
                        3'd4: begin a_word <= a[159:128]; b_word <= b[159:128]; end
                        3'd5: begin a_word <= a[191:160]; b_word <= b[191:160]; end
                        3'd6: begin a_word <= a[223:192]; b_word <= b[223:192]; end
                        3'd7: begin a_word <= a[255:224]; b_word <= b[255:224]; end
                    endcase

                    // Compute sum with carry
                    word_sum <= {1'b0, a_word} + {1'b0, b_word} + {32'd0, carry};
                    sum_words[word_idx[2:0]] <= word_sum[31:0];
                    carry <= word_sum[32];

                    if (word_idx == 4'd7) begin
                        state <= CHECK_GE;
                        word_idx <= 4'd7;  // Start from MSB for comparison
                    end else begin
                        word_idx <= word_idx + 1'b1;
                    end
                end

                CHECK_GE: begin
                    // Check if sum >= p (starting from MSB)
                    // If carry is set, definitely >= p
                    if (carry) begin
                        need_sub <= 1'b1;
                        word_idx <= 4'd0;
                        carry <= 1'b0;
                        state <= SUB_P;
                    end else begin
                        // Compare word by word from MSB
                        p_word <= get_p_word(word_idx[2:0]);
                        if (sum_words[word_idx[2:0]] > p_word) begin
                            need_sub <= 1'b1;
                            word_idx <= 4'd0;
                            carry <= 1'b0;
                            state <= SUB_P;
                        end else if (sum_words[word_idx[2:0]] < p_word) begin
                            need_sub <= 1'b0;
                            state <= DONE_ST;
                        end else begin
                            // Equal, check next word
                            if (word_idx == 4'd0) begin
                                // All words equal means sum == p, need to subtract
                                need_sub <= 1'b1;
                                carry <= 1'b0;
                                state <= SUB_P;
                            end else begin
                                word_idx <= word_idx - 1'b1;
                            end
                        end
                    end
                end

                SUB_P: begin
                    // Subtract p from sum (serial)
                    p_word <= get_p_word(word_idx[2:0]);
                    word_sum <= {1'b0, sum_words[word_idx[2:0]]} - {1'b0, p_word} - {32'd0, carry};
                    sum_words[word_idx[2:0]] <= word_sum[31:0];
                    carry <= word_sum[32];  // Borrow

                    if (word_idx == 4'd7) begin
                        state <= DONE_ST;
                    end else begin
                        word_idx <= word_idx + 1'b1;
                    end
                end

                DONE_ST: begin
                    result <= {sum_words[7], sum_words[6], sum_words[5], sum_words[4],
                              sum_words[3], sum_words[2], sum_words[1], sum_words[0]};
                    done <= 1'b1;
                    state <= IDLE;
                end

                default: state <= IDLE;
            endcase
        end
    end

endmodule

//-----------------------------------------------------------------------------
// Serial modular subtraction
//-----------------------------------------------------------------------------
module secp256k1_sub_mod_serial (
    input  wire         clk,
    input  wire         rst_n,
    input  wire         start,
    input  wire [255:0] a,
    input  wire [255:0] b,
    output reg  [255:0] result,
    output reg          done
);

    // secp256k1 prime (word-by-word)
    localparam [31:0] P0 = 32'hFFFFFC2F;
    localparam [31:0] P1 = 32'hFFFFFFFE;
    localparam [31:0] P2 = 32'hFFFFFFFF;
    localparam [31:0] P3 = 32'hFFFFFFFF;
    localparam [31:0] P4 = 32'hFFFFFFFF;
    localparam [31:0] P5 = 32'hFFFFFFFF;
    localparam [31:0] P6 = 32'hFFFFFFFF;
    localparam [31:0] P7 = 32'hFFFFFFFF;

    // State machine
    reg [2:0] state;
    localparam IDLE      = 3'd0;
    localparam SUB_WORD  = 3'd1;
    localparam CHECK_NEG = 3'd2;
    localparam ADD_P     = 3'd3;
    localparam DONE_ST   = 3'd4;

    // Working registers
    reg [31:0] a_word, b_word, p_word;
    reg [31:0] diff_words [0:7];
    reg [32:0] word_diff;
    reg        borrow;
    reg [3:0]  word_idx;
    reg        need_add;

    // P lookup
    function [31:0] get_p_word;
        input [2:0] idx;
        begin
            case (idx)
                3'd0: get_p_word = P0;
                3'd1: get_p_word = P1;
                default: get_p_word = 32'hFFFFFFFF;
            endcase
        end
    endfunction

    integer i;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            done <= 1'b0;
            result <= 256'd0;
            state <= IDLE;
            borrow <= 1'b0;
            word_idx <= 4'd0;
            need_add <= 1'b0;
            word_diff <= 33'd0;
            for (i = 0; i < 8; i = i + 1) diff_words[i] <= 32'd0;
        end else begin
            case (state)
                IDLE: begin
                    done <= 1'b0;
                    if (start) begin
                        word_idx <= 4'd0;
                        borrow <= 1'b0;
                        state <= SUB_WORD;
                    end
                end

                SUB_WORD: begin
                    // Extract current words
                    case (word_idx[2:0])
                        3'd0: begin a_word <= a[31:0];    b_word <= b[31:0];    end
                        3'd1: begin a_word <= a[63:32];   b_word <= b[63:32];   end
                        3'd2: begin a_word <= a[95:64];   b_word <= b[95:64];   end
                        3'd3: begin a_word <= a[127:96];  b_word <= b[127:96];  end
                        3'd4: begin a_word <= a[159:128]; b_word <= b[159:128]; end
                        3'd5: begin a_word <= a[191:160]; b_word <= b[191:160]; end
                        3'd6: begin a_word <= a[223:192]; b_word <= b[223:192]; end
                        3'd7: begin a_word <= a[255:224]; b_word <= b[255:224]; end
                    endcase

                    // Compute difference with borrow
                    word_diff <= {1'b0, a_word} - {1'b0, b_word} - {32'd0, borrow};
                    diff_words[word_idx[2:0]] <= word_diff[31:0];
                    borrow <= word_diff[32];  // Borrow if negative

                    if (word_idx == 4'd7) begin
                        state <= CHECK_NEG;
                    end else begin
                        word_idx <= word_idx + 1'b1;
                    end
                end

                CHECK_NEG: begin
                    // If borrow is set after last word, result is negative
                    if (borrow) begin
                        need_add <= 1'b1;
                        word_idx <= 4'd0;
                        borrow <= 1'b0;  // Reuse as carry for addition
                        state <= ADD_P;
                    end else begin
                        state <= DONE_ST;
                    end
                end

                ADD_P: begin
                    // Add p to result (serial)
                    p_word <= get_p_word(word_idx[2:0]);
                    word_diff <= {1'b0, diff_words[word_idx[2:0]]} + {1'b0, p_word} + {32'd0, borrow};
                    diff_words[word_idx[2:0]] <= word_diff[31:0];
                    borrow <= word_diff[32];  // Carry

                    if (word_idx == 4'd7) begin
                        state <= DONE_ST;
                    end else begin
                        word_idx <= word_idx + 1'b1;
                    end
                end

                DONE_ST: begin
                    result <= {diff_words[7], diff_words[6], diff_words[5], diff_words[4],
                              diff_words[3], diff_words[2], diff_words[1], diff_words[0]};
                    done <= 1'b1;
                    state <= IDLE;
                end

                default: state <= IDLE;
            endcase
        end
    end

endmodule
