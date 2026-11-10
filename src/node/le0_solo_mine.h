// Copyright (c) 2026 The Le0 developers
// Distributed under the MIT software license, see the accompanying
// file COPYING or http://www.opensource.org/licenses/mit-license.php.

#ifndef BITCOIN_NODE_LE0_SOLO_MINE_H
#define BITCOIN_NODE_LE0_SOLO_MINE_H

namespace node {
struct NodeContext;
}

/** Start background Yespower solo mining to -mineaddress if set. */
void StartLe0SoloMine(node::NodeContext& node);
/** Signal mining thread to exit (non-blocking). */
void InterruptLe0SoloMine();
/** Join mining thread (idempotent). */
void StopLe0SoloMine();

#endif // BITCOIN_NODE_LE0_SOLO_MINE_H
