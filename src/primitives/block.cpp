// Copyright (c) 2009-2010 Satoshi Nakamoto
// Copyright (c) 2009-2019 The Bitcoin Core developers
// Copyright (c) 2026 The Le0 developers
// Distributed under the MIT software license, see the accompanying
// file COPYING or http://www.opensource.org/licenses/mit-license.php.

#include <primitives/block.h>

#include <streams.h>
#include <tinyformat.h>

#include <cstdlib>
#include <cstring>

extern "C" {
#include <crypto/yespower/yespower.h>
}

static const char LE0_YESPOWER_PERS[] = "Le0";

uint256 CBlockHeader::GetHash() const
{
    // Yespower 1.0, N=2048, r=8 (~2 MiB) — CPU-leaning PoW for Le0.
    static const yespower_params_t params = {
        YESPOWER_1_0,
        2048,
        8,
        (const uint8_t*)LE0_YESPOWER_PERS,
        sizeof(LE0_YESPOWER_PERS) - 1,
    };

    DataStream ss{};
    ss << *this;

    uint256 thash;
    if (yespower_tls(reinterpret_cast<const uint8_t*>(ss.data()), ss.size(), &params,
                     reinterpret_cast<yespower_binary_t*>(&thash)) != 0) {
        // Out of memory or internal error — cannot continue safely.
        std::abort();
    }
    return thash;
}

std::string CBlock::ToString() const
{
    std::stringstream s;
    s << strprintf("CBlock(hash=%s, ver=0x%08x, hashPrevBlock=%s, hashMerkleRoot=%s, nTime=%u, nBits=%08x, nNonce=%u, vtx=%u)\n",
        GetHash().ToString(),
        nVersion,
        hashPrevBlock.ToString(),
        hashMerkleRoot.ToString(),
        nTime, nBits, nNonce,
        vtx.size());
    for (const auto& tx : vtx) {
        s << "  " << tx->ToString() << "\n";
    }
    return s.str();
}
