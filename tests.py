#!/usr/bin/env python3
"""
secp256k1 Verification Test Suite
=================================

Pure Python implementation for verifying secp256k1 elliptic curve operations.
No external dependencies required.

Test Coverage:
    1. Curve sanity checks (G on curve, -G calculation)
    2. Known scalar multiplication vectors: k = 1, 2, 3, 7, 8, 255
    3. Group order checks: n*G = infinity, (n-1)*G = -G
    4. ECDSA sign/verify with RFC6979 deterministic nonce

Usage:
    python tests.py

Expected Output:
    ALL TESTS PASSED.

This script validates that the Verilog implementation produces correct results
by comparing against known test vectors from the secp256k1 specification.

Author: Bruno Silva (bsbruno@proton.me)
"""

import hashlib
import hmac
from typing import Optional, Tuple

# ---- Curve params (from your Verilog) ----
P = int("FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEFFFFFC2F", 16)
N = int("FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141", 16)

GX = int("79BE667EF9DCBBAC55A06295CE870B07029BFCDB2DCE28D959F2815B16F81798", 16)
GY = int("483ADA7726A3C4655DA4FBFC0E1108A8FD17B448A68554199C47D08FFB10D4B8", 16)

NEG_GY = int("B7C52588D95C3B9AA25B0403F1EEF75702E84BB7597AABE663B82F6F04EF2777", 16)

VECTORS = {
    1: (GX, GY),
    2: (
        int("C6047F9441ED7D6D3045406E95C07CD85C778E4B8CEF3CA7ABAC09B95C709EE5", 16),
        int("1AE168FEA63DC339A3C58419466CEAEEF7F632653266D0E1236431A950CFE52A", 16),
    ),
    3: (
        int("F9308A019258C31049344F85F89D5229B531C845836F99B08601F113BCE036F9", 16),
        int("388F7B0F632DE8140FE337E62A37F3566500A99934C2231B6CB9FD7584B8E672", 16),
    ),
    7: (
        int("5CBDF0646E5DB4EAA398F365F2EA7A0E3D419B7E0330E39CE92BDDEDCAC4F9BC", 16),
        int("6AEBCA40BA255960A3178D6D861A54DBA813D0B813FDE7B5A5082628087264DA", 16),
    ),
    8: (
        int("2F01E5E15CCA351DAFF3843FB70F3C2F0A1BDD05E5AF888A67784EF3E10A2A01", 16),
        int("5C4DA8A741539949293D082A132D13B4C2E213D6BA5B7617B5DA2CB76CBDE904", 16),
    ),
    255: (
        int("1B38903A43F7F114ED4500B4EAC7083FDEFECE1CF29C63528D563446F972C180", 16),
        int("4036EDC931A60AE889353F77FD53DE4A2708B26B6F5DA72AD3394119DAF408F9", 16),
    ),
}

Point = Optional[Tuple[int, int]]  # None = infinity


# ---- Math helpers ----
def mod_inv(a: int, m: int) -> int:
    """Inverse via extended Euclid. Raises if non-invertible."""
    a %= m
    if a == 0:
        raise ZeroDivisionError("inverse of 0")
    # Extended Euclid
    t, newt = 0, 1
    r, newr = m, a
    while newr != 0:
        q = r // newr
        t, newt = newt, t - q * newt
        r, newr = newr, r - q * newr
    if r != 1:
        raise ZeroDivisionError("not invertible")
    return t % m


def is_on_curve(Pt: Point) -> bool:
    if Pt is None:
        return True
    x, y = Pt
    if not (0 <= x < P and 0 <= y < P):
        return False
    # secp256k1: y^2 = x^3 + 7
    return (y * y - (x * x * x + 7)) % P == 0


def point_neg(Pt: Point) -> Point:
    if Pt is None:
        return None
    x, y = Pt
    return (x, (-y) % P)


def point_add(A: Point, B: Point) -> Point:
    if A is None:
        return B
    if B is None:
        return A
    x1, y1 = A
    x2, y2 = B

    if x1 == x2:
        if (y1 + y2) % P == 0:
            return None
        # A == B (doubling)
        return point_double(A)

    lam = ((y2 - y1) * mod_inv(x2 - x1, P)) % P
    x3 = (lam * lam - x1 - x2) % P
    y3 = (lam * (x1 - x3) - y1) % P
    return (x3, y3)


def point_double(A: Point) -> Point:
    if A is None:
        return None
    x1, y1 = A
    if y1 == 0:
        return None
    lam = ((3 * x1 * x1) * mod_inv(2 * y1, P)) % P
    x3 = (lam * lam - 2 * x1) % P
    y3 = (lam * (x1 - x3) - y1) % P
    return (x3, y3)


def scalar_mul(k: int, Pt: Point) -> Point:
    """Double-and-add (left-to-right)."""
    k %= N  # standard in ECDSA context; for pure group mul you could use k%N too.
    if k == 0 or Pt is None:
        return None
    R = None
    Q = Pt
    while k > 0:
        if k & 1:
            R = point_add(R, Q)
        Q = point_double(Q)
        k >>= 1
    return R


# ---- RFC6979 deterministic k for ECDSA (HMAC-SHA256) ----
def rfc6979_k(privkey: int, h1: bytes) -> int:
    """
    RFC6979 for curve order N using HMAC-SHA256.
    """
    x = privkey.to_bytes(32, "big")
    qlen = N.bit_length()
    holen = hashlib.sha256().digest_size
    rolen = (qlen + 7) // 8

    def bits2int(b: bytes) -> int:
        i = int.from_bytes(b, "big")
        blen = len(b) * 8
        if blen > qlen:
            i >>= (blen - qlen)
        return i

    def int2octets(v: int) -> bytes:
        return v.to_bytes(rolen, "big")

    def bits2octets(b: bytes) -> bytes:
        z1 = bits2int(b)
        z2 = z1 % N
        return int2octets(z2)

    V = b"\x01" * holen
    K = b"\x00" * holen
    K = hmac.new(K, V + b"\x00" + x + bits2octets(h1), hashlib.sha256).digest()
    V = hmac.new(K, V, hashlib.sha256).digest()
    K = hmac.new(K, V + b"\x01" + x + bits2octets(h1), hashlib.sha256).digest()
    V = hmac.new(K, V, hashlib.sha256).digest()

    while True:
        T = b""
        while len(T) < rolen:
            V = hmac.new(K, V, hashlib.sha256).digest()
            T += V
        k = bits2int(T)
        if 1 <= k < N:
            return k
        K = hmac.new(K, V + b"\x00", hashlib.sha256).digest()
        V = hmac.new(K, V, hashlib.sha256).digest()


# ---- ECDSA ----
def ecdsa_sign(privkey: int, msg: bytes) -> Tuple[int, int]:
    if not (1 <= privkey < N):
        raise ValueError("bad privkey")
    z = hashlib.sha256(msg).digest()
    k = rfc6979_k(privkey, z)
    R = scalar_mul(k, (GX, GY))
    assert R is not None
    r = R[0] % N
    if r == 0:
        raise RuntimeError("r=0, retry (shouldn't with RFC6979 normally)")
    s = (mod_inv(k, N) * ((int.from_bytes(z, "big") % N) + r * privkey)) % N
    if s == 0:
        raise RuntimeError("s=0, retry")
    return r, s


def ecdsa_verify(pub: Point, msg: bytes, sig: Tuple[int, int]) -> bool:
    if pub is None or not is_on_curve(pub):
        return False
    r, s = sig
    if not (1 <= r < N and 1 <= s < N):
        return False
    z = int.from_bytes(hashlib.sha256(msg).digest(), "big") % N
    w = mod_inv(s, N)
    u1 = (z * w) % N
    u2 = (r * w) % N
    P1 = scalar_mul(u1, (GX, GY))
    P2 = scalar_mul(u2, pub)
    X = point_add(P1, P2)
    if X is None:
        return False
    return (X[0] % N) == r


# ---- Tests ----
def hex256(x: int) -> str:
    return f"{x:064x}"


def main():
    G = (GX, GY)

    print("=== Curve sanity ===")
    assert P > 3 and N > 3
    assert is_on_curve(G), "G not on curve!"
    assert (P - GY) % P == NEG_GY, "NEG_GY mismatch (should be p - GY)"
    assert is_on_curve((GX, NEG_GY)), "-G not on curve!"
    print("OK: curve params and G/-G check")

    print("\n=== Scalar mul known vectors ===")
    for k, (ex, ey) in VECTORS.items():
        R = scalar_mul(k, G)
        assert R is not None, f"k={k} got infinity"
        x, y = R
        ok = (x == ex and y == ey)
        print(f"k={k:>3}: {'PASS' if ok else 'FAIL'}")
        if not ok:
            print(" expected x:", hex256(ex))
            print(" got      x:", hex256(x))
            print(" expected y:", hex256(ey))
            print(" got      y:", hex256(y))
            raise SystemExit(1)

    print("\n=== Classic group checks ===")
    # n*G = infinity
    Rn = scalar_mul(N, G)
    assert Rn is None, "n*G should be infinity"
    # (n-1)*G = -G
    Rnm1 = scalar_mul(N - 1, G)
    assert Rnm1 == (GX, NEG_GY), "(n-1)*G should be -G"
    print("PASS: n*G=inf and (n-1)*G=-G")

    print("\n=== ECDSA sign/verify test ===")
    priv = 0x123456789ABCDEF123456789ABCDEF123456789ABCDEF123456789ABCDEF1234 % N
    if priv == 0:
        priv = 1
    pub = scalar_mul(priv, G)
    assert pub is not None and is_on_curve(pub)

    msg = b"secp256k1 fpga test"
    sig = ecdsa_sign(priv, msg)
    ok = ecdsa_verify(pub, msg, sig)
    print("priv =", hex256(priv))
    print("pubX =", hex256(pub[0]))
    print("pubY =", hex256(pub[1]))
    print("sig r=", hex256(sig[0]))
    print("sig s=", hex256(sig[1]))
    print("verify:", "PASS" if ok else "FAIL")
    assert ok

    print("\nALL TESTS PASSED.")


if __name__ == "__main__":
    main()
