//-----------------------------------------------------------------------------
// secp256k1_point_add.v
// Elliptic curve point addition for secp256k1
//
// Description:
//   Computes P3 = P1 + P2 using mixed Jacobian-Affine coordinates
//   - Input P1: (X1, Y1, Z1) in Jacobian coordinates
//   - Input P2: (X2, Y2, 1) in Affine coordinates (Z2 = 1)
//   - Output P3: (X3, Y3, Z3) in Jacobian coordinates
//
// Mixed Addition Formulas (Z2 = 1 optimization):
//   U2 = X2 * Z1²           - Convert P2.x to Jacobian space
//   S2 = Y2 * Z1³           - Convert P2.y to Jacobian space
//   H  = U2 - X1            - Difference in X coordinates
//   R  = S2 - Y1            - Difference in Y coordinates
//   X3 = R² - H³ - 2*X1*H²  - New X coordinate
//   Y3 = R*(X1*H² - X3) - Y1*H³  - New Y coordinate
//   Z3 = Z1 * H             - New Z coordinate
//
// Latency: ~19 states × multiplier_latency ≈ 130+ cycles
// Operations: 12 multiplications, 7 additions/subtractions
//
// Note: This module assumes P1 ≠ P2 (use point_double for P1 = P2)
//
// Author: Bruno Silva (bsbruno@proton.me)
//-----------------------------------------------------------------------------

module secp256k1_point_add (
    input  wire         clk,
    input  wire         rst_n,
    input  wire         start,
    input  wire [255:0] x1,
    input  wire [255:0] y1,
    input  wire [255:0] z1,
    input  wire [255:0] x2,      // Affine X (Z2 = 1)
    input  wire [255:0] y2,      // Affine Y (Z2 = 1)
    output reg  [255:0] x3,
    output reg  [255:0] y3,
    output reg  [255:0] z3,
    output reg          done
);

    // State machine
    reg [4:0] state;
    localparam IDLE         = 5'd0;
    localparam CALC_Z1Z1    = 5'd1;   // Z1²
    localparam CALC_Z1Z1Z1  = 5'd2;   // Z1³
    localparam CALC_U2      = 5'd3;   // U2 = X2 * Z1²
    localparam CALC_S2      = 5'd4;   // S2 = Y2 * Z1³
    localparam CALC_H       = 5'd5;   // H = U2 - X1
    localparam CALC_R       = 5'd6;   // R = S2 - Y1
    localparam CALC_HH      = 5'd7;   // H²
    localparam CALC_HHH     = 5'd8;   // H³
    localparam CALC_X1HH    = 5'd9;   // X1 * H²
    localparam CALC_2X1HH   = 5'd10;  // 2 * X1 * H²
    localparam CALC_RR      = 5'd11;  // R²
    localparam CALC_X3_1    = 5'd12;  // R² - H³
    localparam CALC_X3_2    = 5'd13;  // X3 = R² - H³ - 2*X1*H²
    localparam CALC_Y3_1    = 5'd14;  // X1*H² - X3
    localparam CALC_Y3_2    = 5'd15;  // R * (X1*H² - X3)
    localparam CALC_Y3_3    = 5'd16;  // Y1 * H³
    localparam CALC_Y3_4    = 5'd17;  // Y3 = R*(X1*H² - X3) - Y1*H³
    localparam CALC_Z3      = 5'd18;  // Z3 = Z1 * H
    localparam DONE_STATE   = 5'd19;

    // Intermediate values
    reg [255:0] z1z1;     // Z1²
    reg [255:0] z1z1z1;   // Z1³
    reg [255:0] u2;       // U2 = X2 * Z1²
    reg [255:0] s2;       // S2 = Y2 * Z1³
    reg [255:0] h;        // H = U2 - X1
    reg [255:0] r;        // R = S2 - Y1
    reg [255:0] hh;       // H²
    reg [255:0] hhh;      // H³
    reg [255:0] x1hh;     // X1 * H²
    reg [255:0] x1hh2;    // 2 * X1 * H²
    reg [255:0] rr;       // R²
    reg [255:0] temp1;    // Temporary
    reg [255:0] y1hhh;    // Y1 * H³

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
        end else begin
            // Default: clear start signals
            mul_start <= 1'b0;
            add_start <= 1'b0;
            sub_start <= 1'b0;

            case (state)
                IDLE: begin
                    done <= 1'b0;
                    if (start) begin
                        // Start computing Z1²
                        mul_a <= z1;
                        mul_b <= z1;
                        mul_start <= 1'b1;
                        wait_mul <= 1'b1;
                        state <= CALC_Z1Z1;
                    end
                end

                CALC_Z1Z1: begin
                    if (wait_mul && mul_done) begin
                        z1z1 <= mul_result;
                        wait_mul <= 1'b0;
                        // Z1³ = Z1² * Z1
                        mul_a <= mul_result;
                        mul_b <= z1;
                        mul_start <= 1'b1;
                        wait_mul <= 1'b1;
                        state <= CALC_Z1Z1Z1;
                    end
                end

                CALC_Z1Z1Z1: begin
                    if (wait_mul && mul_done) begin
                        z1z1z1 <= mul_result;
                        wait_mul <= 1'b0;
                        // U2 = X2 * Z1²
                        mul_a <= x2;
                        mul_b <= z1z1;
                        mul_start <= 1'b1;
                        wait_mul <= 1'b1;
                        state <= CALC_U2;
                    end
                end

                CALC_U2: begin
                    if (wait_mul && mul_done) begin
                        u2 <= mul_result;
                        wait_mul <= 1'b0;
                        // S2 = Y2 * Z1³
                        mul_a <= y2;
                        mul_b <= z1z1z1;
                        mul_start <= 1'b1;
                        wait_mul <= 1'b1;
                        state <= CALC_S2;
                    end
                end

                CALC_S2: begin
                    if (wait_mul && mul_done) begin
                        s2 <= mul_result;
                        wait_mul <= 1'b0;
                        // H = U2 - X1
                        sub_a <= u2;
                        sub_b <= x1;
                        sub_start <= 1'b1;
                        wait_sub <= 1'b1;
                        state <= CALC_H;
                    end
                end

                CALC_H: begin
                    if (wait_sub && sub_done) begin
                        h <= sub_result;
                        wait_sub <= 1'b0;
                        // R = S2 - Y1
                        sub_a <= s2;
                        sub_b <= y1;
                        sub_start <= 1'b1;
                        wait_sub <= 1'b1;
                        state <= CALC_R;
                    end
                end

                CALC_R: begin
                    if (wait_sub && sub_done) begin
                        r <= sub_result;
                        wait_sub <= 1'b0;
                        // H² = H * H
                        mul_a <= h;
                        mul_b <= h;
                        mul_start <= 1'b1;
                        wait_mul <= 1'b1;
                        state <= CALC_HH;
                    end
                end

                CALC_HH: begin
                    if (wait_mul && mul_done) begin
                        hh <= mul_result;
                        wait_mul <= 1'b0;
                        // H³ = H² * H
                        mul_a <= mul_result;
                        mul_b <= h;
                        mul_start <= 1'b1;
                        wait_mul <= 1'b1;
                        state <= CALC_HHH;
                    end
                end

                CALC_HHH: begin
                    if (wait_mul && mul_done) begin
                        hhh <= mul_result;
                        wait_mul <= 1'b0;
                        // X1 * H²
                        mul_a <= x1;
                        mul_b <= hh;
                        mul_start <= 1'b1;
                        wait_mul <= 1'b1;
                        state <= CALC_X1HH;
                    end
                end

                CALC_X1HH: begin
                    if (wait_mul && mul_done) begin
                        x1hh <= mul_result;
                        wait_mul <= 1'b0;
                        // 2 * X1 * H²
                        add_a <= mul_result;
                        add_b <= mul_result;
                        add_start <= 1'b1;
                        wait_add <= 1'b1;
                        state <= CALC_2X1HH;
                    end
                end

                CALC_2X1HH: begin
                    if (wait_add && add_done) begin
                        x1hh2 <= add_result;
                        wait_add <= 1'b0;
                        // R²
                        mul_a <= r;
                        mul_b <= r;
                        mul_start <= 1'b1;
                        wait_mul <= 1'b1;
                        state <= CALC_RR;
                    end
                end

                CALC_RR: begin
                    if (wait_mul && mul_done) begin
                        rr <= mul_result;
                        wait_mul <= 1'b0;
                        // R² - H³
                        sub_a <= mul_result;
                        sub_b <= hhh;
                        sub_start <= 1'b1;
                        wait_sub <= 1'b1;
                        state <= CALC_X3_1;
                    end
                end

                CALC_X3_1: begin
                    if (wait_sub && sub_done) begin
                        temp1 <= sub_result;
                        wait_sub <= 1'b0;
                        // X3 = (R² - H³) - 2*X1*H²
                        sub_a <= sub_result;
                        sub_b <= x1hh2;
                        sub_start <= 1'b1;
                        wait_sub <= 1'b1;
                        state <= CALC_X3_2;
                    end
                end

                CALC_X3_2: begin
                    if (wait_sub && sub_done) begin
                        x3 <= sub_result;
                        wait_sub <= 1'b0;
                        // X1*H² - X3
                        sub_a <= x1hh;
                        sub_b <= sub_result;
                        sub_start <= 1'b1;
                        wait_sub <= 1'b1;
                        state <= CALC_Y3_1;
                    end
                end

                CALC_Y3_1: begin
                    if (wait_sub && sub_done) begin
                        temp1 <= sub_result;
                        wait_sub <= 1'b0;
                        // R * (X1*H² - X3)
                        mul_a <= r;
                        mul_b <= sub_result;
                        mul_start <= 1'b1;
                        wait_mul <= 1'b1;
                        state <= CALC_Y3_2;
                    end
                end

                CALC_Y3_2: begin
                    if (wait_mul && mul_done) begin
                        temp1 <= mul_result;
                        wait_mul <= 1'b0;
                        // Y1 * H³
                        mul_a <= y1;
                        mul_b <= hhh;
                        mul_start <= 1'b1;
                        wait_mul <= 1'b1;
                        state <= CALC_Y3_3;
                    end
                end

                CALC_Y3_3: begin
                    if (wait_mul && mul_done) begin
                        y1hhh <= mul_result;
                        wait_mul <= 1'b0;
                        // Y3 = R*(X1*H² - X3) - Y1*H³
                        sub_a <= temp1;
                        sub_b <= mul_result;
                        sub_start <= 1'b1;
                        wait_sub <= 1'b1;
                        state <= CALC_Y3_4;
                    end
                end

                CALC_Y3_4: begin
                    if (wait_sub && sub_done) begin
                        y3 <= sub_result;
                        wait_sub <= 1'b0;
                        // Z3 = Z1 * H
                        mul_a <= z1;
                        mul_b <= h;
                        mul_start <= 1'b1;
                        wait_mul <= 1'b1;
                        state <= CALC_Z3;
                    end
                end

                CALC_Z3: begin
                    if (wait_mul && mul_done) begin
                        z3 <= mul_result;
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
