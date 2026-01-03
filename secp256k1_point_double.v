//-----------------------------------------------------------------------------
// secp256k1_point_double.v
// Elliptic curve point doubling for secp256k1 (curve parameter a = 0)
//
// Description:
//   Computes 2P (point doubling) in Jacobian coordinates
//   - Input P: (X1, Y1, Z1) in Jacobian coordinates
//   - Output 2P: (X3, Y3, Z3) in Jacobian coordinates
//
// secp256k1-Optimized Formulas (a = 0):
//   S  = 4*X*Y²           - Intermediate value
//   M  = 3*X²             - Slope (simplified since a=0)
//   X3 = M² - 2*S         - New X coordinate
//   Y3 = M*(S - X3) - 8*Y⁴  - New Y coordinate
//   Z3 = 2*Y*Z            - New Z coordinate
//
// Optimization Note:
//   Generic curves have M = 3*X² + a*Z⁴
//   secp256k1 has a = 0, eliminating the a*Z⁴ term
//   This saves 2 multiplications per doubling operation
//
// Latency: ~21 states × operation_latency ≈ 150+ cycles
// Operations: 8 multiplications, 8 additions
//
// Author: Bruno Silva (bsbruno@proton.me)
//-----------------------------------------------------------------------------

module secp256k1_point_double (
    input  wire         clk,
    input  wire         rst_n,
    input  wire         start,
    input  wire [255:0] x1,
    input  wire [255:0] y1,
    input  wire [255:0] z1,
    output reg  [255:0] x3,
    output reg  [255:0] y3,
    output reg  [255:0] z3,
    output reg          done
);

    // secp256k1 prime
    localparam [255:0] SECP256K1_P = 256'hFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEFFFFFC2F;

    // State machine
    reg [4:0] state;
    localparam IDLE         = 5'd0;
    localparam CALC_YY      = 5'd1;  // YY = Y1²
    localparam CALC_XX      = 5'd2;  // XX = X1²
    localparam CALC_ZZ      = 5'd3;  // ZZ = Z1²  (for Z3)
    localparam CALC_S1      = 5'd4;  // S = X1 * YY
    localparam CALC_S2      = 5'd5;  // S = 4 * S (done with adds)
    localparam CALC_M       = 5'd6;  // M = 3 * XX
    localparam CALC_MM      = 5'd7;  // MM = M²
    localparam CALC_X3      = 5'd8;  // X3 = MM - 2*S
    localparam CALC_YYYY    = 5'd9;  // YYYY = YY²
    localparam CALC_YYYY8   = 5'd10; // 8*YYYY
    localparam CALC_SDIFF   = 5'd11; // S - X3
    localparam CALC_Y3_1    = 5'd12; // M * (S - X3)
    localparam CALC_Y3_2    = 5'd13; // Y3 = M*(S-X3) - 8*YYYY
    localparam CALC_Z3_1    = 5'd14; // 2*Y1
    localparam CALC_Z3_2    = 5'd15; // Z3 = 2*Y1*Z1
    localparam DONE_STATE   = 5'd16;

    // Intermediate values
    reg [255:0] yy;       // Y1²
    reg [255:0] xx;       // X1²
    reg [255:0] s;        // S = 4*X1*Y1²
    reg [255:0] m;        // M = 3*X1²
    reg [255:0] mm;       // M²
    reg [255:0] yyyy;     // Y1⁴
    reg [255:0] yyyy8;    // 8*Y1⁴
    reg [255:0] sdiff;    // S - X3
    reg [255:0] y2;       // 2*Y1

    // Multiplier interface
    reg         mul_start;
    reg [255:0] mul_a, mul_b;
    wire [255:0] mul_result;
    wire        mul_done;

    // Add/Sub interfaces
    reg         add_start, sub_start;
    reg [255:0] add_a, add_b, sub_a, sub_b;
    wire [255:0] add_result, sub_result;
    wire        add_done, sub_done;

    // Instantiate arithmetic modules
    secp256k1_mul_mod u_mul (
        .clk(clk), .rst_n(rst_n), .start(mul_start),
        .a(mul_a), .b(mul_b), .result(mul_result), .done(mul_done)
    );

    secp256k1_add_mod u_add (
        .clk(clk), .rst_n(rst_n), .start(add_start),
        .a(add_a), .b(add_b), .result(add_result), .done(add_done)
    );

    secp256k1_sub_mod u_sub (
        .clk(clk), .rst_n(rst_n), .start(sub_start),
        .a(sub_a), .b(sub_b), .result(sub_result), .done(sub_done)
    );

    // Internal state tracking
    reg wait_mul, wait_add, wait_sub;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            x3 <= 256'd0;
            y3 <= 256'd0;
            z3 <= 256'd0;
            done <= 1'b0;
            state <= IDLE;
            mul_start <= 1'b0;
            add_start <= 1'b0;
            sub_start <= 1'b0;
            wait_mul <= 1'b0;
            wait_add <= 1'b0;
            wait_sub <= 1'b0;
            yy <= 256'd0;
            xx <= 256'd0;
            s <= 256'd0;
            m <= 256'd0;
            mm <= 256'd0;
            yyyy <= 256'd0;
            yyyy8 <= 256'd0;
            sdiff <= 256'd0;
            y2 <= 256'd0;
        end else begin
            // Default: clear start signals
            mul_start <= 1'b0;
            add_start <= 1'b0;
            sub_start <= 1'b0;

            case (state)
                IDLE: begin
                    done <= 1'b0;
                    if (start) begin
                        // Start computing YY = Y1²
                        mul_a <= y1;
                        mul_b <= y1;
                        mul_start <= 1'b1;
                        wait_mul <= 1'b1;
                        state <= CALC_YY;
                    end
                end

                CALC_YY: begin
                    if (wait_mul && mul_done) begin
                        yy <= mul_result;
                        wait_mul <= 1'b0;
                        // Start XX = X1²
                        mul_a <= x1;
                        mul_b <= x1;
                        mul_start <= 1'b1;
                        wait_mul <= 1'b1;
                        state <= CALC_XX;
                    end
                end

                CALC_XX: begin
                    if (wait_mul && mul_done) begin
                        xx <= mul_result;
                        wait_mul <= 1'b0;
                        // Start S1 = X1 * YY
                        mul_a <= x1;
                        mul_b <= yy;
                        mul_start <= 1'b1;
                        wait_mul <= 1'b1;
                        state <= CALC_S1;
                    end
                end

                CALC_S1: begin
                    if (wait_mul && mul_done) begin
                        s <= mul_result;  // S = X1 * YY
                        wait_mul <= 1'b0;
                        // S = 2 * S
                        add_a <= mul_result;
                        add_b <= mul_result;
                        add_start <= 1'b1;
                        wait_add <= 1'b1;
                        state <= CALC_S2;
                    end
                end

                CALC_S2: begin
                    if (wait_add && add_done) begin
                        wait_add <= 1'b0;
                        // S = 4 * (X1 * YY) = 2 * (2 * X1 * YY)
                        add_a <= add_result;
                        add_b <= add_result;
                        add_start <= 1'b1;
                        wait_add <= 1'b1;
                        s <= add_result;  // temporary 2S
                        state <= CALC_M;
                    end
                end

                CALC_M: begin
                    if (wait_add && add_done) begin
                        s <= add_result;  // S = 4*X1*YY
                        wait_add <= 1'b0;
                        // M = 3 * XX = XX + XX + XX
                        add_a <= xx;
                        add_b <= xx;
                        add_start <= 1'b1;
                        wait_add <= 1'b1;
                        state <= CALC_MM;
                    end
                end

                CALC_MM: begin
                    if (wait_add && add_done) begin
                        wait_add <= 1'b0;
                        // 2*XX done, now add XX for 3*XX
                        add_a <= add_result;
                        add_b <= xx;
                        add_start <= 1'b1;
                        wait_add <= 1'b1;
                        state <= CALC_X3;
                    end
                end

                CALC_X3: begin
                    if (wait_add && add_done) begin
                        m <= add_result;  // M = 3*XX
                        wait_add <= 1'b0;
                        // Compute M²
                        mul_a <= add_result;
                        mul_b <= add_result;
                        mul_start <= 1'b1;
                        wait_mul <= 1'b1;
                        state <= CALC_YYYY;
                    end
                end

                CALC_YYYY: begin
                    if (wait_mul && mul_done) begin
                        mm <= mul_result;  // MM = M²
                        wait_mul <= 1'b0;
                        // X3 = MM - 2*S
                        add_a <= s;
                        add_b <= s;
                        add_start <= 1'b1;
                        wait_add <= 1'b1;
                        state <= CALC_YYYY8;
                    end
                end

                CALC_YYYY8: begin
                    if (wait_add && add_done) begin
                        wait_add <= 1'b0;
                        // Now compute X3 = MM - 2S
                        sub_a <= mm;
                        sub_b <= add_result;  // 2S
                        sub_start <= 1'b1;
                        wait_sub <= 1'b1;
                        state <= CALC_SDIFF;
                    end
                end

                CALC_SDIFF: begin
                    if (wait_sub && sub_done) begin
                        x3 <= sub_result;  // X3 = MM - 2S
                        wait_sub <= 1'b0;
                        // Compute S - X3
                        sub_a <= s;
                        sub_b <= sub_result;
                        sub_start <= 1'b1;
                        wait_sub <= 1'b1;
                        state <= CALC_Y3_1;
                    end
                end

                CALC_Y3_1: begin
                    if (wait_sub && sub_done) begin
                        sdiff <= sub_result;  // S - X3
                        wait_sub <= 1'b0;
                        // Compute M * (S - X3)
                        mul_a <= m;
                        mul_b <= sub_result;
                        mul_start <= 1'b1;
                        wait_mul <= 1'b1;
                        state <= CALC_Y3_2;
                    end
                end

                CALC_Y3_2: begin
                    if (wait_mul && mul_done) begin
                        wait_mul <= 1'b0;
                        // Store M*(S-X3), now compute YY²
                        sdiff <= mul_result;  // reuse sdiff for M*(S-X3)
                        mul_a <= yy;
                        mul_b <= yy;
                        mul_start <= 1'b1;
                        wait_mul <= 1'b1;
                        state <= CALC_Z3_1;
                    end
                end

                CALC_Z3_1: begin
                    if (wait_mul && mul_done) begin
                        yyyy <= mul_result;  // YYYY = YY²
                        wait_mul <= 1'b0;
                        // Compute 8*YYYY = 2*2*2*YYYY
                        add_a <= mul_result;
                        add_b <= mul_result;
                        add_start <= 1'b1;
                        wait_add <= 1'b1;
                        state <= CALC_Z3_2;
                    end
                end

                CALC_Z3_2: begin
                    if (wait_add && add_done) begin
                        wait_add <= 1'b0;
                        // 2*YYYY, continue to 4*YYYY
                        add_a <= add_result;
                        add_b <= add_result;
                        add_start <= 1'b1;
                        wait_add <= 1'b1;
                        yyyy8 <= add_result;  // Store 2*YYYY temporarily
                        state <= 5'd17;  // Continue doubling
                    end
                end

                5'd17: begin
                    if (wait_add && add_done) begin
                        wait_add <= 1'b0;
                        // 4*YYYY, continue to 8*YYYY
                        add_a <= add_result;
                        add_b <= add_result;
                        add_start <= 1'b1;
                        wait_add <= 1'b1;
                        state <= 5'd18;
                    end
                end

                5'd18: begin
                    if (wait_add && add_done) begin
                        yyyy8 <= add_result;  // 8*YYYY
                        wait_add <= 1'b0;
                        // Y3 = M*(S-X3) - 8*YYYY
                        sub_a <= sdiff;  // M*(S-X3)
                        sub_b <= add_result;  // 8*YYYY
                        sub_start <= 1'b1;
                        wait_sub <= 1'b1;
                        state <= 5'd19;
                    end
                end

                5'd19: begin
                    if (wait_sub && sub_done) begin
                        y3 <= sub_result;  // Y3 done
                        wait_sub <= 1'b0;
                        // Z3 = 2*Y1*Z1
                        // First compute 2*Y1
                        add_a <= y1;
                        add_b <= y1;
                        add_start <= 1'b1;
                        wait_add <= 1'b1;
                        state <= 5'd20;
                    end
                end

                5'd20: begin
                    if (wait_add && add_done) begin
                        y2 <= add_result;  // 2*Y1
                        wait_add <= 1'b0;
                        // Z3 = 2*Y1 * Z1
                        mul_a <= add_result;
                        mul_b <= z1;
                        mul_start <= 1'b1;
                        wait_mul <= 1'b1;
                        state <= 5'd21;
                    end
                end

                5'd21: begin
                    if (wait_mul && mul_done) begin
                        z3 <= mul_result;  // Z3 done
                        wait_mul <= 1'b0;
                        state <= DONE_STATE;
                    end
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
