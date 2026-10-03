# 🐝 Project Hive — contracts

**$HIVE** is a memecoin on **Robinhood Chain** with a job: its trading fees buy **identity.md** AI‑agent NFT "seats," those seats work 24/7 and earn **IMD**, and that IMD flows back to $HIVE holders. This repo is the on‑chain half — every contract in the money path, so you can read exactly how it works instead of taking our word for it.

> **Don't trust — verify.** The split of fees and rewards is fixed in code. There is no owner, no admin key, and no setter that can change who gets what. All six contracts below are live and **source‑verified on [Sourcify](https://sourcify.dev)** (creation and runtime bytecode both match), so the source here is provably what's running on‑chain.

## The flywheel

```
$HIVE trade  ──►  fee (Pons v2)  ──►  HiveSplitter  ──►  seat treasury ──► buy identity.md seats
                                          │                                   │
                                          ├── ops (running costs)             ▼
                                          └── team                      seats earn IMD
                                                                              │  (bridged to Robinhood Chain)
                                                                              ▼
                                                                      HiveRewardRouter  (immutable 40 / 60)
                                                                         ├── 40% → HiveMerkleDistributor (every holder, staked or not)
                                                                         └── 60% → HiveStaking      (extra, stakers only)
```

Two ways to earn, and you never have to lock to earn *something* — see **[REWARDS.md](REWARDS.md)** for the full mechanics (loyalty staking, soft‑stake TWAB for holders, and why the holder pot can't be farmed).

## Contracts

| Contract | What it does | Chain | Status |
|---|---|---|---|
| [`HiveSplitter`](src/HiveSplitter.sol) | Immutable fee router: claims Pons escrow ETH, splits seat / ops / team | Robinhood Chain | **live** — `0xCFd95537953236E7885f450F001b00960F496bC2` |
| [`HiveStaking`](src/HiveStaking.sol) | Stake $HIVE, earn IMD, loyalty multiplier (1×→2×) | Robinhood Chain | **live** — `0x4a56860781f90Cd4d9D9883b33c2B9bE94E88695` |
| [`HiveRewardRouter`](src/HiveRewardRouter.sol) | Immutable 40/60 split of IMD: 40% every holder / 60% stakers bonus | Robinhood Chain | **live** — `0x8D709c9B0c2978e8dB816f4bb81B53bcab4DD3af` |
| [`HiveMerkleDistributor`](src/HiveMerkleDistributor.sol) | The all‑holders pot: one merkle round per payout, pushed to every eligible holder (or self‑claimed) | Robinhood Chain | **live** — `0x650Ab04Fa554d8C7146103473D4d5bd30232D22C` |
| [`SeatBuyer`](src/SeatBuyer.sol) | The flywheel's seat‑buyer — capped + collection‑checked, so the keeper (or an autonomous bot) can only ever buy identity.md seats into the vault, never move funds anywhere else | Ethereum | **live** — `0x35705a8bc1c5e6854db9a06f8eb33b2218c0ca67` |
| [`HivePotPusher`](src/HivePotPusher.sol) | EIP‑7702 delegate for the treasury wallet: lets the buying bot move the seat pot **only** to `SeatBuyer` on Ethereum (via Across), with a fee cap and deadline bounds — nowhere else | Robinhood Chain | **live** — `0x35705a8bc1c5e6854db9a06f8eb33b2218c0ca67`, delegated by the treasury `0x84b31CB3D205EfD2d20F29eA7ccaB1bc34326DdB` |

**$HIVE token:** `0xCdaE63D95D6dd4f89f6e508c77bD4388b4e5C8Ab` · **Explorer:** https://robinhoodchain.blockscout.com/address/0xCdaE63D95D6dd4f89f6e508c77bD4388b4e5C8Ab

Look up any address above on [sourcify.dev](https://sourcify.dev) (or the Robinhood Chain explorer's *Contract* tab) to see the verified source. `SeatBuyer` is on Ethereum (chain 1); the rest are on Robinhood Chain (4663).

## Why it's trustworthy by construction

- **Immutable splits.** `HiveSplitter` (fees) and `HiveRewardRouter` (rewards) have their percentages as `constant`s and no owner. The team cannot change the cut, ever.
- **No custody of your tokens for the holder slice.** The soft‑stake / holder pot never asks you to lock or move anything. Your $HIVE stays in your wallet.
- **Non‑custodial distribution.** `HiveMerkleDistributor` can only pay the address encoded in each merkle leaf, can never pay out more than it holds, and has no owner‑withdraw. Each round's root is recomputable by anyone from public data.
- **Enforced, capped buying.** Seat purchases run through `SeatBuyer`: it fills identity.md listings only up to an immutable price ceiling and forwards every seat straight to the vault — so the automated buyer (or a compromised keeper) can never overpay or divert funds. It's live: seats #10 and #11 were bought through it, each in under 30 seconds from confirm to vault.
- **The pot can only go one place.** The seat pot sits in the treasury wallet on Robinhood Chain. Its EIP‑7702 delegate, `HivePotPusher`, lets the buying bot send it **only** to `SeatBuyer` on Ethereum, with a fee cap and deadline bounds — the bot never holds the treasury key and can't send the pot anywhere else.
- **Fully tested.** `forge test` (62 tests) covers conservation (no wei created or lost), double‑claim protection, over‑commit protection, the guardian veto, the 40/60 split, SeatBuyer's cap and vault delivery, and the pot pusher's send‑only‑to‑SeatBuyer rules.

## Build & test

```bash
forge install foundry-rs/forge-std OpenZeppelin/openzeppelin-contracts
forge build
forge test
```

## Disclaimers

- **Unaudited.** These contracts have not had a third‑party audit. Read them yourself. Use at your own risk.
- **Rewards depend on the seats actually earning IMD.** The identity.md network's payouts are variable and operator‑driven; nothing here guarantees any yield.
- **Not financial advice.** $HIVE is a memecoin. Nothing in this repo is an offer, a promise of profit, or investment advice.
