# Le0 solo mining

## Algorithm
- **Yespower 1.0** (`N=2048`, `r=8`, personalization `"Le0"`)
- CPU-leaning (GPU can mine, but should not dominate a similar-tier CPU)
- Block reward: **10 LE0** (flat until 100M cap; genesis is 28 LE0 locked-in)
- Target block time: **~90 seconds** (network-wide)

## CPU + GPU at the same time
Yes. Run both against the same node:

1. **CPU (built-in)** — after `le0d` / `le0-qt` is running with a wallet address:
   ```text
   le0-cli generatetoaddress <nblocks> "<your L... address>"
   ```
   Or enable continuous generate via config/RPC as in Bitcoin Core (`setgenerate` / `-generate` style flows once the Windows build is up).

2. **GPU (external)** — point any Yespower-capable miner at your node’s **getblocktemplate** / submit RPC (port **37071**). CPU and GPU just add hashrate; still **one winner per block**.

No pool/Stratum software is shipped (solo-first).

## Notes
- Mining loads the CPU (and GPU if used) continuously — heat and power draw are expected.
- More total hashrate ⇒ more of your blocks over time; weak devices mine less, not equally.
