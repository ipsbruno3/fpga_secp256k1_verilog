#!/usr/bin/env python3
"""
secp256k1 wNAF Precomputation Table Generator
=============================================

Generates the lookup table of odd multiples of G for wNAF scalar multiplication.
The table contains points: G, 3G, 5G, 7G, ..., (2^W - 1)G

Configuration:
    W = Window size (bits)
    Number of points = 2^(W-1)

Examples:
    W = 4  ->   8 points (1G, 3G, ..., 15G)
    W = 8  -> 128 points (1G, 3G, ..., 255G)
    W = 10 -> 512 points (1G, 3G, ..., 1023G)
    W = 11 -> 1024 points (1G, 3G, ..., 2047G)

Output:
    Verilog localparam declarations for precomp_x and precomp_y arrays

Usage:
    python gen_secp256k1_wnaf_table.py > nafs/secp256k1_precomp_wN.sv

Author: Bruno Silva (bsbruno@proton.me)
"""

# secp256k1 curve parameters
P  = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEFFFFFC2F
GX = 0x79BE667EF9DCBBAC55A06295CE870B07029BFCDB2DCE28D959F2815B16F81798
GY = 0x483ADA7726A3C4655DA4FBFC0E1108A8FD17B448A68554199C47D08FFB10D4B8

def inv(a):  # inverso mod P
    return pow(a, P-2, P)

INF = None  # ponto no infinito

def add(P1, P2):
    if P1 is INF: return P2
    if P2 is INF: return P1
    x1,y1 = P1
    x2,y2 = P2
    if x1 == x2:
        if (y1 + y2) % P == 0:
            return INF
        # P1==P2 => doubling
        return dbl(P1)
    lam = ((y2 - y1) * inv((x2 - x1) % P)) % P
    x3 = (lam*lam - x1 - x2) % P
    y3 = (lam*(x1 - x3) - y1) % P
    return (x3,y3)

def dbl(P1):
    if P1 is INF: return INF
    x1,y1 = P1
    if y1 == 0: return INF
    lam = ((3*x1*x1) * inv((2*y1) % P)) % P
    x3 = (lam*lam - 2*x1) % P
    y3 = (lam*(x1 - x3) - y1) % P
    return (x3,y3)

def gen_table(W):
    num = 1 << (W-1)
    G = (GX,GY)
    twoG = dbl(G)

    pts = []
    cur = G  # 1G
    for _ in range(num):
        pts.append(cur)
        cur = add(cur, twoG)  # +2G => próximo ímpar
    return pts

 

if __name__ == "__main__":
    W = 10
    pts = gen_table(W)
    xs = [x for (x,_) in pts]
    ys = [y for (_,y) in pts]
    i = 0
    for v in xs:
        v = (f"{v:064x};").upper();
        print(f"localparam [255:0] K{i}_X = 256'h{v}\n")
        i += 1
    i=0
    for v in ys:
        v = (f"{v:064x};").upper();
        print(f"localparam [255:0] K{i}_Y = 256'h{v}\n")
        i += 1

    print("OK: gerados .mem para W=10 (512 pontos)")
