//-----------------------------------------------------------------------------
// secp256k1_point_ops_serial.v
// Serial point operations using shared ALU - Maximum area optimization
// Single ALU instance handles all field operations
// Point double: ~800 cycles, Point add: ~1000 cycles
//-----------------------------------------------------------------------------

module secp256k1_point_ops_serial (
    input  wire         clk,
    input  wire         rst_n,
    input  wire         start,
    input  wire [1:0]   op,              // 00=DOUBLE, 01=ADD
    // Point P1 (Jacobian)
    input  wire [255:0] x1,
    input  wire [255:0] y1,
    input  wire [255:0] z1,
    // Point P2 (Affine, for ADD only)
    input  wire [255:0] x2,
    input  wire [255:0] y2,
    // Result (Jacobian)
    output reg  [255:0] x3,
    output reg  [255:0] y3,
    output reg  [255:0] z3,
    output reg          done
);

    // Operations
    localparam OP_DOUBLE = 2'b00;
    localparam OP_ADD    = 2'b01;

    // ALU operations
    localparam ALU_ADD = 2'b00;
    localparam ALU_SUB = 2'b01;
    localparam ALU_MUL = 2'b10;

    // Main state machine
    reg [5:0] state;
    localparam IDLE          = 6'd0;
    localparam LOAD          = 6'd1;
    // Point doubling states (secp256k1: a=0)
    // 2P: S=4*X*Y², M=3*X², X'=M²-2S, Y'=M(S-X')-8Y⁴, Z'=2YZ
    localparam DBL_YY        = 6'd2;   // t1 = Y²
    localparam DBL_XX        = 6'd3;   // t2 = X²
    localparam DBL_XYY       = 6'd4;   // t3 = X * Y²
    localparam DBL_S2        = 6'd5;   // t3 = 2 * t3
    localparam DBL_S4        = 6'd6;   // S = 4 * X * Y² = 2 * t3
    localparam DBL_3XX       = 6'd7;   // M = 3 * X² = 2*t2 + t2
    localparam DBL_MM        = 6'd8;   // t4 = M²
    localparam DBL_2S        = 6'd9;   // t5 = 2*S
    localparam DBL_X3        = 6'd10;  // X' = M² - 2S
    localparam DBL_YYYY      = 6'd11;  // t6 = Y⁴ = (Y²)²
    localparam DBL_8YYYY     = 6'd12;  // t6 = 8 * Y⁴
    localparam DBL_SMX       = 6'd13;  // t7 = S - X'
    localparam DBL_MSMX      = 6'd14;  // t7 = M * (S - X')
    localparam DBL_Y3        = 6'd15;  // Y' = M*(S-X') - 8Y⁴
    localparam DBL_2Y        = 6'd16;  // t8 = 2*Y
    localparam DBL_Z3        = 6'd17;  // Z' = 2*Y*Z
    // Point addition states (mixed: P1 Jacobian, P2 affine)
    localparam ADD_Z1Z1      = 6'd20;  // t1 = Z1²
    localparam ADD_Z1Z1Z1    = 6'd21;  // t2 = Z1³
    localparam ADD_U2        = 6'd22;  // U2 = X2 * Z1²
    localparam ADD_S2        = 6'd23;  // S2 = Y2 * Z1³
    localparam ADD_H         = 6'd24;  // H = U2 - X1
    localparam ADD_R         = 6'd25;  // R = S2 - Y1
    localparam ADD_HH        = 6'd26;  // t3 = H²
    localparam ADD_HHH       = 6'd27;  // t4 = H³
    localparam ADD_X1HH      = 6'd28;  // t5 = X1 * H²
    localparam ADD_2X1HH     = 6'd29;  // t6 = 2 * X1 * H²
    localparam ADD_RR        = 6'd30;  // t7 = R²
    localparam ADD_X3_1      = 6'd31;  // t7 = R² - H³
    localparam ADD_X3_2      = 6'd32;  // X3 = R² - H³ - 2*X1*H²
    localparam ADD_DX        = 6'd33;  // t8 = X1*H² - X3
    localparam ADD_RDX       = 6'd34;  // t8 = R * (X1*H² - X3)
    localparam ADD_Y1HHH     = 6'd35;  // t9 = Y1 * H³
    localparam ADD_Y3        = 6'd36;  // Y3 = R*(X1*H² - X3) - Y1*H³
    localparam ADD_Z3        = 6'd37;  // Z3 = Z1 * H
    localparam DONE_STATE    = 6'd63;

    // Current operation
    reg [1:0] curr_op;

    // Temporary registers for intermediate values
    reg [255:0] t1, t2, t3, t4, t5, t6, t7, t8, t9;
    reg [255:0] m_reg, s_reg, h_reg, r_reg;

    // ALU interface
    reg         alu_start;
    reg  [1:0]  alu_op;
    reg  [255:0] alu_a, alu_b;
    wire [255:0] alu_result;
    wire        alu_done;

    // Instantiate shared ALU
    secp256k1_alu u_alu (
        .clk(clk),
        .rst_n(rst_n),
        .start(alu_start),
        .op(alu_op),
        .a(alu_a),
        .b(alu_b),
        .result(alu_result),
        .done(alu_done)
    );

    // Wait flag
    reg wait_alu;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            x3 <= 256'd0;
            y3 <= 256'd0;
            z3 <= 256'd0;
            done <= 1'b0;
            state <= IDLE;
            curr_op <= 2'd0;
            alu_start <= 1'b0;
            wait_alu <= 1'b0;
            t1 <= 256'd0; t2 <= 256'd0; t3 <= 256'd0;
            t4 <= 256'd0; t5 <= 256'd0; t6 <= 256'd0;
            t7 <= 256'd0; t8 <= 256'd0; t9 <= 256'd0;
            m_reg <= 256'd0; s_reg <= 256'd0;
            h_reg <= 256'd0; r_reg <= 256'd0;
        end else begin
            // Default
            alu_start <= 1'b0;

            case (state)
                IDLE: begin
                    done <= 1'b0;
                    if (start) begin
                        curr_op <= op;
                        state <= LOAD;
                    end
                end

                LOAD: begin
                    case (curr_op)
                        OP_DOUBLE: state <= DBL_YY;
                        OP_ADD: state <= ADD_Z1Z1;
                        default: state <= DONE_STATE;
                    endcase
                end

                //==============================================================
                // POINT DOUBLING (secp256k1 a=0 optimization)
                //==============================================================

                DBL_YY: begin  // t1 = Y²
                    if (!wait_alu) begin
                        alu_a <= y1;
                        alu_b <= y1;
                        alu_op <= ALU_MUL;
                        alu_start <= 1'b1;
                        wait_alu <= 1'b1;
                    end else if (alu_done) begin
                        t1 <= alu_result;  // Y²
                        wait_alu <= 1'b0;
                        state <= DBL_XX;
                    end
                end

                DBL_XX: begin  // t2 = X²
                    if (!wait_alu) begin
                        alu_a <= x1;
                        alu_b <= x1;
                        alu_op <= ALU_MUL;
                        alu_start <= 1'b1;
                        wait_alu <= 1'b1;
                    end else if (alu_done) begin
                        t2 <= alu_result;  // X²
                        wait_alu <= 1'b0;
                        state <= DBL_XYY;
                    end
                end

                DBL_XYY: begin  // t3 = X * Y²
                    if (!wait_alu) begin
                        alu_a <= x1;
                        alu_b <= t1;
                        alu_op <= ALU_MUL;
                        alu_start <= 1'b1;
                        wait_alu <= 1'b1;
                    end else if (alu_done) begin
                        t3 <= alu_result;
                        wait_alu <= 1'b0;
                        state <= DBL_S2;
                    end
                end

                DBL_S2: begin  // t3 = 2 * X * Y²
                    if (!wait_alu) begin
                        alu_a <= t3;
                        alu_b <= t3;
                        alu_op <= ALU_ADD;
                        alu_start <= 1'b1;
                        wait_alu <= 1'b1;
                    end else if (alu_done) begin
                        t3 <= alu_result;
                        wait_alu <= 1'b0;
                        state <= DBL_S4;
                    end
                end

                DBL_S4: begin  // S = 4 * X * Y²
                    if (!wait_alu) begin
                        alu_a <= t3;
                        alu_b <= t3;
                        alu_op <= ALU_ADD;
                        alu_start <= 1'b1;
                        wait_alu <= 1'b1;
                    end else if (alu_done) begin
                        s_reg <= alu_result;  // S
                        wait_alu <= 1'b0;
                        state <= DBL_3XX;
                    end
                end

                DBL_3XX: begin  // M = 3 * X² (first compute 2*X²)
                    if (!wait_alu) begin
                        alu_a <= t2;
                        alu_b <= t2;
                        alu_op <= ALU_ADD;
                        alu_start <= 1'b1;
                        wait_alu <= 1'b1;
                    end else if (alu_done) begin
                        t4 <= alu_result;  // 2*X²
                        wait_alu <= 1'b0;
                        // Now add X² to get 3*X²
                        alu_a <= alu_result;
                        alu_b <= t2;
                        alu_op <= ALU_ADD;
                        alu_start <= 1'b1;
                        wait_alu <= 1'b1;
                        state <= DBL_MM;
                    end
                end

                DBL_MM: begin  // Wait for 3*X², then compute M²
                    if (wait_alu && alu_done) begin
                        m_reg <= alu_result;  // M = 3*X²
                        wait_alu <= 1'b0;
                    end else if (!wait_alu) begin
                        alu_a <= m_reg;
                        alu_b <= m_reg;
                        alu_op <= ALU_MUL;
                        alu_start <= 1'b1;
                        wait_alu <= 1'b1;
                        state <= DBL_2S;
                    end
                end

                DBL_2S: begin  // Wait for M², compute 2*S
                    if (wait_alu && alu_done) begin
                        t4 <= alu_result;  // M²
                        wait_alu <= 1'b0;
                        alu_a <= s_reg;
                        alu_b <= s_reg;
                        alu_op <= ALU_ADD;
                        alu_start <= 1'b1;
                        wait_alu <= 1'b1;
                        state <= DBL_X3;
                    end
                end

                DBL_X3: begin  // X' = M² - 2*S
                    if (wait_alu && alu_done) begin
                        t5 <= alu_result;  // 2*S
                        wait_alu <= 1'b0;
                        alu_a <= t4;       // M²
                        alu_b <= alu_result;  // 2*S
                        alu_op <= ALU_SUB;
                        alu_start <= 1'b1;
                        wait_alu <= 1'b1;
                        state <= DBL_YYYY;
                    end
                end

                DBL_YYYY: begin  // Store X', compute Y⁴
                    if (wait_alu && alu_done) begin
                        x3 <= alu_result;  // X'
                        wait_alu <= 1'b0;
                        alu_a <= t1;  // Y²
                        alu_b <= t1;
                        alu_op <= ALU_MUL;
                        alu_start <= 1'b1;
                        wait_alu <= 1'b1;
                        state <= DBL_8YYYY;
                    end
                end

                DBL_8YYYY: begin  // 8 * Y⁴ (3 doublings)
                    if (wait_alu && alu_done) begin
                        t6 <= alu_result;  // Y⁴
                        wait_alu <= 1'b0;
                        // 2*Y⁴
                        alu_a <= alu_result;
                        alu_b <= alu_result;
                        alu_op <= ALU_ADD;
                        alu_start <= 1'b1;
                        wait_alu <= 1'b1;
                        state <= DBL_SMX;
                    end
                end

                DBL_SMX: begin  // Continue 8*Y⁴ and S - X'
                    if (wait_alu && alu_done) begin
                        if (t6 == alu_result) begin
                            // Still computing 8*Y⁴ (this is 2*Y⁴)
                            t6 <= alu_result;
                            // 4*Y⁴
                            alu_a <= alu_result;
                            alu_b <= alu_result;
                            alu_op <= ALU_ADD;
                            alu_start <= 1'b1;
                        end else if (t6 != 256'd0) begin
                            // 4*Y⁴ done, compute 8*Y⁴
                            alu_a <= alu_result;
                            alu_b <= alu_result;
                            alu_op <= ALU_ADD;
                            alu_start <= 1'b1;
                            t6 <= 256'd0;  // Flag that next is 8*Y⁴
                        end else begin
                            t6 <= alu_result;  // 8*Y⁴
                            wait_alu <= 1'b0;
                            // S - X'
                            alu_a <= s_reg;
                            alu_b <= x3;
                            alu_op <= ALU_SUB;
                            alu_start <= 1'b1;
                            wait_alu <= 1'b1;
                            state <= DBL_MSMX;
                        end
                    end
                end

                DBL_MSMX: begin  // M * (S - X')
                    if (wait_alu && alu_done) begin
                        t7 <= alu_result;  // S - X'
                        wait_alu <= 1'b0;
                        alu_a <= m_reg;
                        alu_b <= alu_result;
                        alu_op <= ALU_MUL;
                        alu_start <= 1'b1;
                        wait_alu <= 1'b1;
                        state <= DBL_Y3;
                    end
                end

                DBL_Y3: begin  // Y' = M*(S-X') - 8*Y⁴
                    if (wait_alu && alu_done) begin
                        t7 <= alu_result;  // M*(S-X')
                        wait_alu <= 1'b0;
                        alu_a <= alu_result;
                        alu_b <= t6;  // 8*Y⁴
                        alu_op <= ALU_SUB;
                        alu_start <= 1'b1;
                        wait_alu <= 1'b1;
                        state <= DBL_2Y;
                    end
                end

                DBL_2Y: begin  // Store Y', compute 2*Y
                    if (wait_alu && alu_done) begin
                        y3 <= alu_result;  // Y'
                        wait_alu <= 1'b0;
                        alu_a <= y1;
                        alu_b <= y1;
                        alu_op <= ALU_ADD;
                        alu_start <= 1'b1;
                        wait_alu <= 1'b1;
                        state <= DBL_Z3;
                    end
                end

                DBL_Z3: begin  // Z' = 2*Y*Z
                    if (wait_alu && alu_done) begin
                        t8 <= alu_result;  // 2*Y
                        wait_alu <= 1'b0;
                        alu_a <= alu_result;
                        alu_b <= z1;
                        alu_op <= ALU_MUL;
                        alu_start <= 1'b1;
                        wait_alu <= 1'b1;
                        state <= DONE_STATE;
                    end
                end

                //==============================================================
                // POINT ADDITION (mixed: P1 Jacobian, P2 affine)
                //==============================================================

                ADD_Z1Z1: begin  // t1 = Z1²
                    if (!wait_alu) begin
                        alu_a <= z1;
                        alu_b <= z1;
                        alu_op <= ALU_MUL;
                        alu_start <= 1'b1;
                        wait_alu <= 1'b1;
                    end else if (alu_done) begin
                        t1 <= alu_result;
                        wait_alu <= 1'b0;
                        state <= ADD_Z1Z1Z1;
                    end
                end

                ADD_Z1Z1Z1: begin  // t2 = Z1³
                    if (!wait_alu) begin
                        alu_a <= t1;
                        alu_b <= z1;
                        alu_op <= ALU_MUL;
                        alu_start <= 1'b1;
                        wait_alu <= 1'b1;
                    end else if (alu_done) begin
                        t2 <= alu_result;
                        wait_alu <= 1'b0;
                        state <= ADD_U2;
                    end
                end

                ADD_U2: begin  // U2 = X2 * Z1²
                    if (!wait_alu) begin
                        alu_a <= x2;
                        alu_b <= t1;
                        alu_op <= ALU_MUL;
                        alu_start <= 1'b1;
                        wait_alu <= 1'b1;
                    end else if (alu_done) begin
                        t3 <= alu_result;  // U2
                        wait_alu <= 1'b0;
                        state <= ADD_S2;
                    end
                end

                ADD_S2: begin  // S2 = Y2 * Z1³
                    if (!wait_alu) begin
                        alu_a <= y2;
                        alu_b <= t2;
                        alu_op <= ALU_MUL;
                        alu_start <= 1'b1;
                        wait_alu <= 1'b1;
                    end else if (alu_done) begin
                        t4 <= alu_result;  // S2
                        wait_alu <= 1'b0;
                        state <= ADD_H;
                    end
                end

                ADD_H: begin  // H = U2 - X1
                    if (!wait_alu) begin
                        alu_a <= t3;  // U2
                        alu_b <= x1;
                        alu_op <= ALU_SUB;
                        alu_start <= 1'b1;
                        wait_alu <= 1'b1;
                    end else if (alu_done) begin
                        h_reg <= alu_result;  // H
                        wait_alu <= 1'b0;
                        state <= ADD_R;
                    end
                end

                ADD_R: begin  // R = S2 - Y1
                    if (!wait_alu) begin
                        alu_a <= t4;  // S2
                        alu_b <= y1;
                        alu_op <= ALU_SUB;
                        alu_start <= 1'b1;
                        wait_alu <= 1'b1;
                    end else if (alu_done) begin
                        r_reg <= alu_result;  // R
                        wait_alu <= 1'b0;
                        state <= ADD_HH;
                    end
                end

                ADD_HH: begin  // t5 = H²
                    if (!wait_alu) begin
                        alu_a <= h_reg;
                        alu_b <= h_reg;
                        alu_op <= ALU_MUL;
                        alu_start <= 1'b1;
                        wait_alu <= 1'b1;
                    end else if (alu_done) begin
                        t5 <= alu_result;  // H²
                        wait_alu <= 1'b0;
                        state <= ADD_HHH;
                    end
                end

                ADD_HHH: begin  // t6 = H³
                    if (!wait_alu) begin
                        alu_a <= t5;
                        alu_b <= h_reg;
                        alu_op <= ALU_MUL;
                        alu_start <= 1'b1;
                        wait_alu <= 1'b1;
                    end else if (alu_done) begin
                        t6 <= alu_result;  // H³
                        wait_alu <= 1'b0;
                        state <= ADD_X1HH;
                    end
                end

                ADD_X1HH: begin  // t7 = X1 * H²
                    if (!wait_alu) begin
                        alu_a <= x1;
                        alu_b <= t5;
                        alu_op <= ALU_MUL;
                        alu_start <= 1'b1;
                        wait_alu <= 1'b1;
                    end else if (alu_done) begin
                        t7 <= alu_result;  // X1*H²
                        wait_alu <= 1'b0;
                        state <= ADD_2X1HH;
                    end
                end

                ADD_2X1HH: begin  // t8 = 2 * X1 * H²
                    if (!wait_alu) begin
                        alu_a <= t7;
                        alu_b <= t7;
                        alu_op <= ALU_ADD;
                        alu_start <= 1'b1;
                        wait_alu <= 1'b1;
                    end else if (alu_done) begin
                        t8 <= alu_result;  // 2*X1*H²
                        wait_alu <= 1'b0;
                        state <= ADD_RR;
                    end
                end

                ADD_RR: begin  // t9 = R²
                    if (!wait_alu) begin
                        alu_a <= r_reg;
                        alu_b <= r_reg;
                        alu_op <= ALU_MUL;
                        alu_start <= 1'b1;
                        wait_alu <= 1'b1;
                    end else if (alu_done) begin
                        t9 <= alu_result;  // R²
                        wait_alu <= 1'b0;
                        state <= ADD_X3_1;
                    end
                end

                ADD_X3_1: begin  // R² - H³
                    if (!wait_alu) begin
                        alu_a <= t9;
                        alu_b <= t6;
                        alu_op <= ALU_SUB;
                        alu_start <= 1'b1;
                        wait_alu <= 1'b1;
                    end else if (alu_done) begin
                        t9 <= alu_result;
                        wait_alu <= 1'b0;
                        state <= ADD_X3_2;
                    end
                end

                ADD_X3_2: begin  // X3 = R² - H³ - 2*X1*H²
                    if (!wait_alu) begin
                        alu_a <= t9;
                        alu_b <= t8;
                        alu_op <= ALU_SUB;
                        alu_start <= 1'b1;
                        wait_alu <= 1'b1;
                    end else if (alu_done) begin
                        x3 <= alu_result;  // X3
                        wait_alu <= 1'b0;
                        state <= ADD_DX;
                    end
                end

                ADD_DX: begin  // X1*H² - X3
                    if (!wait_alu) begin
                        alu_a <= t7;
                        alu_b <= x3;
                        alu_op <= ALU_SUB;
                        alu_start <= 1'b1;
                        wait_alu <= 1'b1;
                    end else if (alu_done) begin
                        t9 <= alu_result;
                        wait_alu <= 1'b0;
                        state <= ADD_RDX;
                    end
                end

                ADD_RDX: begin  // R * (X1*H² - X3)
                    if (!wait_alu) begin
                        alu_a <= r_reg;
                        alu_b <= t9;
                        alu_op <= ALU_MUL;
                        alu_start <= 1'b1;
                        wait_alu <= 1'b1;
                    end else if (alu_done) begin
                        t9 <= alu_result;
                        wait_alu <= 1'b0;
                        state <= ADD_Y1HHH;
                    end
                end

                ADD_Y1HHH: begin  // Y1 * H³
                    if (!wait_alu) begin
                        alu_a <= y1;
                        alu_b <= t6;
                        alu_op <= ALU_MUL;
                        alu_start <= 1'b1;
                        wait_alu <= 1'b1;
                    end else if (alu_done) begin
                        t6 <= alu_result;  // Y1*H³
                        wait_alu <= 1'b0;
                        state <= ADD_Y3;
                    end
                end

                ADD_Y3: begin  // Y3 = R*(X1*H² - X3) - Y1*H³
                    if (!wait_alu) begin
                        alu_a <= t9;
                        alu_b <= t6;
                        alu_op <= ALU_SUB;
                        alu_start <= 1'b1;
                        wait_alu <= 1'b1;
                    end else if (alu_done) begin
                        y3 <= alu_result;  // Y3
                        wait_alu <= 1'b0;
                        state <= ADD_Z3;
                    end
                end

                ADD_Z3: begin  // Z3 = Z1 * H
                    if (!wait_alu) begin
                        alu_a <= z1;
                        alu_b <= h_reg;
                        alu_op <= ALU_MUL;
                        alu_start <= 1'b1;
                        wait_alu <= 1'b1;
                    end else if (alu_done) begin
                        z3 <= alu_result;  // Z3
                        wait_alu <= 1'b0;
                        state <= DONE_STATE;
                    end
                end

                DONE_STATE: begin
                    if (wait_alu && alu_done) begin
                        z3 <= alu_result;  // For DBL_Z3
                        wait_alu <= 1'b0;
                    end
                    done <= 1'b1;
                    state <= IDLE;
                end

                default: state <= IDLE;
            endcase
        end
    end

endmodule
