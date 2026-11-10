/* Fast SHA256d genesis miner for Le0 (single network at a time via args). */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

/* Minimal SHA256 */
typedef struct {
    uint32_t state[8];
    uint64_t bitlen;
    uint8_t data[64];
    uint32_t datalen;
} SHA256_CTX;

#define ROTRIGHT(a,b) (((a) >> (b)) | ((a) << (32-(b))))
#define CH(x,y,z) (((x) & (y)) ^ (~(x) & (z)))
#define MAJ(x,y,z) (((x) & (y)) ^ ((x) & (z)) ^ ((y) & (z)))
#define EP0(x) (ROTRIGHT(x,2) ^ ROTRIGHT(x,13) ^ ROTRIGHT(x,22))
#define EP1(x) (ROTRIGHT(x,6) ^ ROTRIGHT(x,11) ^ ROTRIGHT(x,25))
#define SIG0(x) (ROTRIGHT(x,7) ^ ROTRIGHT(x,18) ^ ((x) >> 3))
#define SIG1(x) (ROTRIGHT(x,17) ^ ROTRIGHT(x,19) ^ ((x) >> 10))

static const uint32_t k[64] = {
    0x428a2f98,0x71374491,0xb5c0fbcf,0xe9b5dba5,0x3956c25b,0x59f111f1,0x923f82a4,0xab1c5ed5,
    0xd807aa98,0x12835b01,0x243185be,0x550c7dc3,0x72be5d74,0x80deb1fe,0x9bdc06a7,0xc19bf174,
    0xe49b69c1,0xefbe4786,0x0fc19dc6,0x240ca1cc,0x2de92c6f,0x4a7484aa,0x5cb0a9dc,0x76f988da,
    0x983e5152,0xa831c66d,0xb00327c8,0xbf597fc7,0xc6e00bf3,0xd5a79147,0x06ca6351,0x14292967,
    0x27b70a85,0x2e1b2138,0x4d2c6dfc,0x53380d13,0x650a7354,0x766a0abb,0x81c2c92e,0x92722c85,
    0xa2bfe8a1,0xa81a664b,0xc24b8b70,0xc76c51a3,0xd192e819,0xd6990624,0xf40e3585,0x106aa070,
    0x19a4c116,0x1e376c08,0x2748774c,0x34b0bcb5,0x391c0cb3,0x4ed8aa4a,0x5b9cca4f,0x682e6ff3,
    0x748f82ee,0x78a5636f,0x84c87814,0x8cc70208,0x90befffa,0xa4506ceb,0xbef9a3f7,0xc67178f2
};

static void sha256_transform(SHA256_CTX *ctx, const uint8_t data[]) {
    uint32_t a,b,c,d,e,f,g,h,i,j,t1,t2,m[64];
    for (i = 0, j = 0; i < 16; ++i, j += 4)
        m[i] = ((uint32_t)data[j] << 24) | ((uint32_t)data[j+1] << 16) | ((uint32_t)data[j+2] << 8) | ((uint32_t)data[j+3]);
    for (; i < 64; ++i)
        m[i] = SIG1(m[i-2]) + m[i-7] + SIG0(m[i-15]) + m[i-16];
    a=ctx->state[0]; b=ctx->state[1]; c=ctx->state[2]; d=ctx->state[3];
    e=ctx->state[4]; f=ctx->state[5]; g=ctx->state[6]; h=ctx->state[7];
    for (i = 0; i < 64; ++i) {
        t1 = h + EP1(e) + CH(e,f,g) + k[i] + m[i];
        t2 = EP0(a) + MAJ(a,b,c);
        h=g; g=f; f=e; e=d+t1; d=c; c=b; b=a; a=t1+t2;
    }
    ctx->state[0]+=a; ctx->state[1]+=b; ctx->state[2]+=c; ctx->state[3]+=d;
    ctx->state[4]+=e; ctx->state[5]+=f; ctx->state[6]+=g; ctx->state[7]+=h;
}

static void sha256_init(SHA256_CTX *ctx) {
    ctx->datalen = 0; ctx->bitlen = 0;
    ctx->state[0]=0x6a09e667; ctx->state[1]=0xbb67ae85; ctx->state[2]=0x3c6ef372; ctx->state[3]=0xa54ff53a;
    ctx->state[4]=0x510e527f; ctx->state[5]=0x9b05688c; ctx->state[6]=0x1f83d9ab; ctx->state[7]=0x5be0cd19;
}

static void sha256_update(SHA256_CTX *ctx, const uint8_t data[], size_t len) {
    for (size_t i = 0; i < len; ++i) {
        ctx->data[ctx->datalen] = data[i];
        ctx->datalen++;
        if (ctx->datalen == 64) {
            sha256_transform(ctx, ctx->data);
            ctx->bitlen += 512;
            ctx->datalen = 0;
        }
    }
}

static void sha256_final(SHA256_CTX *ctx, uint8_t hash[]) {
    uint32_t i = ctx->datalen;
    if (ctx->datalen < 56) {
        ctx->data[i++] = 0x80;
        while (i < 56) ctx->data[i++] = 0x00;
    } else {
        ctx->data[i++] = 0x80;
        while (i < 64) ctx->data[i++] = 0x00;
        sha256_transform(ctx, ctx->data);
        memset(ctx->data, 0, 56);
    }
    ctx->bitlen += ctx->datalen * 8;
    ctx->data[63] = (uint8_t)ctx->bitlen;
    ctx->data[62] = (uint8_t)(ctx->bitlen >> 8);
    ctx->data[61] = (uint8_t)(ctx->bitlen >> 16);
    ctx->data[60] = (uint8_t)(ctx->bitlen >> 24);
    ctx->data[59] = (uint8_t)(ctx->bitlen >> 32);
    ctx->data[58] = (uint8_t)(ctx->bitlen >> 40);
    ctx->data[57] = (uint8_t)(ctx->bitlen >> 48);
    ctx->data[56] = (uint8_t)(ctx->bitlen >> 56);
    sha256_transform(ctx, ctx->data);
    for (i = 0; i < 4; ++i) {
        hash[i]    = (ctx->state[0] >> (24 - i * 8)) & 0xff;
        hash[i+4]  = (ctx->state[1] >> (24 - i * 8)) & 0xff;
        hash[i+8]  = (ctx->state[2] >> (24 - i * 8)) & 0xff;
        hash[i+12] = (ctx->state[3] >> (24 - i * 8)) & 0xff;
        hash[i+16] = (ctx->state[4] >> (24 - i * 8)) & 0xff;
        hash[i+20] = (ctx->state[5] >> (24 - i * 8)) & 0xff;
        hash[i+24] = (ctx->state[6] >> (24 - i * 8)) & 0xff;
        hash[i+28] = (ctx->state[7] >> (24 - i * 8)) & 0xff;
    }
}

static void sha256d(const uint8_t *in, size_t len, uint8_t out[32]) {
    uint8_t mid[32];
    SHA256_CTX ctx;
    sha256_init(&ctx); sha256_update(&ctx, in, len); sha256_final(&ctx, mid);
    sha256_init(&ctx); sha256_update(&ctx, mid, 32); sha256_final(&ctx, out);
}

static void wr_u32(uint8_t *p, uint32_t v) {
    p[0]=v&0xff; p[1]=(v>>8)&0xff; p[2]=(v>>16)&0xff; p[3]=(v>>24)&0xff;
}

/* Compare hash (SHA256d output) as little-endian uint256 <= target from compact bits */
static int hash_meets(const uint8_t hash[32], uint32_t nbits) {
    int exp = nbits >> 24;
    uint32_t mant = nbits & 0xffffff;
    uint8_t target[32];
    memset(target, 0, 32);
    if (exp >= 3 && exp <= 32) {
        int idx = exp - 3;
        /* place mantissa big-endian into target byte array at position from the right */
        /* Bitcoin compact: target is mantissa * 256^(exp-3), stored as 256-bit BE for display,
           but hash comparison uses arith_uint256 from LE hash bytes. */
        /* Build target as 32-byte BE, then compare hash BE. */
        if (idx < 30) {
            target[29 - idx] = (mant >> 16) & 0xff;
            target[30 - idx] = (mant >> 8) & 0xff;
            target[31 - idx] = mant & 0xff;
        }
    }
    /* hash is SHA256d digest in internal order; Bitcoin GetHash reverses for display.
       CheckProofOfWork uses UintToArith256(hash) where hash is uint256 from GetHash()
       which is the reversed digest... In Python we used int.from_bytes(digest,'little').
       digest little-endian int <=> digest bytes compared as reversed (BE) against BE target. */
    uint8_t hash_be[32];
    for (int i = 0; i < 32; i++) hash_be[i] = hash[31 - i];
    return memcmp(hash_be, target, 32) <= 0;
}

int main(int argc, char **argv) {
    if (argc < 5) {
        fprintf(stderr, "usage: %s <name> <ntime> <nbits_hex> <merkle_hex_le>\n", argv[0]);
        return 1;
    }
    const char *name = argv[1];
    uint32_t ntime = (uint32_t)strtoul(argv[2], NULL, 10);
    uint32_t nbits = (uint32_t)strtoul(argv[3], NULL, 16);
    const char *merkle_hex = argv[4];
    uint8_t merkle[32];
    if (strlen(merkle_hex) != 64) { fprintf(stderr, "merkle must be 64 hex chars\n"); return 1; }
    for (int i = 0; i < 32; i++) {
        unsigned int b;
        sscanf(merkle_hex + i*2, "%02x", &b);
        merkle[i] = (uint8_t)b;
    }

    uint8_t header[80];
    memset(header, 0, 80);
    wr_u32(header + 0, 1);           /* version */
    /* prev = 0 already */
    memcpy(header + 36, merkle, 32);
    wr_u32(header + 68, ntime);
    wr_u32(header + 72, nbits);

    printf("[%s] mining nbits=0x%08x ...\n", name, nbits);
    fflush(stdout);
    clock_t t0 = clock();
    uint8_t hash[32];
    for (uint32_t nonce = 0;; nonce++) {
        wr_u32(header + 76, nonce);
        sha256d(header, 80, hash);
        if (hash_meets(hash, nbits)) {
            double sec = (double)(clock() - t0) / CLOCKS_PER_SEC;
            printf("[%s] FOUND nonce=%u in %.2fs\n", name, nonce, sec);
            printf("hash_be=");
            for (int i = 31; i >= 0; i--) printf("%02x", hash[i]);
            printf("\n");
            return 0;
        }
        if ((nonce & 0x3fffff) == 0 && nonce) {
            double sec = (double)(clock() - t0) / CLOCKS_PER_SEC;
            printf("[%s] tried %u (%.0f H/s)\n", name, nonce, nonce / (sec > 0 ? sec : 1));
            fflush(stdout);
        }
        if (nonce == 0xffffffffu) break;
    }
    fprintf(stderr, "exhausted\n");
    return 1;
}
