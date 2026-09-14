# Unbounded per-deal share of an epoch reward budget — first-mover drain

*Anonymized case study. The protocol is a live peer-to-peer credit market on an EVM L2; because the issue was reported through the project's own bug bounty and remains unremediated at time of writing, no protocol name, addresses, or runnable exploit are included. The mechanism is described conceptually.*

## Context

The protocol pays a reward token to both sides of each credit "deal" (a borrower who pledges collateral and a lender who funds it). Rewards for a given week (an "epoch") are drawn from a fixed per-epoch, per-term **budget**. A permissionless `register(dealId)` function reads a funded deal, computes its reward, reserves that reward from the epoch budget, and opens two vesting streams — one to the borrower, one to the lender.

The intended economic model is that each deal earns roughly its fee scaled by an epoch rate, capped at a fraction of the fee, and that the budget is shared across the epoch's participants.

## The finding

`register()` bounds a single deal's reward only by `min(rateAmount, cap)` and then by the **budget remaining** for that epoch and term. Nothing bounds any *single* deal's share of the budget, and nothing bounds how many deals one address may register. Registration order is therefore the only thing that decides who receives rewards.

Combined with two other permissionless properties of the system:

- funding a deal lets the caller **name the lender**, so one actor can fund their own listing across two wallets they control; and
- the borrower may **reclaim collateral and principal immediately** after funding,

a single unprivileged actor can, at the start of an epoch, register a small number of self-funded deals whose combined reward reserves the **entire** epoch budget. Every honest borrower and lender who registers afterward in that epoch receives a reward of **zero**. The attacker's principal and collateral are never at risk — only the (small) deal fee is spent, and the reward streams vest and are collected later.

The result is a systemic **reward-denial** that also functions as a cheap griefing vector: one party captures or blocks the whole epoch's incentive budget, defeating the reason honest users participate.

## Why the cap doesn't save it

The system has an 80%-of-fee cap intended to make a self-dealt wash a guaranteed loss. In the live configuration the cap and the rate-based amount evaluate to the *same number*, so the cap never actually constrains the grant relative to the rate. The cap's protective value also depends on a manually-posted, unscaled price parameter that is carried forward indefinitely if left un-updated — so its safety degrades silently as the reward token's market price moves. These are contributing factors to how large a single grant can be, not independent issues.

## Evidence and severity

The mechanism was confirmed to have already occurred on-chain under the protocol's real launch configuration: a single registration consumed the large majority of an epoch's budget in one call, after which subsequent registrations returned "exhausted" and then zero — exactly the denial the analysis predicts, under honest (non-malicious) use.

Severity was assessed as **Medium**, not higher, on three honest grounds:

1. The drained asset is the epoch's unclaimed reward budget, not depositor principal or collateral.
2. At the chain head observed, the exploit yields nothing — the budget was already spent and later epochs carried a zero rate; it re-arms only under the launch-time configuration.
3. Extracted rewards must exit through a single thin liquidity pool, so the realisable value of a full-budget drain is far below its nominal (paper) value once price impact is accounted for.

A proof of concept reproduced both the drain (one actor reserving the whole epoch budget, honest participants then denied) and the dormancy (zero grant at chain head), against forked mainnet state, using only unprivileged externally-owned accounts.

## Lessons for reviewers

- **A per-epoch budget is not a per-participant bound.** Any permissionless function that reserves from a shared pool in call order, with no cap on a single caller's share, is a first-mover / denial vector. Look for the missing per-address or per-item limit, not just for a direct theft path.
- **"Permissionless registration" plus "caller names the counterparty" plus "immediate reclaim" is a self-dealing kit.** Each is innocuous alone; together they let one actor play both sides at zero principal risk.
- **A cap that equals the thing it caps is not a cap.** When a bound and the value it bounds reduce to the same expression under live parameters, the protection is cosmetic — check the arithmetic at deployed values, not just in the spec.
- **Value the impact at what can be *realised*, not at spot × supply.** A drain of a reward token that can only exit through a shallow pool is worth a fraction of its nominal figure; honest severity follows the realisable number.
- **Reproduce the dormant case too.** Showing that the exploit yields zero at current head, and only arms under a specific (real) configuration, is part of an honest severity claim — not something to hide.
