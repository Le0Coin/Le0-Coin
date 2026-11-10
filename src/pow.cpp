// Copyright (c) 2009-2010 Satoshi Nakamoto
// Copyright (c) 2009-2022 The Bitcoin Core developers
// Copyright (c) 2026 The Le0 developers
// Distributed under the MIT software license, see the accompanying
// file COPYING or http://www.opensource.org/licenses/mit-license.php.

#include <pow.h>

#include <arith_uint256.h>
#include <chain.h>
#include <primitives/block.h>
#include <uint256.h>

#include <algorithm>

namespace {

/** How many recent post-genesis intervals Le0 averages when retargeting. */
constexpr int LE0_RETARGET_LOOKBACK = 17;

unsigned int Le0NextWorkRequired(const CBlockIndex* pindexLast, const CBlockHeader* pblock,
                                 const Consensus::Params& params)
{
    const arith_uint256 bnPowLimit = UintToArith256(params.powLimit);
    const unsigned int nProofOfWorkLimit = bnPowLimit.GetCompact();

    // Keep genesis difficulty until we have real mined intervals (skip genesis→1).
    if (pindexLast->nHeight < 2) {
        return pindexLast->nBits;
    }

    // If the tip went stale (network quiet / miner closed), ease back to min
    // difficulty so solo / small-network mining can recover instead of looking
    // "stuck" for hours at an unreachable target.
    if (pblock && pblock->GetBlockTime() > pindexLast->GetBlockTime() + params.nPowTargetSpacing * 6) {
        return nProofOfWorkLimit;
    }

    // Only average intervals AFTER genesis. The genesis timestamp is years earlier
    // than block 1; even a *4 clamp on that gap kept difficulty too low and
    // produced multi-block bursts instead of ~90s.
    const int nPast = std::min(LE0_RETARGET_LOOKBACK, pindexLast->nHeight - 1);
    assert(nPast >= 1);

    // LWMA: weight recent intervals more so hashrate changes track ~90s quickly.
    int64_t nWeightedTimespan = 0;
    int64_t nWeightSum = 0;
    const CBlockIndex* curr = pindexLast;
    for (int i = 0; i < nPast; ++i) {
        assert(curr && curr->pprev);
        if (curr->pprev->nHeight < 1) {
            break; // never include genesis→block1
        }
        int64_t dt = curr->GetBlockTime() - curr->pprev->GetBlockTime();
        const int64_t lo = params.nPowTargetSpacing / 4;
        const int64_t hi = params.nPowTargetSpacing * 4;
        if (dt < lo) dt = lo;
        if (dt > hi) dt = hi;
        const int64_t w = static_cast<int64_t>(nPast - i); // i=0 most recent → heaviest
        nWeightedTimespan += dt * w;
        nWeightSum += w;
        curr = curr->pprev;
    }
    if (nWeightSum <= 0) {
        return pindexLast->nBits;
    }

    // avgDt / targetSpacing  →  adjust previous target
    const int64_t nTargetTimespan = nWeightSum * params.nPowTargetSpacing;

    arith_uint256 bnNew;
    bnNew.SetCompact(pindexLast->nBits);
    bnNew *= nWeightedTimespan;
    bnNew /= nTargetTimespan;

    // Hard clamp vs previous target (±4x) so a burst of fast blocks cannot
    // spike difficulty into "looks frozen" territory for a single CPU miner.
    arith_uint256 bnPrev;
    bnPrev.SetCompact(pindexLast->nBits);
    arith_uint256 bnMax = bnPrev * 4;
    arith_uint256 bnMin = bnPrev / 4;
    if (bnMin == 0) bnMin = 1;
    if (bnMax > bnPowLimit) bnMax = bnPowLimit;
    if (bnNew > bnMax) bnNew = bnMax;
    if (bnNew < bnMin) bnNew = bnMin;

    if (bnNew > bnPowLimit) {
        bnNew = bnPowLimit;
    }
    if (bnNew == 0) {
        return nProofOfWorkLimit;
    }
    return bnNew.GetCompact();
}

} // namespace

unsigned int GetNextWorkRequired(const CBlockIndex* pindexLast, const CBlockHeader *pblock, const Consensus::Params& params)
{
    assert(pindexLast != nullptr);
    unsigned int nProofOfWorkLimit = UintToArith256(params.powLimit).GetCompact();

    // Le0: every-block retarget with multi-block average (~90s).
    if (params.DifficultyAdjustmentInterval() == 1) {
        return Le0NextWorkRequired(pindexLast, pblock, params);
    }

    // Only change once per difficulty adjustment interval
    if ((pindexLast->nHeight+1) % params.DifficultyAdjustmentInterval() != 0)
    {
        if (params.fPowAllowMinDifficultyBlocks)
        {
            // Special difficulty rule for testnet:
            // If the new block's timestamp is more than 2* 10 minutes
            // then allow mining of a min-difficulty block.
            if (pblock->GetBlockTime() > pindexLast->GetBlockTime() + params.nPowTargetSpacing*2)
                return nProofOfWorkLimit;
            else
            {
                // Return the last non-special-min-difficulty-rules-block
                const CBlockIndex* pindex = pindexLast;
                while (pindex->pprev && pindex->nHeight % params.DifficultyAdjustmentInterval() != 0 && pindex->nBits == nProofOfWorkLimit)
                    pindex = pindex->pprev;
                return pindex->nBits;
            }
        }
        return pindexLast->nBits;
    }

    // Go back by what we want to be 14 days worth of blocks
    int nHeightFirst = pindexLast->nHeight - (params.DifficultyAdjustmentInterval()-1);
    assert(nHeightFirst >= 0);
    const CBlockIndex* pindexFirst = pindexLast->GetAncestor(nHeightFirst);
    assert(pindexFirst);

    return CalculateNextWorkRequired(pindexLast, pindexFirst->GetBlockTime(), params);
}

unsigned int CalculateNextWorkRequired(const CBlockIndex* pindexLast, int64_t nFirstBlockTime, const Consensus::Params& params)
{
    if (params.fPowNoRetargeting)
        return pindexLast->nBits;

    // Limit adjustment step
    int64_t nActualTimespan = pindexLast->GetBlockTime() - nFirstBlockTime;
    if (nActualTimespan < params.nPowTargetTimespan/4)
        nActualTimespan = params.nPowTargetTimespan/4;
    if (nActualTimespan > params.nPowTargetTimespan*4)
        nActualTimespan = params.nPowTargetTimespan*4;

    // Retarget
    const arith_uint256 bnPowLimit = UintToArith256(params.powLimit);
    arith_uint256 bnNew;

    // Special difficulty rule for Testnet4
    if (params.enforce_BIP94) {
        // Here we use the first block of the difficulty period. This way
        // the real difficulty is always preserved in the first block as
        // it is not allowed to use the min-difficulty exception.
        int nHeightFirst = pindexLast->nHeight - (params.DifficultyAdjustmentInterval()-1);
        const CBlockIndex* pindexFirst = pindexLast->GetAncestor(nHeightFirst);
        bnNew.SetCompact(pindexFirst->nBits);
    } else {
        bnNew.SetCompact(pindexLast->nBits);
    }

    bnNew *= nActualTimespan;
    bnNew /= params.nPowTargetTimespan;

    if (bnNew > bnPowLimit)
        bnNew = bnPowLimit;

    return bnNew.GetCompact();
}

// Check that on difficulty adjustments, the new difficulty does not increase
// or decrease beyond the permitted limits.
bool PermittedDifficultyTransition(const Consensus::Params& params, int64_t height, uint32_t old_nbits, uint32_t new_nbits)
{
    if (params.fPowAllowMinDifficultyBlocks) return true;

    // Le0 every-block average retarget: allow any change within a single 4x step
    // from the previous block's nBits (matches Le0NextWorkRequired dampening).
    if (params.DifficultyAdjustmentInterval() == 1) {
        if (height < 1) {
            return old_nbits == new_nbits;
        }
        const arith_uint256 pow_limit = UintToArith256(params.powLimit);
        arith_uint256 observed_new_target;
        observed_new_target.SetCompact(new_nbits);

        arith_uint256 largest;
        largest.SetCompact(old_nbits);
        largest *= 4;
        if (largest > pow_limit) largest = pow_limit;
        arith_uint256 maximum_new_target;
        maximum_new_target.SetCompact(largest.GetCompact());
        if (maximum_new_target < observed_new_target) return false;

        arith_uint256 smallest;
        smallest.SetCompact(old_nbits);
        smallest /= 4;
        if (smallest == 0) smallest = 1;
        arith_uint256 minimum_new_target;
        minimum_new_target.SetCompact(smallest.GetCompact());
        if (minimum_new_target > observed_new_target) return false;
        return true;
    }

    if (height % params.DifficultyAdjustmentInterval() == 0) {
        int64_t smallest_timespan = params.nPowTargetTimespan/4;
        int64_t largest_timespan = params.nPowTargetTimespan*4;

        const arith_uint256 pow_limit = UintToArith256(params.powLimit);
        arith_uint256 observed_new_target;
        observed_new_target.SetCompact(new_nbits);

        // Calculate the largest difficulty value possible:
        arith_uint256 largest_difficulty_target;
        largest_difficulty_target.SetCompact(old_nbits);
        largest_difficulty_target *= largest_timespan;
        largest_difficulty_target /= params.nPowTargetTimespan;

        if (largest_difficulty_target > pow_limit) {
            largest_difficulty_target = pow_limit;
        }

        // Round and then compare this new calculated value to what is
        // observed.
        arith_uint256 maximum_new_target;
        maximum_new_target.SetCompact(largest_difficulty_target.GetCompact());
        if (maximum_new_target < observed_new_target) return false;

        // Calculate the smallest difficulty value possible:
        arith_uint256 smallest_difficulty_target;
        smallest_difficulty_target.SetCompact(old_nbits);
        smallest_difficulty_target *= smallest_timespan;
        smallest_difficulty_target /= params.nPowTargetTimespan;

        if (smallest_difficulty_target > pow_limit) {
            smallest_difficulty_target = pow_limit;
        }

        // Round and then compare this new calculated value to what is
        // observed.
        arith_uint256 minimum_new_target;
        minimum_new_target.SetCompact(smallest_difficulty_target.GetCompact());
        if (minimum_new_target > observed_new_target) return false;
    } else if (old_nbits != new_nbits) {
        return false;
    }
    return true;
}

bool CheckProofOfWork(uint256 hash, unsigned int nBits, const Consensus::Params& params)
{
    bool fNegative;
    bool fOverflow;
    arith_uint256 bnTarget;

    bnTarget.SetCompact(nBits, &fNegative, &fOverflow);

    // Check range
    if (fNegative || bnTarget == 0 || fOverflow || bnTarget > UintToArith256(params.powLimit))
        return false;

    // Check proof of work matches claimed amount
    if (UintToArith256(hash) > bnTarget)
        return false;

    return true;
}
