# Oakmont Two-Token Protocol — Security Review

**Scope:** SOAK, StakedOakmontToken, OakmontLending, BasketVault (Robinhood Chain, ID 4663)
**Perspective:** Unprivileged attacker
**Methodology:** Source review, bytecode disassembly (unverified contracts), and forked-mainnet proof-of-concept
**Date:** 2026-08-16
**Result:** 1 Medium · 4 Informational · 0 Critical / High / Low

---

## Scope

| Contract | Address | Role |
|---|---|---|
| SOAK | `0x8d6FF05c40899bFbC618e203052A8cd02D0e9581` | ERC4626 vault / share token |
| OakmontLending | `0xb4F7306DcF8A89EcD94c7a8Af24046be3294F506` | Credit engine (currently inert) |
| StakedOakmontToken | `0xa3bbfeb83cf2e2dd75b58c14cb6de7818d023ecf` | Collateral / staked token |
| BasketVault | `0x9c61D093a0a31547e5040126B5b8542804ED902c` | Two-step redemption queue (unverified source) |

---

## OAK-M-01 · Redemption payout is priced at execution, allowing a donation front-run

**Severity:** Medium
**Contract:** `BasketVault.executeRedeem(uint256)`
**Manipulated value:** `StakedOakmontToken.previewBasketClaim` spot ratio
**Status:** Mechanism confirmed via forked-mainnet PoC. Not exploitable on mainnet in the protocol's current (unfunded) state — see *Applicability*.

### Summary

`BasketVault` redeems sTKN for a proportional slice of nine held basket assets in two steps: `requestRedeem` (permissionless; transfers the caller's sTKN into the vault) and `executeRedeem` (owner-only; pays out). The payout is recomputed from live on-chain state at execution rather than fixed when the request is created. Because the underlying ratio can be moved by an unpermissioned token transfer, an attacker holding a pending request can inflate their own payout by donating tokens immediately before the owner's `executeRedeem` transaction lands.

### Mechanism

`executeRedeem` calls `StakedOakmontToken.consumeBasketClaim(shares)` and uses its live return values directly:

```
payout[i]     = basketBalance[i] * grossTknClaim * (1 - 500/10000) / outstandingTknSupply
grossTknClaim = shares * StakedOakmontToken.balanceOf(tkn) / StakedOakmontToken.totalSupply()
```

Both operands on the right are read at execution time, not locked at request time. A plain `transfer()` of the underlying token into `StakedOakmontToken` — callable by anyone, no approval, no role — moves the ratio instantly.

### Proof of concept

Reproduced on a Foundry `anvil` fork of Robinhood Chain mainnet. Two `executeRedeem` runs from an identical snapshot, with a pending 100-sTKN request:

| | Baseline | After 5,000 TKN donation |
|---|---|---|
| Backing (TKN) | 500.000 | 5,500.000 |
| `grossTknClaim` | 50.000 | 550.000 |
| Payout / asset (wei) | 47,500,000,000,000 | 522,500,000,000,000 |

The donation cost 34,180 gas (plain transfer). The inflated payout — **11.0x the honest amount** — was paid to the original requester on a real mined transaction, confirming the manipulated value is what settles.

### Applicability (current state)

At the time of review, `StakedOakmontToken` and `BasketVault` are unfunded on mainnet: zero staked shares, zero basket balances, no pending requests. The PoC therefore constructs the required state on the fork to exercise the flow. **The flaw is not exploitable today for lack of funds.** It becomes live as soon as redemptions carry real basket assets. This is reported now, pre-funding, so the fix can precede any value being placed at risk.

### Impact

Every other sTKN holder's proportional claim on the vault's real basket assets (tokenized equities) is diluted — measurable value loss, not a fee. Funds are not frozen; a live redemption's value is skewed.

### Severity rationale

Capped at Medium rather than High: `executeRedeem` is owner-only, so this is a *front-run of a benign owner transaction*, not a self-triggered or flash-loanable exploit. The donation and the execution must be two transactions from two senders; the attacker's donated capital sits at genuine risk across the window (the ratio can revert, the owner may delay, the attacker can be sandwiched).

### Recommended fix

Lock `grossTknClaim` / `outstandingTknSupply` — or the resulting per-asset amounts — at `requestRedeem` time, when the caller's shares are already in and no specific pending execution exists to target. Recomputing the ratio live inside `executeRedeem` is the root cause; the rest of the two-step design is sound.

---

## Informational

- **INF-01 — SOAK trusts its own transfer amount.** `wrap()` mints against the stated `oakAmount` with no balance-delta check; safe only while the underlying is a standard, non-fee token.
- **INF-02 — No slippage guard on liquidity deposits.** `depositLiquidity` / `fundLiquidity` are the only value-moving entrypoints across all four contracts without a min-output parameter. (Donation front-run math walked; not extractable.)
- **INF-03 — Fee rounding direction.** `StakedOakmontToken`'s wrap/unwrap fee leg rounds down (user-favoring) where SOAK's rounds up (protocol-favoring); dust-bounded.
- **INF-04 — BasketVault has no published source.** Verifying it would let future reviews start from source rather than disassembly.

---

## Methodology note

Reviewed contracts were audited against unprivileged-attacker misuse: value conservation, share-price manipulation, reentrancy, access control, fee-on-transfer handling, and checkpoint ordering. Per-contract "ruled out" detail available on request. No mainnet state was modified during this review — all dynamic testing ran on a local fork.
