# Unchecked subtraction underflow in Seamless LeverageToken pre-liquidation rebalance

**Protocol:** Seamless Protocol — leverage-tokens (leveraged positions over Morpho Blue)
**Contract:** `PreLiquidationRebalanceAdapter.sol`
**Severity:** Low (fail-closed; no funds at risk; permissionless workaround; narrow reachable band)
**Status:** Found during independent review. Protocol announced wind-down (UI offline
2026-06-30); published as a portfolio write-up rather than a live disclosure.
**Verification:** Foundry mainnet fork PoC, block 25,881,451 — 8/8 tests passing, reproduced locally.

---

## Summary

`PreLiquidationRebalanceAdapter.isStateAfterRebalanceValid` bounds the equity a
rebalancer may take with an **unchecked** subtraction:

```solidity
return stateAfter.equity >= stateBefore.equity - maxEquityLoss;
```

Under Solidity 0.8.x, when `stateBefore.equity < maxEquityLoss` this subtraction
underflows and reverts with `Panic(0x11)`. Because the check is invoked from
`LeverageManager.rebalance`, the entire rebalance reverts — including a **pure repay**
that strictly improves the position and takes nothing out.

`getEquityInDebtAsset()` clamps equity to 0 once collateral ≤ debt, so this state is
reached exactly when a token is at or near insolvency — the one situation where a
good-faith deleveraging repay is most needed.

## Root cause

The bound should express "equity did not drop by more than `maxEquityLoss`." Written as
`stateBefore.equity - maxEquityLoss`, it underflows for small `stateBefore.equity`
instead of evaluating to a satisfiable condition. A saturating subtraction (or an
additive reformulation) expresses the same intent without underflow.

## Impact and scope (measured on fork, not assumed)

Fork: Ethereum mainnet, block 25,881,451, against the live RLP-USDC-6.75x LeverageToken
(at that block: collateral $157,889 / debt $3,055,904 / equity 0 / CR 0.0517).

- A **1 USDC pure-repay** rebalance reverts with `Panic(0x11)` on the live insolvent state.
- The exact survival boundary is `WAD / r` = **45 wei** of USDC for this token, where
  `r = liquidationPenalty * rebalanceReward / REWARD_BASE`. Repays ≤ 45 wei succeed
  (maxEquityLoss floors to 0); ≥ 46 wei revert.
- The reachable band is narrow: the equity bound binds before the ratio cap only for
  `CR < target*(1+r)/(target+r)` — ≈ 1.00319 on this token, ≈ 1.00021 on the 25x token.
  Above that the ratio cap binds first and there is no underflow. (Binary-searched on
  fork; matches the closed form to 9 decimals.)
- It self-heals: one legal (small) repay lifts CR out of the band in a single step.

## What this is NOT (honest severity)

- It does **not** brick the Dutch-auction `take()` path. That path also removes
  collateral, which Morpho rejects first with `"insufficient collateral"` on an
  insolvent position — the underflow never executes there. (Verified on fork: `take()`
  reverts with the Morpho string, not the arithmetic panic.)
- No funds are at risk; nothing is permanently locked.
- **Permissionless escape hatch:** `MorphoLendingAdapter.repay` carries no
  `onlyLeverageManager` modifier (it is `external` with no access control), so anyone
  can donate a repayment directly to the adapter, lift the position out of the band, and
  the normal rebalance path then works. (`removeCollateral` *is* gated — so the open
  pair can only help, never harm.)

These are why the finding is Low rather than a griefing/DoS of consequence.

## Proof of concept

Foundry fork test (8 passing) demonstrates: the revert through the real entrypoint, the
exact 45-wei boundary, the narrow brick zone (binary-searched to the closed form), that
`take()` is stopped by Morpho rather than the underflow, the permissionless escape hatch,
and that the full mechanism works once out of the band (keeper take lands exactly at the
`maxEquityLoss` bound — independently confirming the reward arithmetic).

```
[PASS] test_F01_realRebalanceRevertsWithPanic          rebalance([Repay 1 USDC]) -> Panic(0x11)
[PASS] test_F01_boundaryIsFloorOfMaxEquityLoss         45 wei survives, 46 wei reverts
[PASS] test_F01_takePathOnInsolventToken               take() -> Morpho "insufficient collateral"
[PASS] test_F01_brickZone_boundary                     underflow reachable for CR < 1.003187975287437438
[PASS] test_F01_brickZone_equityBoundBindsFirst        ratio-legal repay above equity cap -> Panic(0x11)
[PASS] test_F01_brickZone_upperEdge                    ratio cap binds first higher up (no underflow)
[PASS] test_F01_escapeHatch_directRepayThenRebalanceWorks   ungated adapter.repay rescues; rebalance then succeeds
[PASS] test_F01_profitableRebalanceWorksAfterRescue    post-rescue take == maxEquityLoss bound (21920668 == 21920668)
```

Full test: `test/poc/F01_EquityBoundUnderflow.t.sol`.

## Suggested fix (one line)

```solidity
// additive reformulation (no underflow):
return stateAfter.equity + maxEquityLoss >= stateBefore.equity;

// or a saturating subtraction:
return stateAfter.equity >= Math.saturatingSub(stateBefore.equity, maxEquityLoss);
```

Either allows the strictly-improving repay through instead of reverting when
`stateBefore.equity` is below `maxEquityLoss`.

## Notes

Found via manual scoping (narrowing the rebalance-adapter surface to the pre-liquidation
equity-bound seam) plus tool-assisted sweep, then fork-verified by hand. Two initially
over-stated claims (that it bricks `take()`, and a wider brick zone) were corrected by the
fork tests and are reflected accurately above.
