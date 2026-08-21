# Firelight — FTSO adapter reports FastUpdater-global liveness as per-feed `updatedAt`, defeating the protocol's only staleness check

**Severity:** Medium (Critical on impact; discounted for likelihood — no attacker-controlled trigger)
**Type:** Oracle freshness / stale-price
**Components:** `FtsoChainlinkAdapter`, `lib/PriceFeed`
**Affected downstream:** `CoverOrderAllocator._computeAvailableCapacity`, `IncidentManager._executePayout`
**Status:** Reviewed as an independent security review of an audit-competition codebase. Finding is a property of the code as written; both legs reproduced against the project's own test harness on a forked network. No claim of a live incident or exploited deployment.

> This is a public write-up of a finding I produced during a review of the Firelight on-chain cover protocol (an audit competition codebase intended for deployment/upgrade on Flare mainnet). It is published for portfolio purposes. The runnable exploit harness is intentionally **not** included; the mechanism, the root-cause trace, and the reproduction approach are described in full so the finding can be independently verified from the source.

---

## Summary

Firelight prices cover payouts and collateral capacity off a Flare FTSO v2 feed, read through a Chainlink `AggregatorV3`-compatible adapter. The protocol's only real freshness guard is a single check in `PriceFeed.getPrice`:

```
block.timestamp - updatedAt > maxAge  →  revert
```

Everything else next to it is inert: the round-integrity check compares two values that are assigned equal, and `getRoundData` reverts, so there is no historical cross-check. The whole defense rests on `updatedAt`.

The adapter copies `updatedAt` verbatim from the timestamp FTSO returns. That timestamp does **not** mean "when this feed's value last changed." It means "when the FastUpdater contract last received any submission for anything." A single feed can therefore be frozen indefinitely — its value unchanged for hours — while `updatedAt` keeps tracking wall-clock time, and `maxPriceAge` never fires.

A stale price feeds directly into two value paths, in opposite directions, so **whichever way the market moves during a freeze, one side is harmed**: a feed frozen *below* market over-pays claims; a feed frozen *above* market over-authorises cover capacity against collateral that isn't there.

---

## Root cause

Tracing what FTSO's returned timestamp actually is, against the exact Flare revision the repo pins (`flare-smart-contracts-v2 @ 0b90381`):

`getFeedByIdInWei → _getFeedById → _getFeedByIndex → FastUpdater.fetchCurrentFeeds`, which sets the returned timestamp from `FastUpdater._getLastSubmissionTs()`:

```solidity
function _getLastSubmissionTs() internal view returns (uint64) {
    if (backlogDelta == currentDelta)                 return lastSubmissionTs;
    else if (numOfUpdatesInBlock[block.number] > 0)   return uint64(block.timestamp);
    else                                              return lastDaemonizeTs;
}
```

Every input to that function is **global to the FastUpdater contract and not indexed by feed**:

| State                 | Scope                        |
|-----------------------|------------------------------|
| `lastSubmissionTs`    | contract-wide                |
| `lastDaemonizeTs`     | contract-wide                |
| `numOfUpdatesInBlock` | keyed by **block**, not feed |
| `currentDelta`        | contract-wide                |
| `backlogDelta`        | contract-wide                |

A provider that updates some feeds and not others submits a "no change" delta for the rest — the ordinary encoding, nothing malformed. The returned timestamp advances; the individual feed's value does not. `block.timestamp - updatedAt` stays near zero regardless. **`maxPriceAge` is unenforceable at feed granularity — it detects only a FastUpdater-wide outage.**

The adapter is not fabricating a timestamp (it forwards FTSO's real value); the defect is *which event* that timestamp marks.

---

## Impact

Firelight is a cover protocol; its solvency condition is that collateral backing outstanding cover ≥ cover written. The stale price bears on both sides:

- **Liability side** — `_computeAvailableCapacity` values staked collateral at the oracle price. A feed frozen **above** market inflates available capacity, so cover the protocol's own solvency check would reject at the true price is accepted at the frozen price — and the inflated commitment persists after the price corrects.
- **Asset side** — `_executePayout` divides a USD-denominated loss by the same price. A feed frozen **below** market makes the vault hand over proportionally more asset units than the claim is worth, permanently depleting the collateral backing everyone else's cover.

Both directions push toward the same end state (under-collateralisation), and nothing in the Firelight code bounds how long a feed may be frozen, so neither the divergence nor the loss is bounded by the protocol.

---

## Proof of concept (approach and results)

The finding was reproduced against the real `IncidentManager` and `CoverOrderAllocator` on a forked network. The reproduction was designed to be **non-circular**, which is the crux for any oracle-staleness claim:

The repo's own FTSO mock lets a test set `(value, timestamp)` independently — so a PoC built on it would simply *assert* a stale timestamp and prove nothing. Instead, the harness **ports Flare's own `FastUpdater` timestamp state machine** (line-for-line against the pinned revision) and lets *that* logic derive every timestamp from ordinary, well-formed provider submissions. The only input the test controls is *which feeds each submission moves*. No timestamp is ever set by hand.

Representative results:

**Freshness defeated.** A feed held unchanged for 2 hours under a 1-hour `maxPriceAge` is accepted with a reported age of ~122 seconds, while its raw stored value is bit-identical to two hours prior. Divergence at that point: ~16%.

**Timestamp proven global (the decisive test).** After the freeze, all submissions stop and time advances. The guard now fires — and fires for *both* feeds simultaneously, including one that was healthy moments earlier. A per-feed timestamp could not produce that; only a contract-global one can.

**Payout leg (through the real `IncidentManager`).** Two identical claims, same block, differing only in which adapter is installed. The stale (low) feed pays ~16% more asset units than the true price would — a direct loss to LP capital, measured end-to-end.

**Capacity leg (through the real `CoverOrderAllocator`).** The on-chain capacity is bracketed (a commit at capacity+1 wei reverts; at exactly capacity it succeeds), so the figure is validated by the contract rather than assumed. Cover writable at the frozen price is then shown to be rejected by the protocol's own solvency check at the true price, and the inflated commitment is shown still standing after the price converges back to market — the contract holding a figure it would itself now reject.

---

## Severity

Priced on **impact**, the outcome — under-collateralised cover and depleted claim reserves — is the protocol-insolvency class. On **likelihood**, there is no attacker-controlled trigger: realisation requires FTSO fast-update provider-set degradation or per-feed censoring, an external liveness condition, not an action anyone takes on demand. Stating that plainly: priced on impact it is Critical; under a likelihood discount, Medium is the defensible landing point. I do not argue an attacker trigger, because there isn't one.

---

## Recommended mitigation

1. **Cross-check the fast-update value against the anchor (block-latency) feed**, which is anchored each voting epoch — this detects a frozen feed that global liveness cannot.
2. **Add a per-feed deviation / heartbeat check** in `PriceFeed`: persist the last observed `(answer, timestamp)` per adapter and reject when the value hasn't moved across a window in which it demonstrably should have.
3. **Bound `maxPriceAge`** with a sane ceiling (the consumers reject only `0` today).
4. **Correct the adapter documentation** — nothing tells an integrator that `updatedAt` measures FastUpdater liveness rather than per-feed freshness, which is exactly what makes the `PriceFeed` check look sufficient.

Fixing the inert round-integrity check is *not* a mitigation for this — it addresses a separate reporting defect and would not detect the frozen-feed condition.

---

## Key lesson (generalizable)

When an adapter maps a non-Chainlink oracle onto `latestRoundData`, don't stop at *"is the timestamp real?"* — ask **what event does the timestamp actually mark, and at what granularity?** A real, honestly-forwarded timestamp for the *wrong event* silently defeats a correct-looking staleness check. The bug is invisible from the consuming protocol's code alone; it only surfaces by reading the upstream dependency at its pinned revision instead of trusting its interface.
