// Copyright (c) 2026 The Le0 developers
// Distributed under the MIT software license, see the accompanying
// file COPYING or http://www.opensource.org/licenses/mit-license.php.

#include <node/le0_solo_mine.h>

#include <addresstype.h>
#include <common/args.h>
#include <consensus/consensus.h>
#include <consensus/merkle.h>
#include <interfaces/mining.h>
#include <key_io.h>
#include <logging.h>
#include <node/context.h>
#include <node/miner.h>
#include <pow.h>
#include <primitives/block.h>
#include <sync.h>
#include <util/signalinterrupt.h>
#include <util/threadnames.h>
#include <validation.h>

#include <atomic>
#include <chrono>
#include <cmath>
#include <limits>
#include <memory>
#include <mutex>
#include <thread>

namespace {

std::atomic<bool> g_le0_mine_stop{false};
std::thread g_le0_mine_thread;

std::atomic<uint64_t> g_hashes_total{0};
std::atomic<uint64_t> g_blocks_found{0};
std::atomic<uint64_t> g_blocks_rejected{0};

bool Interrupted(ChainstateManager& chainman)
{
    return g_le0_mine_stop || bool(chainman.m_interrupt);
}

// Do NOT AllocConsole() on Windows. Closing that console sends CTRL_CLOSE and
// kills the whole le0-qt process — which is why mining looked like it "just
// stopped" after a while. Stats go to debug.log only.
void PrintMineLine(const std::string& line)
{
    LogPrintf("%s\n", line);
}

std::string FormatHashrate(double hps)
{
    char buf[64];
    if (hps >= 1e6) {
        std::snprintf(buf, sizeof(buf), "%.2f MH/s", hps / 1e6);
    } else if (hps >= 1e3) {
        std::snprintf(buf, sizeof(buf), "%.2f kH/s", hps / 1e3);
    } else {
        std::snprintf(buf, sizeof(buf), "%.2f H/s", hps);
    }
    return buf;
}

bool MineOneBlock(node::NodeContext& node, const CScript& coinbase_script,
                  uint64_t& hashes_since_report, const std::chrono::steady_clock::time_point& start,
                  std::chrono::steady_clock::time_point& last_report)
{
    if (!node.mining || !node.chainman) return false;
    interfaces::Mining& miner = *node.mining;
    ChainstateManager& chainman = *node.chainman;

    std::unique_ptr<node::CBlockTemplate> templ = miner.createNewBlock(coinbase_script);
    if (!templ) {
        PrintMineLine("le0-mine: createNewBlock failed — retrying");
        return false;
    }

    CBlock& block = templ->block;
    block.hashMerkleRoot = BlockMerkleRoot(block);
    const int height = WITH_LOCK(chainman.GetMutex(), return chainman.ActiveHeight()) + 1;
    const uint32_t nBits = block.nBits;

    while (!Interrupted(chainman)) {
        // Yespower hash check
        const bool found = CheckProofOfWork(block.GetHash(), block.nBits, chainman.GetConsensus());
        ++hashes_since_report;
        g_hashes_total.fetch_add(1, std::memory_order_relaxed);

        const auto now = std::chrono::steady_clock::now();
        if (now - last_report >= std::chrono::seconds(10)) {
            const double elapsed = std::chrono::duration<double>(now - start).count();
            const double window = std::chrono::duration<double>(now - last_report).count();
            const double hps_window = window > 0 ? hashes_since_report / window : 0.0;
            const double hps_avg = elapsed > 0 ? g_hashes_total.load() / elapsed : 0.0;
            char line[512];
            std::snprintf(line, sizeof(line),
                          "le0-mine: %s (avg %s) | height~%d | nBits=0x%08x | hashes=%llu | blocks=%llu accepted / %llu rejected",
                          FormatHashrate(hps_window).c_str(),
                          FormatHashrate(hps_avg).c_str(),
                          height,
                          nBits,
                          static_cast<unsigned long long>(g_hashes_total.load()),
                          static_cast<unsigned long long>(g_blocks_found.load()),
                          static_cast<unsigned long long>(g_blocks_rejected.load()));
            PrintMineLine(line);
            hashes_since_report = 0;
            last_report = now;
        }

        if (found) {
            break;
        }
        if (block.nNonce == std::numeric_limits<uint32_t>::max()) {
            return false;
        }
        ++block.nNonce;
    }

    if (Interrupted(chainman)) return false;

    auto block_out = std::make_shared<const CBlock>(block);
    bool new_block = false;
    if (!miner.processNewBlock(block_out, &new_block)) {
        g_blocks_rejected.fetch_add(1, std::memory_order_relaxed);
        PrintMineLine("le0-mine: BLOCK REJECTED " + block_out->GetHash().ToString());
        return false;
    }
    if (!new_block) {
        // Already had this block — do not treat as a new reward.
        return false;
    }
    // Force disk flush so a hard kill / crash cannot roll the tip backwards
    // and turn just-mined rewards into orphans (empty Transactions history).
    WITH_LOCK(chainman.GetMutex(), chainman.ActiveChainstate().ForceFlushStateToDisk());
    g_blocks_found.fetch_add(1, std::memory_order_relaxed);
    const int tip = WITH_LOCK(chainman.GetMutex(), return chainman.ActiveHeight());
    char line[512];
    std::snprintf(line, sizeof(line),
                  "le0-mine: *** BLOCK FOUND *** height=%d hash=%s | total blocks=%llu | reward=10 LE0 (immature until %d confs)",
                  tip,
                  block_out->GetHash().ToString().c_str(),
                  static_cast<unsigned long long>(g_blocks_found.load()),
                  COINBASE_MATURITY);
    PrintMineLine(line);
    return true;
}

void Le0MineThread(node::NodeContext* node, CScript coinbase_script, std::string address)
{
    util::ThreadRename("le0-mine");
    const auto start = std::chrono::steady_clock::now();
    auto last_report = start;
    uint64_t hashes_since_report = 0;

    PrintMineLine("============================================================");
    PrintMineLine("  Le0 solo miner (Yespower)");
    PrintMineLine("  address: " + address);
    PrintMineLine("  Stats every 10s in debug.log (no extra console — closing one used to kill mining).");
    PrintMineLine("============================================================");

    // Do NOT wait for IBD. On a solo/new chain the tip can look "stale"
    // (genesis age) forever, which would block mining forever.
    bool logged_ibd = false;
    while (node && node->chainman && !Interrupted(*node->chainman)) {
        if (!logged_ibd && node->mining && node->mining->isInitialBlockDownload()) {
            PrintMineLine("le0-mine: tip marked IBD (normal for a new solo chain) -- mining anyway");
            logged_ibd = true;
        }
        if (!MineOneBlock(*node, coinbase_script, hashes_since_report, start, last_report)) {
            std::this_thread::sleep_for(std::chrono::milliseconds(50));
        }
    }
    PrintMineLine("le0-mine: stopped");
}

} // namespace

void StartLe0SoloMine(node::NodeContext& node)
{
    StopLe0SoloMine();
    if (!gArgs.IsArgSet("-mineaddress")) return;

    const std::string addr = gArgs.GetArg("-mineaddress", "");
    const CTxDestination dest = DecodeDestination(addr);
    if (!IsValidDestination(dest)) {
        LogPrintf("le0-mine: invalid -mineaddress=%s (not mining)\n", addr);
        return;
    }

    g_le0_mine_stop = false;
    g_hashes_total = 0;
    g_blocks_found = 0;
    g_blocks_rejected = 0;
    CScript script = GetScriptForDestination(dest);
    g_le0_mine_thread = std::thread(&Le0MineThread, &node, std::move(script), addr);
}

void InterruptLe0SoloMine()
{
    g_le0_mine_stop = true;
}

void StopLe0SoloMine()
{
    g_le0_mine_stop = true;
    if (g_le0_mine_thread.joinable()) {
        g_le0_mine_thread.join();
    }
    g_le0_mine_stop = false;
}
