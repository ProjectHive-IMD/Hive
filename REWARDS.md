# How $HIVE rewards work

Our fees buy AI agents that work 24/7 and earn **IMD**. That IMD flows back to $HIVE holders. There are **two ways to earn, and you never have to lock your tokens to earn something.**

---

## 💎 Just hold

Keep $HIVE in your **own wallet** (or staked — staked $HIVE counts too). At each payout, every wallet holding **at least 10,000 $HIVE** gets a share of the **holder pot**, in proportion to its balance. It's **pushed straight to your wallet** — nothing to claim, nothing to lock, full freedom to trade.

Sell, and you simply don't get a share for what you sold. The reward for holding *over time* lives on the staking side (below).

## 🔒 Stake (optional — earns more)

Lock your $HIVE in [`HiveStaking`](src/HiveStaking.sol) and you earn the **extra 60% bonus pot** on top of your 40% holder slice, plus a **loyalty multiplier** that grows the longer you stay:

| Time staked | Multiplier |
|---|---|
| < 7 days | 1.00× |
| ≥ 7 days | 1.25× |
| ≥ 30 days | 1.50× |
| ≥ 90 days | 2.00× |

There's no minimum stake and no lock-up: unstake any time, instantly, with no fee. Your staker share is paid into the staking contract and you **claim** it whenever you like on [projecthive.fun/stake](https://projecthive.fun/stake).

## The split: 40 / 60, base + bonus, fixed in code

Every batch of IMD is split by [`HiveRewardRouter`](src/HiveRewardRouter.sol):

- **40% → a pot every holder shares** — staked or not (your staked $HIVE counts too)
- **60% → an extra pot only stakers share**

So a **staker earns the 40% holder slice AND the 60% staker bonus**; a **non‑staking holder earns the 40% slice**. Everyone who holds earns something; staking is a bonus on top. The split is a `constant` with **no owner and no setter** — the team cannot change it.

Later, the tokens our seats earn from identity.md launches go to **long‑time stakers** as an added loyalty bonus — so time staked is rewarded on top of the 60%.

---

## How the holder slice is worked out

The holder slice is computed off‑chain and committed on‑chain as a **merkle root** (see [`HiveMerkleDistributor`](src/HiveMerkleDistributor.sol)). For each payout:

1. **Balance at the snapshot.** Each wallet's $HIVE balance **plus its staked $HIVE** at the snapshot. The staking contract's balance is attributed back to the individual stakers, so staking never costs you your holder slice and nothing is counted twice.
2. **A 10,000 $HIVE minimum.** Wallets below it get nothing. This keeps dust out, and because the pot is strictly pro‑rata, splitting one bag across many wallets never earns more.
3. **Infrastructure is excluded — people aren't.** No slice goes to: the Uniswap v4 PoolManager (pool liquidity), the Pons bonding curve, the Pons launch locker (`0x267444D099b10fB5Ed7c3Cc7B7c767AdcA574952`), `HiveStaking` (attributed back to stakers), the fee splitter, the treasury, the router, the distributor, the $HIVE token contract, the zero/burn addresses, and one non‑wallet routing contract (`0x00000000Cf1cD5867BE5D90B99A6EBd683BC031c`). **Smart‑account wallets** (EIP‑7702 / account‑abstraction wallets, which many Robinhood Chain users have) are real holders and **are included**.
4. **Exact amounts.** Each wallet gets `pot × its balance ÷ total eligible balance`, with the last wei handed out by largest remainder so the round sums to the pot exactly.

## Why the distribution is trust‑minimised

The contract guarantees, on‑chain, that:

- **Conservation** — a round can only reserve funds already in the contract; nothing can be double‑spent or over‑committed.
- **Correct destination** — a claim always pays the address encoded in the merkle leaf, never whoever submits the transaction. That's why the keeper can **push** your slice to you and you don't have to do anything.
- **No double claim** — each holder is paid at most once per round.
- **No drain** — there is no owner withdrawal. The only non‑claim outflow is sweeping a round's *unclaimed* remainder to the treasury, and only after 180 days.

The contract also supports a claim delay during which an optional **guardian** can cancel a bad round (it can only cancel, never move funds). The live distributor was deployed with that delay set to **0**, so payouts are instant — which makes the published list below the thing to check.

## Verify a distribution yourself

Every round's full list (wallet, amount, merkle proof) is published in [`rounds/`](rounds/).

1. Rebuild the merkle tree from the list — leaf = `keccak256(bytes.concat(keccak256(abi.encode(account, amount))))`, sorted‑pair parents (OpenZeppelin `StandardMerkleTree`) — and check the root matches the one the contract emitted in `RoundOpened`.
2. Check the pushes on‑chain: every amount in the list was paid to that address.
3. Spot‑check any wallet: its amount should be `pot × (its balance + stake) ÷ total eligible` under the rules above.

**Round 0 (2 Oct 2026):** 14 IMD to 610 wallets, root `0x82a9358353a6dbcfd1ed5a982f15f00804edca0d5851b4055768c017ca8b5838`. Balances were read from the Robinhood Chain explorer at about 23:00 UTC that day, so no exact block was recorded for this first round. The list is in [`rounds/round-0.json`](rounds/round-0.json).

---

*Rewards depend on the seats actually earning IMD, which is variable and operator‑driven. Nothing here guarantees a yield. Not financial advice.*
