# Le0 (LE0)

CPU-leaning **Yespower** PoW coin — Bitcoin Core–based. Fair launch, no premine.

**Website:** https://le0-coin.vercel.app  
**Source:** https://github.com/Le0Coin/Le0-Coin  
**Downloads (Windows):** Wallet + Miner packs on the website (Google Drive links)

## Quick start
1. Download the **Wallet** or **Miner** pack from the website.
2. Unzip and run the Start script in the pack.
3. For mining: use a wallet address and leave the miner connected.
4. Keep your **12-word seed** offline.

## Economics
| | |
|--|--|
| Max supply | **100,000,000 LE0** |
| Block reward | **10 LE0** (flat, then 0) |
| Block time | **~90 seconds** |
| Premine | **0%** |
| Transfer burn | **1%** |
| Addresses | start with **L** / `le0` |

## Specs (short)
- **PoW:** Yespower 1.0 (`N=2048`, `r=8`, personalization `Le0`)
- **Mining:** built-in solo; pools not required
- **Maturity:** 20 confirmations before coinbase is spendable
- Full detail: **[SPEC.md](SPEC.md)** · mining notes: **[doc/MINING.md](doc/MINING.md)**

## Build from source
MSVC: see `build_msvc/README.md`.

## License
MIT
