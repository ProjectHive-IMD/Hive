# How $HIVE rewards work

Our fees buy AI agents that work 24/7 and earn **IMD**. That IMD flows back to $HIVE holders. There are **two ways to earn, and you never have to lock your tokens to earn something.**

---

## 💎 Just hold (soft‑stake)

Keep $HIVE in your **own wallet**. That's it. You earn a share of the **holder pot** automatically — no staking, no locking, full freedom to trade whenever you want.

It's "soft" because nothing leaves your wallet. Your reward is worked out from **how much you hold and how long you hold it** — so:

- Hold steady → earn steadily.
- Sell → you simply stop earning on what you sold. The "link" breaks itself, because the chain shows the tokens left.

Technically this is a **time‑weighted average balance (TWAB)** over the whole period, not a single‑moment snapshot. That one design choice is what makes it fair (see "Why it can't be farmed" below).

## 🔒 Stake (optional — earns more)

Lock your $HIVE in [`HiveStaking`](src/HiveStaking.sol) and you earn the **extra 60% bonus pot** on top of your 40% holder slice, plus a **loyalty multiplier** that grows the longer you stay:

| Time staked | Multiplier |
|---|---|
| < 7 days | 1.00× |
| ≥ 7 days | 1.25× |
| ≥ 30 days | 1.50× |
| ≥ 90 days | 2.00× |

For the believers who want maximum yield and are happy to lock.

## The split: 40 / 60, base + bonus, fixed in code

Every batch of IMD is split by [`HiveRewardRouter`](src/HiveRewardRouter.sol):

- **40% → a pot every holder shares** — staked or not (your staked $HIVE counts too)
- **60% → an extra pot only stakers share**

So a **staker earns the 40% holder slice AND the 60% staker bonus**; a **non‑staking holder earns the 40% slice**. Everyone who holds earns something; staking is a bonus on top — you never have to lock to earn. This is a `constant` with **no owner and no setter** — the team cannot change it.

Later, the tokens our seats earn from identity.md launches go to **long‑time stakers** as an added loyalty bonus (staked ≥ a set time) — so the "time bonus" rewards conviction on top of the 60%.

---

## Why the holder pot can't be farmed

The holder slice is computed off‑chain and committed on‑chain as a **merkle root** (see [`HiveMerkleDistributor`](src/HiveMerkleDistributor.sol)). The snapshot is hardened three ways:

1. **TWAB, not a snapshot.** Rewards count *time held*, so nobody can buy a giant bag one block before a snapshot, grab a reward, and dump. Loyalty can't be faked. This is also what makes "if it moves, the link breaks" literally true.
2. **A floor.** A wallet must average at least a minimum balance over the period to be eligible. This kills dust and makes sybil‑splitting pointless — the pot is strictly pro‑rata by balance, so splitting one bag across many wallets never helped anyway, and below the floor each shard earns zero.
3. **Exclusions + staked counts.** Infrastructure never receives a slice: the bonding curve, the liquidity pool, the fee splitter, the treasury, the router, and the burn address. The **staking contract's** balance isn't orphaned — it's **attributed back to the individual stakers** (from the on‑chain stake/unstake events), so a staker's staked $HIVE counts toward their 40% holder slice too, with no double‑counting.

## Why the distribution is trust‑minimised

The contract guarantees, on‑chain, that:

- **Conservation** — a round can only reserve funds already in the contract; nothing can be double‑spent or over‑committed.
- **Correct destination** — a claim always pays the address encoded in the merkle leaf, never whoever submits the transaction. That's why anyone (the keeper) can **push** your slice to you and you don't have to do anything.
- **No double claim** — each holder is paid at most once per round.
- **No drain** — there is no owner withdrawal. The only non‑claim outflow is sweeping a round's *unclaimed* remainder to the treasury, and only after a long delay.

The only thing left to trust is *"the published holder list is honest"* — and that's **publicly recomputable**: anyone can rebuild the merkle root from the on‑chain $HIVE transfer history using the same rules and check it matches. For extra safety a round isn't claimable until a delay passes, and an optional **guardian** can cancel a bad round during that window (it can only cancel — it can never move funds).

## Verify a distribution yourself

1. Take the round's block window and rules (TWAB, floor, exclusion list) — all public.
2. Replay $HIVE `Transfer` events **and `HiveStaking` stake/unstake events** over that window from an archive RPC, and compute each holder's TWAB of **wallet + staked** balance.
3. Rebuild the merkle tree (leaf = `keccak256(keccak256(abi.encode(account, amount)))`, sorted‑pair parents) and compare the root to the one the contract emitted in `RoundOpened`.

If it matches, every holder got exactly what the rules say — no more, no less.

---

*Rewards depend on the seats actually earning IMD, which is variable and operator‑driven. Nothing here guarantees a yield. Not financial advice.*
