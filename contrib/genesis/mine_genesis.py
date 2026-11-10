#!/usr/bin/env python3
"""Mine Le0 genesis blocks (SHA256d) matching Bitcoin Core CreateGenesisBlock layout."""

from __future__ import annotations

import hashlib
import multiprocessing as mp
import struct
import time
from typing import Optional


COIN = 100_000_000
PUBKEY = bytes.fromhex(
    "04678afdb0fe5548271967f1a67130b7105cd6a828e03909a67962e0ea1f61deb649f6bc3f4cef38c4f35504e51ec112de5c384df7ba0b8d578a4c702b6bf11d5f"
)
TIMESTAMP = b"Le0 genesis 2026-11-03 fair launch CPU-leaning PoW"


def sha256d(data: bytes) -> bytes:
    return hashlib.sha256(hashlib.sha256(data).digest()).digest()


def compact_to_target(bits: int) -> int:
    exponent = bits >> 24
    mantissa = bits & 0xFFFFFF
    if exponent <= 3:
        return mantissa >> (8 * (3 - exponent))
    return mantissa << (8 * (exponent - 3))


def ser_uint32(n: int) -> bytes:
    return struct.pack("<I", n)


def ser_int32(n: int) -> bytes:
    return struct.pack("<i", n)


def ser_uint64(n: int) -> bytes:
    return struct.pack("<Q", n)


def ser_varint(n: int) -> bytes:
    if n < 0xFD:
        return struct.pack("<B", n)
    if n <= 0xFFFF:
        return b"\xfd" + struct.pack("<H", n)
    if n <= 0xFFFFFFFF:
        return b"\xfe" + struct.pack("<I", n)
    return b"\xff" + struct.pack("<Q", n)


def ser_script(script: bytes) -> bytes:
    return ser_varint(len(script)) + script


def make_coinbase_script_sig(timestamp: bytes) -> bytes:
    return b"\x04\xff\xff\x00\x1d\x01\x04" + bytes([len(timestamp)]) + timestamp


def make_genesis_tx(timestamp: bytes, reward: int, pubkey: bytes) -> bytes:
    script_sig = make_coinbase_script_sig(timestamp)
    script_pubkey = bytes([len(pubkey)]) + pubkey + b"\xac"
    tx = b""
    tx += ser_uint32(1)
    tx += ser_varint(1)
    tx += b"\x00" * 32
    tx += ser_uint32(0xFFFFFFFF)
    tx += ser_script(script_sig)
    tx += ser_uint32(0xFFFFFFFF)
    tx += ser_varint(1)
    tx += ser_uint64(reward)
    tx += ser_script(script_pubkey)
    tx += ser_uint32(0)
    return tx


def block_header(version: int, merkle: bytes, ntime: int, nbits: int, nonce: int) -> bytes:
    return (
        ser_int32(version)
        + (b"\x00" * 32)
        + merkle
        + ser_uint32(ntime)
        + ser_uint32(nbits)
        + ser_uint32(nonce)
    )


def _worker(args: tuple) -> Optional[tuple[int, bytes]]:
    merkle, ntime, nbits, version, start, count, target = args
    end = start + count
    for nonce in range(start, end):
        digest = sha256d(block_header(version, merkle, ntime, nbits, nonce))
        if int.from_bytes(digest, "little") <= target:
            return nonce, digest
    return None


def mine(name: str, ntime: int, nbits: int, version: int = 1, reward: int = 24 * COIN) -> dict:
    tx = make_genesis_tx(TIMESTAMP, reward, PUBKEY)
    merkle = sha256d(tx)
    target = compact_to_target(nbits)
    workers = max(mp.cpu_count(), 1)
    chunk = 250_000

    print(f"[{name}] mining bits=0x{nbits:08x} workers={workers}", flush=True)
    print(f"[{name}] merkle_root_be={merkle[::-1].hex()}", flush=True)

    start_t = time.time()
    nonce_base = 0
    with mp.Pool(processes=workers) as pool:
        while True:
            tasks = [
                (merkle, ntime, nbits, version, nonce_base + i * chunk, chunk, target)
                for i in range(workers)
            ]
            for result in pool.imap_unordered(_worker, tasks):
                if result is not None:
                    nonce, digest = result
                    elapsed = time.time() - start_t
                    block_hash_be = digest[::-1].hex()
                    print(f"[{name}] FOUND nonce={nonce} hash={block_hash_be} in {elapsed:.2f}s", flush=True)
                    pool.terminate()
                    return {
                        "name": name,
                        "nTime": ntime,
                        "nNonce": nonce,
                        "nBits": nbits,
                        "nVersion": version,
                        "merkle_root": merkle[::-1].hex(),
                        "hash": block_hash_be,
                    }
            nonce_base += workers * chunk
            if nonce_base > 0xFFFFFFFF:
                raise RuntimeError(f"{name}: nonce space exhausted")
            rate = nonce_base / max(time.time() - start_t, 1e-6)
            print(f"[{name}] tried {nonce_base:,} ({rate:,.0f} H/s)", flush=True)


def main() -> None:
    # 0x1e0fffff matches casual powLimit 00000fff... (much easier than BTC diff-1).
    results = [
        mine("main", ntime=1730664000, nbits=0x1E0FFFFF),
        mine("test", ntime=1730664001, nbits=0x1E0FFFFF),
        mine("regtest", ntime=1730664002, nbits=0x207FFFFF),
        mine("testnet4", ntime=1730664003, nbits=0x1E0FFFFF),
    ]
    print("\n=== paste into chainparams ===", flush=True)
    for r in results:
        print(
            f"{r['name']}: CreateGenesisBlock({r['nTime']}, {r['nNonce']}, "
            f"0x{r['nBits']:08x}, {r['nVersion']}, 24 * COIN);",
            flush=True,
        )
        print(f"  hashGenesisBlock = {r['hash']}", flush=True)
        print(f"  hashMerkleRoot   = {r['merkle_root']}", flush=True)


if __name__ == "__main__":
    mp.freeze_support()
    main()
