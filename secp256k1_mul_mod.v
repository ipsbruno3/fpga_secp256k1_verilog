
//-----------------------------------------------------------------------------
// secp256k1_mul_mod.v
// Modular multiplication for secp256k1: r = (a * b) mod p
// Uses the special form of p: p = 2^256 - 2^32 - 977
// Reduction: 2^256 ≡ 2^32 + 977 (mod p)
//-----------------------------------------------------------------------------

module secp256k1_mul_mod (
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
    localparam [31:0]  REDUCTION_CONST = 32'd977;

    // State machine
    reg [3:0] state;
    localparam IDLE       = 4'd0;
    localparam MULTIPLY   = 4'd1;
    localparam REDUCE1    = 4'd2;
    localparam REDUCE2    = 4'd3;
    localparam REDUCE3    = 4'd4;
    localparam NORMALIZE  = 4'd5;
    localparam DONE_STATE = 4'd6;

    // Internal registers
    reg [511:0] product;        // Full 512-bit product
    reg [288:0] reduced;        // Intermediate reduction result (needs extra bits)
    reg [255:0] high_part;      // Upper 256 bits of product
    reg [255:0] low_part;       // Lower 256 bits of product
    reg [287:0] fold_result;    // Result after folding high part
    reg [8:0]   overflow;       // Overflow from reduction

    // Wires for multiplication (using DSP blocks)
    wire [511:0] mult_result;

    // 256x256 bit multiplication
    assign mult_result = a * b;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            result   <= 256'd0;
            done     <= 1'b0;
            state    <= IDLE;
            product  <= 512'd0;
            reduced  <= 289'd0;
            high_part <= 256'd0;
            low_part  <= 256'd0;
            fold_result <= 288'd0;
            overflow <= 9'd0;
        end else begin
            case (state)
                IDLE: begin
                    done <= 1'b0;
                    if (start) begin
                        product <= mult_result;
                        state <= MULTIPLY;
                    end
                end

                MULTIPLY: begin
                    // Split product into high and low parts
                    low_part  <= product[255:0];
                    high_part <= product[511:256];
                    state <= REDUCE1;
                end

                REDUCE1: begin
                    // First reduction: r = low + high * 977 + high << 32
                    // This uses: 2^256 ≡ 2^32 + 977 (mod p)
                    // fold_result = low + high * (2^32 + 977)
                    fold_result <= {32'd0, low_part} +
                                   ({high_part, 32'd0}) +  // high << 32
                                   (high_part * REDUCTION_CONST);  // high * 977
                    state <= REDUCE2;
                end

                REDUCE2: begin
                    // Check if we need another reduction (overflow beyond 256 bits)
                    if (fold_result[287:256] != 32'd0) begin
                        // Need to reduce again: take bits [287:256] and fold them
                        overflow <= {1'b0, fold_result[287:256]};
                        reduced <= {33'd0, fold_result[255:0]} +
                                  ({fold_result[287:256], 32'd0}) +
                                  (fold_result[287:256] * REDUCTION_CONST);
                    end else begin
                        reduced <= {33'd0, fold_result[255:0]};
                    end
                    state <= REDUCE3;
                end

                REDUCE3: begin
                    // Final overflow handling
                    if (reduced[288:256] != 33'd0) begin
                        // One more reduction pass
                        reduced <= {33'd0, reduced[255:0]} +
                                  ({reduced[264:256], 32'd0}) +
                                  (reduced[264:256] * REDUCTION_CONST);
                    end
                    state <= NORMALIZE;
                end

                NORMALIZE: begin
                    // Final normalization: if result >= p, subtract p
                    if (reduced[255:0] >= SECP256K1_P) begin
                        result <= reduced[255:0] - SECP256K1_P;
                    end else begin
                        result <= reduced[255:0];
                    end
                    state <= DONE_STATE;
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
