// hit_detect.v -- comparador de hash160 contra a(s) targes dos puzzles.
// Hash de 160 bits vindo do pipeline (em {r4,r3,r2,r1,r0}); quando `valid`
// pulsa, registra `hit` (1 se igual a alguma target) e `hit_id`.
module hit_detect #(
    parameter NTARGETS     = 1,
    parameter [159:0] TARGET0 = 160'h693f0bfd72c433b3806acae3d49d59eaf9fbed5d
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire [159:0] hash,
    input  wire        valid,
    output reg         hit,
    output reg  [7:0]  hit_id
);
    reg [159:0] tgt [0:NTARGETS-1];
    integer i;
    reg        hit_next;
    reg [7:0]  id_next;
    initial begin
        tgt[0] = TARGET0;
        if (NTARGETS >= 2) tgt[1] = 160'h0; // extender aqui p/ mais alvos
        if (NTARGETS >= 3) tgt[2] = 160'h0;
    end

    always @* begin
        hit_next = 1'b0;
        id_next  = 8'd0;
        for (i = 0; i < NTARGETS; i = i + 1)
            if (hash == tgt[i]) begin
                hit_next = 1'b1;
                id_next  = i[7:0];
            end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            hit <= 1'b0;
            hit_id <= 8'd0;
        end else if (valid) begin
            hit <= hit_next;
            hit_id <= id_next;
        end
    end
endmodule