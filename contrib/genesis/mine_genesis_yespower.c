/*
 * Mine Le0 genesis using Yespower 1.0 (N=2048,r=8,pers="Le0").
 * Header serialization matches Bitcoin Core CBlockHeader / DataStream.
 *
 * Build (from this directory, after yespower objects exist or via cl):
 *   cl /O2 /I..\..\src\crypto\yespower mine_genesis_yespower.c
 *      ..\..\src\crypto\yespower\yespower-ref.c ..\..\src\crypto\yespower\sha256.c
 */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "yespower.h"

static const char PERS[] = "Le0";
static const char TIMESTAMP[] = "Le0 genesis 2026-11-03 fair launch CPU-leaning PoW";
static const unsigned char PUBKEY[65] = {
    0x04,0x67,0x8a,0xfd,0xb0,0xfe,0x55,0x48,0x27,0x19,0x67,0xf1,0xa6,0x71,0x30,0xb7,
    0x10,0x5c,0xd6,0xa8,0x28,0xe0,0x39,0x09,0xa6,0x79,0x62,0xe0,0xea,0x1f,0x61,0xde,
    0xb6,0x49,0xf6,0xbc,0x3f,0x4c,0xef,0x38,0xc4,0xf3,0x55,0x04,0xe5,0x1e,0xc1,0x12,
    0xde,0x5c,0x38,0x4d,0xf7,0xba,0x0b,0x8d,0x57,0x8a,0x4c,0x70,0x2b,0x6b,0xf1,0x1d,
    0x5f
};

/* minimal sha256d for merkle of coinbase (same as Bitcoin) */
#include "sha256.h"

static void sha256d(const unsigned char *in, size_t len, unsigned char out[32])
{
    SHA256_CTX ctx;
    unsigned char mid[32];
    SHA256_Init(&ctx);
    SHA256_Update(&ctx, in, len);
    SHA256_Final(mid, &ctx);
    SHA256_Init(&ctx);
    SHA256_Update(&ctx, mid, 32);
    SHA256_Final(out, &ctx);
}

static void wr_u32(unsigned char *p, uint32_t v)
{
    p[0] = (unsigned char)(v); p[1] = (unsigned char)(v >> 8);
    p[2] = (unsigned char)(v >> 16); p[3] = (unsigned char)(v >> 24);
}

static void wr_u64(unsigned char *p, uint64_t v)
{
    for (int i = 0; i < 8; i++) p[i] = (unsigned char)(v >> (8 * i));
}

static size_t ser_varint(unsigned char *p, uint64_t n)
{
    if (n < 0xfd) { p[0] = (unsigned char)n; return 1; }
    if (n <= 0xffff) { p[0] = 0xfd; p[1] = (unsigned char)n; p[2] = (unsigned char)(n >> 8); return 3; }
    p[0] = 0xfe; wr_u32(p + 1, (uint32_t)n); return 5;
}

static void make_coinbase_tx(unsigned char *tx, size_t *txlen, uint64_t reward)
{
    unsigned char script_sig[128];
    size_t ss = 0;
    /* CScript() << 486604799 << CScriptNum(4) << timestamp */
    memcpy(script_sig + ss, "\x04\xff\xff\x00\x1d\x01\x04", 7); ss += 7;
    script_sig[ss++] = (unsigned char)strlen(TIMESTAMP);
    memcpy(script_sig + ss, TIMESTAMP, strlen(TIMESTAMP)); ss += strlen(TIMESTAMP);

    unsigned char *p = tx;
    wr_u32(p, 1); p += 4;                    /* version */
    p += ser_varint(p, 1);                   /* vin */
    memset(p, 0, 32); p += 32;               /* prevout hash */
    wr_u32(p, 0xffffffffu); p += 4;          /* prevout n */
    p += ser_varint(p, ss);
    memcpy(p, script_sig, ss); p += ss;
    wr_u32(p, 0xffffffffu); p += 4;          /* sequence */
    p += ser_varint(p, 1);                   /* vout */
    wr_u64(p, reward); p += 8;
    p += ser_varint(p, 67);                  /* scriptPubKey len: 65+1 OP_CHECKSIG */
    *p++ = 65;
    memcpy(p, PUBKEY, 65); p += 65;
    *p++ = 0xac;                             /* OP_CHECKSIG */
    wr_u32(p, 0); p += 4;                    /* locktime */
    *txlen = (size_t)(p - tx);
}

static int hash_meets_bits(const unsigned char hash[32], uint32_t nbits)
{
    int exp = (int)(nbits >> 24);
    uint32_t mant = nbits & 0xffffff;
    unsigned char target[32];
    memset(target, 0, 32);
    if (exp >= 3 && exp <= 32) {
        int idx = exp - 3;
        if (idx < 30) {
            target[29 - idx] = (unsigned char)((mant >> 16) & 0xff);
            target[30 - idx] = (unsigned char)((mant >> 8) & 0xff);
            target[31 - idx] = (unsigned char)(mant & 0xff);
        }
    }
    unsigned char hash_be[32];
    for (int i = 0; i < 32; i++) hash_be[i] = hash[31 - i];
    return memcmp(hash_be, target, 32) <= 0;
}

static void mine_one(const char *name, uint32_t ntime, uint32_t nbits)
{
    const uint64_t reward = 28ULL * 100000000ULL;
    unsigned char tx[512];
    size_t txlen = 0;
    make_coinbase_tx(tx, &txlen, reward);

    unsigned char merkle[32];
    sha256d(tx, txlen, merkle);

    unsigned char header[80];
    memset(header, 0, 80);
    wr_u32(header + 0, 1);
    memcpy(header + 36, merkle, 32);
    wr_u32(header + 68, ntime);
    wr_u32(header + 72, nbits);

    yespower_params_t params = {
        YESPOWER_1_0, 2048, 8,
        (const uint8_t *)PERS, sizeof(PERS) - 1
    };

    printf("[%s] yespower mining nbits=0x%08x merkle_be=", name, nbits);
    for (int i = 31; i >= 0; i--) printf("%02x", merkle[i]);
    printf("\n");
    fflush(stdout);

    clock_t t0 = clock();
    yespower_binary_t pow;
    for (uint32_t nonce = 0;; nonce++) {
        wr_u32(header + 76, nonce);
        if (yespower_tls(header, 80, &params, &pow) != 0) {
            fprintf(stderr, "yespower_tls failed\n");
            exit(1);
        }
        if (hash_meets_bits(pow.uc, nbits)) {
            double sec = (double)(clock() - t0) / CLOCKS_PER_SEC;
            printf("[%s] FOUND nonce=%u in %.2fs\n", name, nonce, sec);
            printf("  hashGenesisBlock=");
            for (int i = 31; i >= 0; i--) printf("%02x", pow.uc[i]);
            printf("\n  hashMerkleRoot=");
            for (int i = 31; i >= 0; i--) printf("%02x", merkle[i]);
            printf("\n  CreateGenesisBlock(%u, %u, 0x%08x, 1, 28 * COIN);\n",
                   ntime, nonce, nbits);
            fflush(stdout);
            return;
        }
        if ((nonce & 0xfff) == 0 && nonce) {
            double sec = (double)(clock() - t0) / CLOCKS_PER_SEC;
            if (sec > 0)
                printf("[%s] tried %u (%.1f H/s)\n", name, nonce, nonce / sec);
            fflush(stdout);
        }
        if (nonce == 0xffffffffu) break;
    }
    fprintf(stderr, "[%s] exhausted\n", name);
    exit(1);
}

int main(void)
{
    mine_one("main", 1730664000u, 0x1f0fffffu);
    mine_one("test", 1730664001u, 0x1f0fffffu);
    mine_one("regtest", 1730664002u, 0x207fffffu);
    mine_one("testnet4", 1730664003u, 0x1f0fffffu);
    return 0;
}
