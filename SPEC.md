# Le0 (LE0) — Frozen Spec

Status: locked for v0.2  
Last updated: 2026-11-05

## Identity
- **Name:** Le0
- **Ticker:** LE0
- **Address prefix:** addresses start with `L`
- **License:** MIT (open source)

## Economics
| Param | Value |
|--------|--------|
| Max supply | 100,000,000 LE0 |
| Premine | 0% |
| Block time | ~90 seconds |
| Block reward | 10 LE0 (flat until cap, then 0; genesis coinbase is 28 LE0 locked-in) |
| Mine-out | ~28 years at ~90s |
| Transfer burn | 1% of transferred value destroyed |
| Halving | none (flat emission) |

## Consensus / mining
- **PoW:** Yespower 1.0 (`N=2048`, `r=8`, pers=`Le0`) — CPU-leaning
- **Mining mode:** solo-first; **CPU + GPU simultaneous OK** (built-in CPU + external GPU via GBT)
- **Initial difficulty:** casual (`powLimit` `000fff…`, genesis `nBits=0x1f0fffff`)
- **Difficulty retarget:** every block, DigiShield-damped average of last ~12 intervals (tracks ~90s, no sharp stalls)
- **Coinbase maturity:** 20 blocks (~30 min) before spendable
- **Default node:** pruned (casual install ~10GB-class target)

## Platform
- **Primary:** Windows (node + wallet + one-click starter)
- **Seed nodes:** operator-run (`Start-Le0-Seed.bat`); IP in `release/seeds.txt` + baked into binary
- **Solo mine flag:** `-mineaddress=L...` (also used by `Start-Le0.bat`)

## Release stance
- Fair launch: seed online first, then publish `release\` zip — no genesis premine
- Official wallet first; Trust Wallet / Wallet Core later; Coinbase not a v0.1 goal

## Out of scope for v0.1
- Trust Wallet listing
- Exchange listings
- Domain / marketing site
- Mining pools
