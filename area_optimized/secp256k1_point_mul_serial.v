//-----------------------------------------------------------------------------
// secp256k1_point_mul_serial.v
// Area-optimized scalar point multiplication for secp256k1
// Uses wNAF with shared ALU - trades cycles for LUTs
// Estimated: ~200K cycles for full multiplication, ~1/5 LUTs
//-----------------------------------------------------------------------------

module secp256k1_point_mul_serial #(
    parameter W = 4  // Window size (4 for area, 8 for speed)
) (
    input  wire         clk,
    input  wire         rst_n,
    input  wire         start,
    input  wire [255:0] k,           // Scalar multiplier
    input  wire [255:0] px,          // Base point X (affine)
    input  wire [255:0] py,          // Base point Y (affine)
    input  wire         use_g,       // 1 = use generator G
    output reg  [255:0] qx,          // Result X (affine)
    output reg  [255:0] qy,          // Result Y (affine)
    output reg          done,
    output reg          point_at_inf
);

    // secp256k1 generator point G
    localparam [255:0] GX = 256'h79BE667EF9DCBBAC55A06295CE870B07029BFCDB2DCE28D959F2815B16F81798;
    localparam [255:0] GY = 256'h483ADA7726A3C4655DA4FBFC0E1108A8FD17B448A68554199C47D08FFB10D4B8;
    localparam [255:0] SECP256K1_P = 256'hFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEFFFFFC2F;

    // Number of precomputed points
    localparam NUM_POINTS = (1 << (W-1));

    // Point operations
    localparam POP_DOUBLE = 2'b00;
    localparam POP_ADD    = 2'b01;

    // ALU operations
    localparam ALU_ADD = 2'b00;
    localparam ALU_SUB = 2'b01;
    localparam ALU_MUL = 2'b10;

    // Main state machine
    reg [5:0] state;
    localparam IDLE           = 6'd0;
    localparam INIT           = 6'd1;
    localparam NAF_CONVERT    = 6'd2;
    localparam PRECOMP_INIT   = 6'd3;
    localparam PRECOMP_2P     = 6'd4;
    localparam PRECOMP_NEXT   = 6'd5;
    localparam PRECOMP_TO_AFF = 6'd6;
    localparam FIND_MSB       = 6'd7;
    localparam INIT_RESULT    = 6'd8;
    localparam LOOP_DOUBLE    = 6'd9;
    localparam WAIT_DOUBLE    = 6'd10;
    localparam CHECK_DIGIT    = 6'd11;
    localparam DO_ADD         = 6'd12;
    localparam WAIT_ADD       = 6'd13;
    localparam NEXT_BIT       = 6'd14;
    localparam TO_AFFINE      = 6'd15;
    localparam INV_Z          = 6'd16;
    localparam CALC_Z2        = 6'd17;
    localparam CALC_QX        = 6'd18;
    localparam CALC_Z3        = 6'd19;
    localparam CALC_QY        = 6'd20;
    localparam DONE_STATE     = 6'd63;

    // Base point
    reg [255:0] bx, by;

    // Precomputed points table (affine)
    reg [255:0] table_x [0:NUM_POINTS-1];
    reg [255:0] table_y [0:NUM_POINTS-1];
    reg [3:0]   table_idx;

    // NAF representation
    reg [263:0] naf_data;  // 33 x 8-bit digits
    reg [8:0]   naf_len;
    reg [8:0]   bit_pos;

    // NAF conversion working registers
    reg [264:0] naf_k;

    // Current digit
    reg signed [7:0] curr_digit;

    // Result accumulator (Jacobian)
    reg [255:0] rx, ry, rz;
    reg         r_is_inf;

    // Point for addition
    reg [255:0] add_x, add_y;

    // 2P for precomputation
    reg [255:0] p2_x, p2_y, p2_z;

    // Temporary point (Jacobian) for precomputation
    reg [255:0] temp_x, temp_y, temp_z;

    // Point operations interface
    reg         pop_start;
    reg  [1:0]  pop_op;
    reg  [255:0] pop_x1, pop_y1, pop_z1, pop_x2, pop_y2;
    wire [255:0] pop_x3, pop_y3, pop_z3;
    wire        pop_done;

    // ALU interface
    reg         alu_start;
    reg  [1:0]  alu_op;
    reg  [255:0] alu_a, alu_b;
    wire [255:0] alu_result;
    wire        alu_done;

    // Instantiate shared ALU
    secp256k1_alu u_alu (
        .clk(clk), .rst_n(rst_n),
        .start(alu_start), .op(alu_op),
        .a(alu_a), .b(alu_b),
        .result(alu_result), .done(alu_done)
    );

    // Instantiate point operations (uses its own ALU instance)
    secp256k1_point_ops_serial u_pop (
        .clk(clk), .rst_n(rst_n),
        .start(pop_start), .op(pop_op),
        .x1(pop_x1), .y1(pop_y1), .z1(pop_z1),
        .x2(pop_x2), .y2(pop_y2),
        .x3(pop_x3), .y3(pop_y3), .z3(pop_z3),
        .done(pop_done)
    );

    // Inversion module
    reg         inv_start;
    reg  [255:0] inv_in;
    wire [255:0] inv_result;
    wire        inv_done;

    secp256k1_inv_mod_serial u_inv (
        .clk(clk), .rst_n(rst_n),
        .start(inv_start), .a(inv_in),
        .result(inv_result), .done(inv_done)
    );

    // Wait flags
    reg wait_pop, wait_alu, wait_inv;

    // Temporaries for affine conversion
    reg [255:0] z_inv, z2, z3;

    // Affine conversion state
    reg [2:0] aff_step;

    integer i;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            qx <= 256'd0;
            qy <= 256'd0;
            done <= 1'b0;
            point_at_inf <= 1'b0;
            state <= IDLE;

            bx <= 256'd0;
            by <= 256'd0;
            naf_data <= 264'd0;
            naf_len <= 9'd0;
            naf_k <= 265'd0;
            bit_pos <= 9'd0;
            curr_digit <= 8'd0;

            rx <= 256'd0;
            ry <= 256'd0;
            rz <= 256'd0;
            r_is_inf <= 1'b1;

            add_x <= 256'd0;
            add_y <= 256'd0;

            table_idx <= 4'd0;
            p2_x <= 256'd0;
            p2_y <= 256'd0;
            p2_z <= 256'd0;
            temp_x <= 256'd0;
            temp_y <= 256'd0;
            temp_z <= 256'd0;

            pop_start <= 1'b0;
            alu_start <= 1'b0;
            inv_start <= 1'b0;
            wait_pop <= 1'b0;
            wait_alu <= 1'b0;
            wait_inv <= 1'b0;

            z_inv <= 256'd0;
            z2 <= 256'd0;
            z3 <= 256'd0;
            aff_step <= 3'd0;

            for (i = 0; i < NUM_POINTS; i = i + 1) begin
                table_x[i] <= 256'd0;
                table_y[i] <= 256'd0;
            end
        end else begin
            // Default
            pop_start <= 1'b0;
            alu_start <= 1'b0;
            inv_start <= 1'b0;

            case (state)
                IDLE: begin
                    done <= 1'b0;
                    point_at_inf <= 1'b0;
                    if (start) begin
                        // Select base point
                        bx <= use_g ? GX : px;
                        by <= use_g ? GY : py;

                        if (k == 256'd0) begin
                            point_at_inf <= 1'b1;
                            qx <= 256'd0;
                            qy <= 256'd0;
                            state <= DONE_STATE;
                        end else begin
                            state <= INIT;
                        end
                    end
                end

                INIT: begin
                    // Initialize for NAF conversion
                    naf_k <= {9'd0, k};
                    naf_data <= 264'd0;
                    bit_pos <= 9'd0;
                    state <= NAF_CONVERT;
                end

                //==============================================================
                // NAF CONVERSION (inline, serial)
                //==============================================================
                NAF_CONVERT: begin
                    if (naf_k == 265'd0) begin
                        naf_len <= bit_pos;
                        // Start precomputation
                        table_idx <= 4'd0;
                        state <= PRECOMP_INIT;
                    end else if (naf_k[0]) begin
                        // k is odd, extract digit
                        if (naf_k[W-1:0] >= (1 << (W-1))) begin
                            // Negative digit
                            naf_data[bit_pos*8 +: 8] <= naf_k[W-1:0] - (1 << W);
                            naf_k <= (naf_k + ((1 << W) - naf_k[W-1:0])) >> 1;
                        end else begin
                            // Positive digit
                            naf_data[bit_pos*8 +: 8] <= naf_k[W-1:0];
                            naf_k <= (naf_k - naf_k[W-1:0]) >> 1;
                        end
                        bit_pos <= bit_pos + 1'b1;
                    end else begin
                        // k is even
                        naf_data[bit_pos*8 +: 8] <= 8'd0;
                        naf_k <= naf_k >> 1;
                        bit_pos <= bit_pos + 1'b1;
                    end
                end

                //==============================================================
                // PRECOMPUTATION: Build table of 1P, 3P, 5P, ...
                //==============================================================
                PRECOMP_INIT: begin
                    // Store 1P (index 0)
                    table_x[0] <= bx;
                    table_y[0] <= by;

                    if (NUM_POINTS == 1) begin
                        state <= FIND_MSB;
                    end else begin
                        // Compute 2P
                        pop_x1 <= bx;
                        pop_y1 <= by;
                        pop_z1 <= 256'd1;
                        pop_op <= POP_DOUBLE;
                        pop_start <= 1'b1;
                        wait_pop <= 1'b1;
                        state <= PRECOMP_2P;
                    end
                end

                PRECOMP_2P: begin
                    if (wait_pop && pop_done) begin
                        p2_x <= pop_x3;
                        p2_y <= pop_y3;
                        p2_z <= pop_z3;
                        wait_pop <= 1'b0;

                        // Convert 2P to affine for table additions
                        inv_in <= pop_z3;
                        inv_start <= 1'b1;
                        wait_inv <= 1'b1;
                        aff_step <= 3'd0;
                        state <= PRECOMP_TO_AFF;
                    end
                end

                PRECOMP_TO_AFF: begin
                    if (wait_inv && inv_done) begin
                        z_inv <= inv_result;
                        wait_inv <= 1'b0;
                        // z²
                        alu_a <= inv_result;
                        alu_b <= inv_result;
                        alu_op <= ALU_MUL;
                        alu_start <= 1'b1;
                        wait_alu <= 1'b1;
                        aff_step <= 3'd1;
                    end else if (wait_alu && alu_done) begin
                        wait_alu <= 1'b0;
                        case (aff_step)
                            3'd1: begin  // z² done
                                z2 <= alu_result;
                                alu_a <= p2_x;
                                alu_b <= alu_result;
                                alu_op <= ALU_MUL;
                                alu_start <= 1'b1;
                                wait_alu <= 1'b1;
                                aff_step <= 3'd2;
                            end
                            3'd2: begin  // x_aff done
                                p2_x <= alu_result;  // Store affine X of 2P
                                alu_a <= z2;
                                alu_b <= z_inv;
                                alu_op <= ALU_MUL;
                                alu_start <= 1'b1;
                                wait_alu <= 1'b1;
                                aff_step <= 3'd3;
                            end
                            3'd3: begin  // z³ done
                                z3 <= alu_result;
                                alu_a <= p2_y;
                                alu_b <= alu_result;
                                alu_op <= ALU_MUL;
                                alu_start <= 1'b1;
                                wait_alu <= 1'b1;
                                aff_step <= 3'd4;
                            end
                            3'd4: begin  // y_aff done
                                p2_y <= alu_result;  // Store affine Y of 2P
                                // Now compute 3P = P + 2P
                                table_idx <= 4'd1;
                                temp_x <= bx;
                                temp_y <= by;
                                temp_z <= 256'd1;
                                state <= PRECOMP_NEXT;
                            end
                        endcase
                    end
                end

                PRECOMP_NEXT: begin
                    // Compute (2i+1)P = (2i-1)P + 2P
                    if (!wait_pop) begin
                        pop_x1 <= temp_x;
                        pop_y1 <= temp_y;
                        pop_z1 <= temp_z;
                        pop_x2 <= p2_x;
                        pop_y2 <= p2_y;
                        pop_op <= POP_ADD;
                        pop_start <= 1'b1;
                        wait_pop <= 1'b1;
                    end else if (pop_done) begin
                        temp_x <= pop_x3;
                        temp_y <= pop_y3;
                        temp_z <= pop_z3;
                        wait_pop <= 1'b0;

                        // Convert to affine and store
                        inv_in <= pop_z3;
                        inv_start <= 1'b1;
                        wait_inv <= 1'b1;
                        aff_step <= 3'd0;
                        // Reuse conversion logic
                        p2_x <= pop_x3;  // Temporarily store for conversion
                        p2_y <= pop_y3;
                        state <= 6'd25;  // PRECOMP_STORE_AFF
                    end
                end

                6'd25: begin  // PRECOMP_STORE_AFF
                    if (wait_inv && inv_done) begin
                        z_inv <= inv_result;
                        wait_inv <= 1'b0;
                        alu_a <= inv_result;
                        alu_b <= inv_result;
                        alu_op <= ALU_MUL;
                        alu_start <= 1'b1;
                        wait_alu <= 1'b1;
                        aff_step <= 3'd1;
                    end else if (wait_alu && alu_done) begin
                        wait_alu <= 1'b0;
                        case (aff_step)
                            3'd1: begin
                                z2 <= alu_result;
                                alu_a <= temp_x;
                                alu_b <= alu_result;
                                alu_op <= ALU_MUL;
                                alu_start <= 1'b1;
                                wait_alu <= 1'b1;
                                aff_step <= 3'd2;
                            end
                            3'd2: begin
                                table_x[table_idx] <= alu_result;
                                alu_a <= z2;
                                alu_b <= z_inv;
                                alu_op <= ALU_MUL;
                                alu_start <= 1'b1;
                                wait_alu <= 1'b1;
                                aff_step <= 3'd3;
                            end
                            3'd3: begin
                                z3 <= alu_result;
                                alu_a <= temp_y;
                                alu_b <= alu_result;
                                alu_op <= ALU_MUL;
                                alu_start <= 1'b1;
                                wait_alu <= 1'b1;
                                aff_step <= 3'd4;
                            end
                            3'd4: begin
                                table_y[table_idx] <= alu_result;
                                table_idx <= table_idx + 1'b1;

                                if (table_idx >= NUM_POINTS - 1) begin
                                    // Precomputation done
                                    state <= FIND_MSB;
                                end else begin
                                    // Next point
                                    state <= PRECOMP_NEXT;
                                end
                            end
                        endcase
                    end
                end

                //==============================================================
                // MAIN MULTIPLICATION LOOP
                //==============================================================
                FIND_MSB: begin
                    if (naf_len == 9'd0) begin
                        point_at_inf <= 1'b1;
                        state <= DONE_STATE;
                    end else begin
                        bit_pos <= naf_len - 1'b1;
                        r_is_inf <= 1'b1;
                        state <= CHECK_DIGIT;
                    end
                end

                INIT_RESULT: begin
                    // Initialize R with first non-zero point
                    if (curr_digit > 0) begin
                        rx <= table_x[(curr_digit - 1) >> 1];
                        ry <= table_y[(curr_digit - 1) >> 1];
                        rz <= 256'd1;
                    end else begin
                        rx <= table_x[(-curr_digit - 1) >> 1];
                        ry <= SECP256K1_P - table_y[(-curr_digit - 1) >> 1];
                        rz <= 256'd1;
                    end
                    r_is_inf <= 1'b0;
                    state <= NEXT_BIT;
                end

                LOOP_DOUBLE: begin
                    if (!r_is_inf && !wait_pop) begin
                        pop_x1 <= rx;
                        pop_y1 <= ry;
                        pop_z1 <= rz;
                        pop_op <= POP_DOUBLE;
                        pop_start <= 1'b1;
                        wait_pop <= 1'b1;
                        state <= WAIT_DOUBLE;
                    end else if (r_is_inf) begin
                        state <= CHECK_DIGIT;
                    end
                end

                WAIT_DOUBLE: begin
                    if (wait_pop && pop_done) begin
                        rx <= pop_x3;
                        ry <= pop_y3;
                        rz <= pop_z3;
                        wait_pop <= 1'b0;
                        state <= CHECK_DIGIT;
                    end
                end

                CHECK_DIGIT: begin
                    curr_digit <= naf_data[bit_pos*8 +: 8];

                    if (naf_data[bit_pos*8 +: 8] == 8'd0) begin
                        state <= NEXT_BIT;
                    end else if (r_is_inf) begin
                        state <= INIT_RESULT;
                    end else begin
                        // Prepare point for addition
                        if ($signed(naf_data[bit_pos*8 +: 8]) > 0) begin
                            add_x <= table_x[(naf_data[bit_pos*8 +: 8] - 1) >> 1];
                            add_y <= table_y[(naf_data[bit_pos*8 +: 8] - 1) >> 1];
                        end else begin
                            add_x <= table_x[(-$signed(naf_data[bit_pos*8 +: 8]) - 1) >> 1];
                            add_y <= SECP256K1_P - table_y[(-$signed(naf_data[bit_pos*8 +: 8]) - 1) >> 1];
                        end
                        state <= DO_ADD;
                    end
                end

                DO_ADD: begin
                    if (!wait_pop) begin
                        pop_x1 <= rx;
                        pop_y1 <= ry;
                        pop_z1 <= rz;
                        pop_x2 <= add_x;
                        pop_y2 <= add_y;
                        pop_op <= POP_ADD;
                        pop_start <= 1'b1;
                        wait_pop <= 1'b1;
                        state <= WAIT_ADD;
                    end
                end

                WAIT_ADD: begin
                    if (wait_pop && pop_done) begin
                        rx <= pop_x3;
                        ry <= pop_y3;
                        rz <= pop_z3;
                        wait_pop <= 1'b0;
                        state <= NEXT_BIT;
                    end
                end

                NEXT_BIT: begin
                    if (bit_pos == 9'd0) begin
                        if (r_is_inf) begin
                            point_at_inf <= 1'b1;
                            qx <= 256'd0;
                            qy <= 256'd0;
                            state <= DONE_STATE;
                        end else begin
                            state <= TO_AFFINE;
                        end
                    end else begin
                        bit_pos <= bit_pos - 1'b1;
                        state <= LOOP_DOUBLE;
                    end
                end

                //==============================================================
                // CONVERT RESULT TO AFFINE
                //==============================================================
                TO_AFFINE: begin
                    if (rz == 256'd0) begin
                        point_at_inf <= 1'b1;
                        qx <= 256'd0;
                        qy <= 256'd0;
                        state <= DONE_STATE;
                    end else begin
                        inv_in <= rz;
                        inv_start <= 1'b1;
                        wait_inv <= 1'b1;
                        state <= INV_Z;
                    end
                end

                INV_Z: begin
                    if (wait_inv && inv_done) begin
                        z_inv <= inv_result;
                        wait_inv <= 1'b0;
                        alu_a <= inv_result;
                        alu_b <= inv_result;
                        alu_op <= ALU_MUL;
                        alu_start <= 1'b1;
                        wait_alu <= 1'b1;
                        state <= CALC_Z2;
                    end
                end

                CALC_Z2: begin
                    if (wait_alu && alu_done) begin
                        z2 <= alu_result;
                        wait_alu <= 1'b0;
                        alu_a <= rx;
                        alu_b <= alu_result;
                        alu_op <= ALU_MUL;
                        alu_start <= 1'b1;
                        wait_alu <= 1'b1;
                        state <= CALC_QX;
                    end
                end

                CALC_QX: begin
                    if (wait_alu && alu_done) begin
                        qx <= alu_result;
                        wait_alu <= 1'b0;
                        alu_a <= z2;
                        alu_b <= z_inv;
                        alu_op <= ALU_MUL;
                        alu_start <= 1'b1;
                        wait_alu <= 1'b1;
                        state <= CALC_Z3;
                    end
                end

                CALC_Z3: begin
                    if (wait_alu && alu_done) begin
                        z3 <= alu_result;
                        wait_alu <= 1'b0;
                        alu_a <= ry;
                        alu_b <= alu_result;
                        alu_op <= ALU_MUL;
                        alu_start <= 1'b1;
                        wait_alu <= 1'b1;
                        state <= CALC_QY;
                    end
                end

                CALC_QY: begin
                    if (wait_alu && alu_done) begin
                        qy <= alu_result;
                        wait_alu <= 1'b0;
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
