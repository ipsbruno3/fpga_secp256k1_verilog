
//-----------------------------------------------------------------------------
// secp256k1_point_mul_wnaf.v
// Scalar point multiplication using windowed NAF (wNAF) algorithm
// Window size: 8 bits (digits in range [-127, 127])
//
// Algorithm:
// 1. Convert scalar k to wNAF representation
// 2. Precompute table: P, 3P, 5P, ..., 255P (128 points for w=8)
// 3. Scan wNAF from MSB to LSB:
//    - Double the accumulator
//    - If digit != 0: add/subtract precomputed point
// 4. Convert result to affine coordinates
//-----------------------------------------------------------------------------

module secp256k1_point_mul_wnaf #(
    parameter W = 8  // Window size (8 for production, 4 for testing)
) (
    input  wire         clk,
    input  wire         rst_n,
    input  wire         start,
    input  wire [255:0] k,           // Scalar multiplier
    input  wire [255:0] px,          // Base point X (affine)
    input  wire [255:0] py,          // Base point Y (affine)
    input  wire         use_g,       // 1 = use generator G, 0 = use (px, py)
    output reg  [255:0] qx,          // Result X (affine)
    output reg  [255:0] qy,          // Result Y (affine)
    output reg          done,
    output reg          point_at_inf // Result is point at infinity
);

    // secp256k1 generator point G
    localparam [255:0] GX = 256'h79BE667EF9DCBBAC55A06295CE870B07029BFCDB2DCE28D959F2815B16F81798;
    localparam [255:0] GY = 256'h483ADA7726A3C4655DA4FBFC0E1108A8FD17B448A68554199C47D08FFB10D4B8;
    localparam [255:0] SECP256K1_P = 256'hFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEFFFFFC2F;

    // Number of precomputed points: 2^(w-1)
    localparam NUM_POINTS = (1 << (W-1));
    // NAF max length
    localparam NAF_LEN = 264;  // 256 + w

    // State machine
    reg [4:0] state;
    localparam IDLE           = 5'd0;
    localparam INIT           = 5'd1;
    localparam CONVERT_NAF    = 5'd2;
    localparam WAIT_NAF       = 5'd3;
    localparam PRECOMPUTE     = 5'd4;
    localparam WAIT_PRECOMP   = 5'd5;
    localparam FIND_MSB       = 5'd6;
    localparam INIT_ACCUM     = 5'd7;
    localparam DOUBLE         = 5'd8;
    localparam WAIT_DOUBLE    = 5'd9;
    localparam CHECK_DIGIT    = 5'd10;
    localparam ADD_POINT      = 5'd11;
    localparam WAIT_ADD       = 5'd12;
    localparam SUB_POINT      = 5'd13;
    localparam WAIT_SUB       = 5'd14;
    localparam NEXT_DIGIT     = 5'd15;
    localparam TO_AFFINE      = 5'd16;
    localparam WAIT_INV       = 5'd17;
    localparam CALC_Z2        = 5'd18;
    localparam CALC_QX        = 5'd19;
    localparam CALC_Z3        = 5'd20;
    localparam CALC_QY        = 5'd21;
    localparam DONE_STATE     = 5'd22;

    // Working point in Jacobian coordinates
    reg [255:0] rx, ry, rz;  // Result accumulator
    reg         r_is_inf;    // Accumulator is point at infinity

    // Base point
    reg [255:0] bx, by;

    // NAF representation

    reg [8:0]   naf_len;
    reg signed [7:0] curr_digit;
    reg [8:0]   digit_pos;
    reg         found_first;

    // Precomputed points table
    reg [255:0] precomp_x [0:NUM_POINTS-1];
    reg [255:0] precomp_y [0:NUM_POINTS-1];
    reg [6:0]   precomp_idx;
    reg         precomp_done;

    // Point double interface
    reg         dbl_start;
    wire [255:0] dbl_x, dbl_y, dbl_z;
    wire        dbl_done;

    // Point add interface
    reg         add_start;
    reg [255:0] add_px, add_py;
    wire [255:0] add_x, add_y, add_z;
    wire        add_done;

    // Inversion interface
    reg         inv_start;
    wire [255:0] inv_out;
    wire        inv_done;

    // Multiplier interface
    reg         mul_start;
    reg [255:0] mul_a, mul_b;
    wire [255:0] mul_result;
    wire        mul_done;

    // Intermediate values
    reg [255:0] z_inv, z2, z3;

    // Instantiate point operations
    secp256k1_point_double u_double (
        .clk(clk), .rst_n(rst_n), .start(dbl_start),
        .x1(rx), .y1(ry), .z1(rz),
        .x3(dbl_x), .y3(dbl_y), .z3(dbl_z),
        .done(dbl_done)
    );

    secp256k1_point_add u_add (
        .clk(clk), .rst_n(rst_n), .start(add_start),
        .x1(rx), .y1(ry), .z1(rz),
        .x2(add_px), .y2(add_py),
        .x3(add_x), .y3(add_y), .z3(add_z),
        .done(add_done)
    );

    secp256k1_inv_mod u_inv (
        .clk(clk), .rst_n(rst_n), .start(inv_start),
        .a(rz), .result(inv_out), .done(inv_done)
    );

    secp256k1_mul_mod u_mul (
        .clk(clk), .rst_n(rst_n), .start(mul_start),
        .a(mul_a), .b(mul_b), .result(mul_result), .done(mul_done)
    );

    // Wait flags
    reg wait_dbl, wait_add, wait_inv, wait_mul;

    // NAF conversion working registers
    reg [264:0] naf_k;
    reg [8:0]   naf_bit_pos;
    reg [NAF_LEN*8-1:0] naf_data;   // 264 * 8 = 2112 bits (bytes)
    wire signed [7:0] naf_digit = $signed(naf_data[digit_pos*8 +: 8]);


    // Precompute 2P for building table
    reg [255:0] p2_x, p2_y;
    reg         have_2p;

    // Table building state
    reg [3:0]   precomp_state;
    localparam PC_IDLE    = 4'd0;
    localparam PC_STORE_P = 4'd1;
    localparam PC_CALC_2P = 4'd2;
    localparam PC_WAIT_2P = 4'd3;
    localparam PC_ADD_2P  = 4'd4;
    localparam PC_WAIT_ADD = 4'd5;
    localparam PC_NEXT    = 4'd6;
    localparam PC_DONE    = 4'd7;

    // Second add instance for precomputation
    reg         pc_add_start;
    reg [255:0] pc_x, pc_y, pc_z;
    wire [255:0] pc_add_x, pc_add_y, pc_add_z;
    wire        pc_add_done;

    secp256k1_point_add u_pc_add (
        .clk(clk), .rst_n(rst_n), .start(pc_add_start),
        .x1(pc_x), .y1(pc_y), .z1(pc_z),
        .x2(p2_x), .y2(p2_y),
        .x3(pc_add_x), .y3(pc_add_y), .z3(pc_add_z),
        .done(pc_add_done)
    );

    // Second double for 2P calculation
    reg         pc_dbl_start;
    wire [255:0] pc_dbl_x, pc_dbl_y, pc_dbl_z;
    wire        pc_dbl_done;

    secp256k1_point_double u_pc_double (
        .clk(clk), .rst_n(rst_n), .start(pc_dbl_start),
        .x1(bx), .y1(by), .z1(256'd1),
        .x3(pc_dbl_x), .y3(pc_dbl_y), .z3(pc_dbl_z),
        .done(pc_dbl_done)
    );

    // Conversion from Jacobian to affine for precomputed table
    reg         pc_inv_start;
    reg [255:0] pc_inv_in;
    wire [255:0] pc_inv_out;
    wire        pc_inv_done;

    secp256k1_inv_mod u_pc_inv (
        .clk(clk), .rst_n(rst_n), .start(pc_inv_start),
        .a(pc_inv_in), .result(pc_inv_out), .done(pc_inv_done)
    );

    reg         pc_mul_start;
    reg [255:0] pc_mul_a, pc_mul_b;
    wire [255:0] pc_mul_result;
    wire        pc_mul_done;

    secp256k1_mul_mod u_pc_mul (
        .clk(clk), .rst_n(rst_n), .start(pc_mul_start),
        .a(pc_mul_a), .b(pc_mul_b), .result(pc_mul_result), .done(pc_mul_done)
    );

    reg wait_pc_dbl, wait_pc_add, wait_pc_inv, wait_pc_mul;
    reg [255:0] pc_z_inv, pc_z2, pc_aff_x, pc_aff_y;
    reg [1:0] pc_aff_step;

    // Main state machine
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            qx <= 256'd0;
            qy <= 256'd0;
            done <= 1'b0;
            point_at_inf <= 1'b0;
            state <= IDLE;
            rx <= 256'd0;
            ry <= 256'd0;
            rz <= 256'd0;
            r_is_inf <= 1'b1;
            bx <= 256'd0;
            by <= 256'd0;
            naf_data <= {NAF_LEN{1'b0}};
            naf_len <= 9'd0;
            digit_pos <= 9'd0;
            found_first <= 1'b0;
            precomp_idx <= 7'd0;
            precomp_done <= 1'b0;
            dbl_start <= 1'b0;
            add_start <= 1'b0;
            inv_start <= 1'b0;
            mul_start <= 1'b0;
            wait_dbl <= 1'b0;
            wait_add <= 1'b0;
            wait_inv <= 1'b0;
            wait_mul <= 1'b0;
            naf_k <= 265'd0;
            naf_bit_pos <= 9'd0;
            p2_x <= 256'd0;
            p2_y <= 256'd0;
            have_2p <= 1'b0;
            precomp_state <= PC_IDLE;
            pc_add_start <= 1'b0;
            pc_dbl_start <= 1'b0;
            pc_inv_start <= 1'b0;
            pc_mul_start <= 1'b0;
            wait_pc_dbl <= 1'b0;
            wait_pc_add <= 1'b0;
            wait_pc_inv <= 1'b0;
            wait_pc_mul <= 1'b0;
            pc_aff_step <= 2'd0;
            pc_x <= 256'd0;
            pc_y <= 256'd0;
            pc_z <= 256'd0;
        end else begin
            // Default: clear start signals
            dbl_start <= 1'b0;
            add_start <= 1'b0;
            inv_start <= 1'b0;
            mul_start <= 1'b0;
            pc_add_start <= 1'b0;
            pc_dbl_start <= 1'b0;
            pc_inv_start <= 1'b0;
            pc_mul_start <= 1'b0;

            case (state)
                IDLE: begin
                    done <= 1'b0;
                    point_at_inf <= 1'b0;
                    if (start) begin
                        // Select base point
                        if (use_g) begin
                            bx <= GX;
                            by <= GY;
                        end else begin
                            bx <= px;
                            by <= py;
                        end

                        // Check for k = 0
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
                    // Initialize NAF conversion
                    naf_k <= {9'd0, k};
                    naf_bit_pos <= 9'd0;
                    naf_data <= {NAF_LEN{1'b0}};
                    naf_len <= 9'd0;
                    precomp_done <= 1'b0;
                    naf_data <= 'd0;
                    precomp_idx <= 7'd0;
                    have_2p <= 1'b0;
                    precomp_state <= PC_IDLE;
                    state <= CONVERT_NAF;
                end

                // ============ NAF Conversion (inline) ============
                CONVERT_NAF: begin : CONVERT_NAF_BLK
                  reg [8:0]        pow2w;
                  reg [7:0]        halfw;
                  reg [W-1:0]      wnd;
                  reg  [8:0] digit_s;
                  reg [264:0]      k_adj;
                
                  pow2w = (9'd1 << W);        // 16 ou 256
                  halfw = (8'd1 << (W-1));    // 8 ou 128
                
                  if (naf_k == 265'd0) begin
                    naf_len       <= naf_bit_pos;
                    state         <= PRECOMPUTE;
                    precomp_state <= PC_STORE_P;
                
                  end else if (naf_bit_pos >= NAF_LEN) begin
                    naf_len       <= NAF_LEN[8:0];
                    state         <= PRECOMPUTE;
                    precomp_state <= PC_STORE_P;
                
                  end else if (naf_k[0]) begin
                    wnd = naf_k[W-1:0];
                
                    if (wnd >= halfw[W-1:0]) begin
                      digit_s = $signed({1'b0, wnd}) - $signed({1'b0, pow2w}); // ex 255-256=-1
                      naf_data[naf_bit_pos*8 +: 8] <= digit_s[7:0];
                
                      k_adj = naf_k + ( {256'd0, pow2w} - {256'd0, 1'b0, wnd} );
                    end else begin
                      digit_s = $signed({1'b0, wnd});
                      naf_data[naf_bit_pos*8 +: 8] <= digit_s[7:0];
                
                      k_adj = naf_k - {256'd0, 1'b0, wnd};
                    end
                
                    naf_k       <= (k_adj >> 1);
                    naf_bit_pos <= naf_bit_pos + 1'b1;
                
                  end else begin
                    naf_data[naf_bit_pos*8 +: 8] <= 8'sd0;
                    naf_k       <= (naf_k >> 1);
                    naf_bit_pos <= naf_bit_pos + 1'b1;
                  end
                end



                // ============ Precomputation ============
                PRECOMPUTE: begin
                    case (precomp_state)
                        PC_STORE_P: begin
                            // Store 1P at index 0
                            precomp_x[0] <= bx;
                            precomp_y[0] <= by;
                            precomp_idx <= 7'd1;

                            if (NUM_POINTS == 1) begin
                                precomp_done <= 1'b1;
                                state <= FIND_MSB;
                            end else begin
                                // Calculate 2P
                                pc_dbl_start <= 1'b1;
                                wait_pc_dbl <= 1'b1;
                                precomp_state <= PC_CALC_2P;
                            end
                        end

                        PC_CALC_2P: begin
                            if (wait_pc_dbl && pc_dbl_done) begin
                                wait_pc_dbl <= 1'b0;
                                // Store 2P in affine (need to convert)
                                pc_inv_in <= pc_dbl_z;
                                pc_inv_start <= 1'b1;
                                wait_pc_inv <= 1'b1;
                                pc_x <= pc_dbl_x;
                                pc_y <= pc_dbl_y;
                                pc_z <= pc_dbl_z;
                                pc_aff_step <= 2'd0;
                                precomp_state <= PC_WAIT_2P;
                            end
                        end

                        PC_WAIT_2P: begin
                            if (wait_pc_inv && pc_inv_done) begin
                                pc_z_inv <= pc_inv_out;
                                wait_pc_inv <= 1'b0;
                                // z^2
                                pc_mul_a <= pc_inv_out;
                                pc_mul_b <= pc_inv_out;
                                pc_mul_start <= 1'b1;
                                wait_pc_mul <= 1'b1;
                                pc_aff_step <= 2'd0;
                                precomp_state <= PC_ADD_2P;
                            end
                        end

                        PC_ADD_2P: begin
                            if (wait_pc_mul && pc_mul_done) begin
                                wait_pc_mul <= 1'b0;
                                case (pc_aff_step)
                                    2'd0: begin
                                        pc_z2 <= pc_mul_result;
                                        pc_mul_a <= pc_x;
                                        pc_mul_b <= pc_mul_result;
                                        pc_mul_start <= 1'b1;
                                        wait_pc_mul <= 1'b1;
                                        pc_aff_step <= 2'd1;
                                    end
                                    2'd1: begin
                                        pc_aff_x <= pc_mul_result;
                                        p2_x <= pc_mul_result;  // Store 2P.x
                                        pc_mul_a <= pc_z2;
                                        pc_mul_b <= pc_z_inv;
                                        pc_mul_start <= 1'b1;
                                        wait_pc_mul <= 1'b1;
                                        pc_aff_step <= 2'd2;
                                    end
                                    2'd2: begin
                                        pc_mul_a <= pc_y;
                                        pc_mul_b <= pc_mul_result;
                                        pc_mul_start <= 1'b1;
                                        wait_pc_mul <= 1'b1;
                                        pc_aff_step <= 2'd3;
                                    end
                                    2'd3: begin
                                        pc_aff_y <= pc_mul_result;
                                        p2_y <= pc_mul_result;  // Store 2P.y
                                        have_2p <= 1'b1;

                                        // Now compute 3P, 5P, ... using P + 2P iteratively
                                        // Start with 3P = P + 2P
                                        pc_x <= bx;
                                        pc_y <= by;
                                        pc_z <= 256'd1;
                                        pc_add_start <= 1'b1;
                                        wait_pc_add <= 1'b1;
                                        precomp_state <= PC_WAIT_ADD;
                                    end
                                endcase
                            end
                        end

                        PC_WAIT_ADD: begin
                            if (wait_pc_add && pc_add_done) begin
                                wait_pc_add <= 1'b0;
                                // Convert result to affine
                                pc_x <= pc_add_x;
                                pc_y <= pc_add_y;
                                pc_z <= pc_add_z;
                                pc_inv_in <= pc_add_z;
                                pc_inv_start <= 1'b1;
                                wait_pc_inv <= 1'b1;
                                pc_aff_step <= 2'd0;
                                precomp_state <= PC_NEXT;
                            end
                        end

                        PC_NEXT: begin
                            if (wait_pc_inv && pc_inv_done) begin
                                pc_z_inv <= pc_inv_out;
                                wait_pc_inv <= 1'b0;
                                pc_mul_a <= pc_inv_out;
                                pc_mul_b <= pc_inv_out;
                                pc_mul_start <= 1'b1;
                                wait_pc_mul <= 1'b1;
                                pc_aff_step <= 2'd0;
                            end else if (wait_pc_mul && pc_mul_done) begin
                                wait_pc_mul <= 1'b0;
                                case (pc_aff_step)
                                    2'd0: begin
                                        pc_z2 <= pc_mul_result;
                                        pc_mul_a <= pc_x;
                                        pc_mul_b <= pc_mul_result;
                                        pc_mul_start <= 1'b1;
                                        wait_pc_mul <= 1'b1;
                                        pc_aff_step <= 2'd1;
                                    end
                                    2'd1: begin
                                        pc_aff_x <= pc_mul_result;
                                        pc_mul_a <= pc_z2;
                                        pc_mul_b <= pc_z_inv;
                                        pc_mul_start <= 1'b1;
                                        wait_pc_mul <= 1'b1;
                                        pc_aff_step <= 2'd2;
                                    end
                                    2'd2: begin
                                        pc_mul_a <= pc_y;
                                        pc_mul_b <= pc_mul_result;
                                        pc_mul_start <= 1'b1;
                                        wait_pc_mul <= 1'b1;
                                        pc_aff_step <= 2'd3;
                                    end
                                    2'd3: begin
                                        // Store point in table
                                        precomp_x[precomp_idx] <= pc_aff_x;
                                        precomp_y[precomp_idx] <= pc_mul_result;
                                        precomp_idx <= precomp_idx + 1'b1;

                                        if (precomp_idx >= NUM_POINTS - 1) begin
                                            precomp_done <= 1'b1;
                                            state <= FIND_MSB;
                                        end else begin
                                            // Next: (2i+1)P + 2P = (2i+3)P
                                            pc_x <= pc_aff_x;
                                            pc_y <= pc_mul_result;
                                            pc_z <= 256'd1;
                                            pc_add_start <= 1'b1;
                                            wait_pc_add <= 1'b1;
                                            precomp_state <= PC_WAIT_ADD;
                                        end
                                    end
                                endcase
                            end
                        end

                        default: precomp_state <= PC_STORE_P;
                    endcase
                end

                // ============ Main Multiplication Loop ============
                FIND_MSB: begin
                    // Find first non-zero NAF digit from MSB
                    if (naf_len == 9'd0) begin
                        point_at_inf <= 1'b1;
                        state <= DONE_STATE;
                    end else begin
                        digit_pos <= naf_len - 1'b1;
                        r_is_inf <= 1'b1;
                        found_first <= 1'b0;
                        state <= CHECK_DIGIT;
                    end
                end

                INIT_ACCUM: begin
                    if (naf_digit > 0) begin
                        rx <= precomp_x[(naf_digit - 1) >> 1];
                        ry <= precomp_y[(naf_digit - 1) >> 1];
                        rz <= 256'd1;
                        r_is_inf <= 1'b0;
                    end else begin
                        rx <= precomp_x[(-naf_digit - 1) >> 1];
                        ry <= SECP256K1_P - precomp_y[(-naf_digit - 1) >> 1];
                        rz <= 256'd1;
                        r_is_inf <= 1'b0;
                    end
                    found_first <= 1'b1;
                    state <= NEXT_DIGIT;
                end


                DOUBLE: begin
                    if (!r_is_inf) begin
                        dbl_start <= 1'b1;
                        wait_dbl <= 1'b1;
                        state <= WAIT_DOUBLE;
                    end else begin
                        state <= CHECK_DIGIT;
                    end
                end

                WAIT_DOUBLE: begin
                    if (wait_dbl && dbl_done) begin
                        rx <= dbl_x;
                        ry <= dbl_y;
                        rz <= dbl_z;
                        wait_dbl <= 1'b0;
                        state <= CHECK_DIGIT;
                    end
                end

                CHECK_DIGIT: begin
                    curr_digit <= naf_digit;

                    if (naf_digit == 8'sd0) begin
                        // Zero digit, just continue
                        state <= NEXT_DIGIT;
                    end else if (!found_first) begin
                        // First non-zero digit, initialize accumulator
                        state <= INIT_ACCUM;
                    end else if (naf_digit > 8'sd0) begin
                        // Positive digit: add precomp point
                        add_px <= precomp_x[(naf_digit - 1) >> 1];
                        add_py <= precomp_y[(naf_digit - 1) >> 1];
                        state <= ADD_POINT;
                    end else begin
                        // Negative digit: subtract (add negated Y)
                        add_px <= precomp_x[(-naf_digit - 1) >> 1];
                        add_py <= SECP256K1_P - precomp_y[(-naf_digit - 1) >> 1];
                        state <= ADD_POINT;
                    end
                end

                ADD_POINT: begin
                    if (r_is_inf) begin
                        // R was infinity, just set R = P
                        rx <= add_px;
                        ry <= add_py;
                        rz <= 256'd1;
                        r_is_inf <= 1'b0;
                        state <= NEXT_DIGIT;
                    end else begin
                        add_start <= 1'b1;
                        wait_add <= 1'b1;
                        state <= WAIT_ADD;
                    end
                end

                WAIT_ADD: begin
                    if (wait_add && add_done) begin
                        rx <= add_x;
                        ry <= add_y;
                        rz <= add_z;
                        wait_add <= 1'b0;
                        state <= NEXT_DIGIT;
                    end
                end

                NEXT_DIGIT: begin
                    if (digit_pos == 9'd0) begin
                        // Done with all digits
                        if (r_is_inf) begin
                            point_at_inf <= 1'b1;
                            qx <= 256'd0;
                            qy <= 256'd0;
                            state <= DONE_STATE;
                        end else begin
                            state <= TO_AFFINE;
                        end
                    end else begin
                        digit_pos <= digit_pos - 1'b1;
                        state <= DOUBLE;
                    end
                end

                // ============ Convert to Affine ============
                TO_AFFINE: begin
                    if (rz == 256'd0) begin
                        point_at_inf <= 1'b1;
                        qx <= 256'd0;
                        qy <= 256'd0;
                        state <= DONE_STATE;
                    end else begin
                        inv_start <= 1'b1;
                        wait_inv <= 1'b1;
                        state <= WAIT_INV;
                    end
                end

                WAIT_INV: begin
                    if (wait_inv && inv_done) begin
                        z_inv <= inv_out;
                        wait_inv <= 1'b0;
                        mul_a <= inv_out;
                        mul_b <= inv_out;
                        mul_start <= 1'b1;
                        wait_mul <= 1'b1;
                        state <= CALC_Z2;
                    end
                end

                CALC_Z2: begin
                    if (wait_mul && mul_done) begin
                        z2 <= mul_result;
                        wait_mul <= 1'b0;
                        mul_a <= rx;
                        mul_b <= mul_result;
                        mul_start <= 1'b1;
                        wait_mul <= 1'b1;
                        state <= CALC_QX;
                    end
                end

                CALC_QX: begin
                    if (wait_mul && mul_done) begin
                        qx <= mul_result;
                        wait_mul <= 1'b0;
                        mul_a <= z2;
                        mul_b <= z_inv;
                        mul_start <= 1'b1;
                        wait_mul <= 1'b1;
                        state <= CALC_Z3;
                    end
                end

                CALC_Z3: begin
                    if (wait_mul && mul_done) begin
                        z3 <= mul_result;
                        wait_mul <= 1'b0;
                        mul_a <= ry;
                        mul_b <= mul_result;
                        mul_start <= 1'b1;
                        wait_mul <= 1'b1;
                        state <= CALC_QY;
                    end
                end

                CALC_QY: begin
                    if (wait_mul && mul_done) begin
                        qy <= mul_result;
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

    // Initialize precomputed table
    integer i;
    initial begin
        for (i = 0; i < NUM_POINTS; i = i + 1) begin
            precomp_x[i] = 256'd0;
            precomp_y[i] = 256'd0;
        end
    end

endmodule
