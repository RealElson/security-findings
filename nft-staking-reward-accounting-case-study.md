# Reward-Accounting Failures in an NFT-Staking Protocol — A Case Study

*An anonymized security review write-up. The target is an EVM NFT-staking
contract deployed with real value at stake; identifying details are withheld
because the findings below concern an unpatched, live deployment. This write-up
is intended to document analysis method and finding classes, not to provide a
runnable exploit.*

---

## Summary

The contract lets holders stake NFTs and accrue a fungible reward token over
per-epoch reward rates. The staking and ownership accounting held up under
review — the value-moving paths are bound to the caller, and the usual
first-staker / donation-inflation and reentrancy concerns were checked and
found handled.

The problems live entirely in the **reward-rate accounting**: the epoch model
stores the reward rate in two places that are supposed to move together but
don't, and there is no invariant tying promised rewards to the tokens actually
available to pay them. Three medium-severity issues follow from that, each with
an honest account of *when* it bites — because the preconditions matter as much
as the mechanism.

Method: source review against the verified on-chain source, with the key
behaviours confirmed on a local fork of the deployment so the accounting claims
are demonstrated rather than asserted. Severities are stated conservatively and
each finding notes the exact condition under which it is (or isn't) reachable.

---

## Finding 1 — The administrative rate-change control is inert, and one form of it silently destroys rewards

**Severity: Medium**

The epoch's reward rate is written into two pieces of state when an epoch is
started. User reward accrual, however, reads only *one* of those two pieces.
The separate administrative "change the rate mid-epoch" entry point updates only
the *other* one — the copy that accrual never reads.

The consequence is two-layered:

- **The control is inert.** An operator who uses the mid-epoch rate-change
  function to slow or adjust emissions sees no effect on what stakers actually
  accrue, because accrual is reading the copy the function doesn't touch. A
  safety lever the contract appears to offer does nothing.

- **One specific use of it destroys value.** Driving the rate to zero via that
  same function freezes the global settlement accumulator while per-user
  liability keeps growing. At epoch finalization the shortfall is then
  *misclassified as surplus* and the corresponding reward tokens are burned.
  In a fork demonstration, exercising this path burned roughly 45% of the
  reward pool to the burn address; a control run without the rate change burned
  nothing.

**Honest scope.** This is not "any rate change burns tokens." A *partial*
downward change does not burn on an under-funded pool, because a later
re-charge step clamps the leftover to zero. The zero case reliably triggers the
burn; on a properly funded pool a partial cut triggers it too. The precondition
is narrow, but the mechanism is real and the safety control is genuinely
non-functional.

**Root cause.** Two sources of truth for one value, kept in sync on one write
path and not the other, with the consumer reading the path that the
administrative function ignores.

**Fix direction.** Collapse to a single source of truth for the epoch rate, or
have every rate-writing path update *both* copies and the settlement
accumulator together. The general lesson: if two storage locations are supposed
to represent the same fact, no code path may update one without the other.

---

## Finding 2 — No solvency invariant: an unpayable reward rate is accepted silently

**Severity: Medium**

Starting an epoch accepts a reward rate without any check that the pool holds
enough reward tokens to honour it. In the observed live state the configured
rate implied a liability on the order of a million times the tokens actually
available. Nothing reverts, emits, or exposes this at configuration time.

The downstream effect is a first-come settlement: the earliest claimant is paid
in full and later claimants find nothing left. Ordering, not entitlement,
decides who gets paid.

**Honest scope.** This is a *missing invariant*, not a drain or a theft. The
funding entry point is permissionless, so anyone can top the pool back up and —
in either claim order — make both parties whole. Framing it as "the contract is
broken" would overstate it. The real defect is that the contract will silently
accept a rate it cannot possibly pay, with no revert, no event, and no view that
surfaces the shortfall, so the condition is invisible until a claimant hits the
empty pool.

**Root cause.** Absence of a promised-vs-available check at the point where the
promise is made.

**Fix direction.** At epoch start, compare the total liability the rate implies
against the pool balance and either revert or emit a clear, queryable
under-funding signal. Make the shortfall observable *before* a user discovers it
at claim time.

---

## Finding 3 — A required per-transfer hook cannot be unset, so a future broken hook would permanently lock staked assets

**Severity: Medium (latent — currently unarmed)**

The contract calls an external hook on every relevant transfer. The setter for
that hook rejects the zero address, so once a hook is installed it can be
replaced but never removed. If a hook is ever set to an address that reverts or
becomes non-functional, every transfer path that invokes it reverts with it —
and because staked assets move through that path, they become permanently
locked. The dedicated rescue function routes through the same hook and so cannot
recover them either.

**Honest scope.** This is currently *unarmed*: no hook is set, so nothing is at
risk today. It is a "fix this before you ever use the feature" finding, not a
live exposure. Its severity is about the irreversibility of the failure mode, not
about a present danger.

**Root cause.** A removable dependency modelled as non-removable — the setter
forbids the one value (zero) that would represent "no hook."

**Fix direction.** Allow the hook to be cleared (permit the zero address as
"disabled"), or make the rescue path bypass the hook entirely so recovery is
always possible regardless of hook state.

---

## What generalizes

Three observations from this review that transfer to any staking or
reward-distribution system:

1. **Dual-write invariants are a rich bug class.** Whenever one logical value is
   stored in two places, audit every write path for whether it keeps them in
   sync — and audit the *consumer* to learn which copy actually matters. The
   dangerous case is a control that writes the copy nobody reads.

2. **"Promised" and "available" need an explicit invariant.** A reward system
   that lets an operator promise more than the pool can pay, with no check and
   no signal, has moved a solvency failure from configuration time (where it is
   cheap to catch) to claim time (where a user eats it).

3. **Irreversible dependencies deserve special scrutiny.** A required external
   call that can never be disabled turns any future failure of that dependency
   into a permanent lock. "Can this be turned off if it breaks?" is a question
   worth asking of every mandatory hook.

Preconditions were stated for each finding on purpose. A finding that reads as
"catastrophic, always" when it is really "value-destroying under a specific
operator action" or "latent until a feature is enabled" is worth less than one
that tells you exactly when it bites — because that is what a team needs to
decide what to fix first.
