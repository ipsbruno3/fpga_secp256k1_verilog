
//-----------------------------------------------------------------------------
// secp256k1_defines.vh
// Common definitions for secp256k1 FPGA implementation
//-----------------------------------------------------------------------------

`ifndef SECP256K1_DEFINES_VH
`define SECP256K1_DEFINES_VH

// secp256k1 curve parameters
// Prime: p = 2^256 - 2^32 - 977
// Equation: y² = x³ + 7 (mod p)
// Order: n = FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141

// Prime field modulus p
`define SECP256K1_P 256'hFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEFFFFFC2F

// Curve coefficient b = 7 (a = 0 for secp256k1)
`define SECP256K1_B 256'h0000000000000000000000000000000000000000000000000000000000000007

// Generator point G
`define SECP256K1_GX 256'h79BE667EF9DCBBAC55A06295CE870B07029BFCDB2DCE28D959F2815B16F81798
`define SECP256K1_GY 256'h483ADA7726A3C4655DA4FBFC0E1108A8FD17B448A68554199C47D08FFB10D4B8

// Curve order n (number of points)
`define SECP256K1_N 256'hFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141

// Reduction constant: 2^32 + 977 (used for fast reduction mod p)
`define SECP256K1_R 64'h00000001000003D1

// Reduction value: 977
`define SECP256K1_977 32'h000003D1

`endif // SECP256K1_DEFINES_VH
