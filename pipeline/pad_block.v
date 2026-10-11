// pad_block.v -- Pad a short message (<=55 bytes) into one 512-bit block.
// byte i of message in bits [511-8*i -: 8]; then 0x80, zeros and the 64-bit
// bit-length. le_len=0 -> big-endian length (SHA-256); le_len=1 -> little-endian
// (RIPEMD-160 message padding, words read little-endian by that core).
module pad_block (
    input  wire [319:0] msg,      // up to 40 message bytes, byte0 = msg[319:312]
    input  wire [5:0]   nbytes,   // valid message length in bytes
    input  wire         le_len,   // endianness of the 64-bit length field
    output reg  [511:0] blk
);
    wire [15:0] len_bits = nbytes * 16'd8;
    integer i;
    always @* begin
        for (i = 0; i < 64; i = i + 1) begin
            if (i < nbytes)
                blk[511 - 8*i -: 8] = msg[319 - 8*i -: 8];
            else if (i == nbytes)
                blk[511 - 8*i -: 8] = 8'h80;
            else if (i >= 56)
                blk[511 - 8*i -: 8] = 8'd0;
            else
                blk[511 - 8*i -: 8] = 8'd0;
        end
        // 64-bit length field (bits 448..511 = bytes 56..63)
        if (le_len) begin
            blk[511 - 8*56 -: 8] = len_bits[7:0];
            blk[511 - 8*57 -: 8] = len_bits[15:8];
        end else begin
            blk[511 - 8*62 -: 8] = len_bits[15:8];
            blk[511 - 8*63 -: 8] = len_bits[7:0];
        end
    end
endmodule