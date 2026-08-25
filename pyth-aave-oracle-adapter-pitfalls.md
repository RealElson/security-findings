# Auditing the Oracle Path of an Aave V3 Fork: Four Ways a Pyth Adapter Bites

*An anonymized security-review write-up. The target is a live Aave V3 lending fork
on an EVM L2 that prices assets through a Pyth "pull" oracle behind a Chainlink-shaped
adapter. Identifying details are withheld because the primary finding concerns an
unpatched, live deployment. This documents method and finding classes, not a runnable
exploit against any specific protocol.*

---

## Why the oracle path was the whole audit

The lending core here is stock Aave V3 — one of the most heavily audited codebases in
existence. Auditing it line-by-line would have been auditing Aave, not the fork. The
value in a fork is always the *diff*: what the team changed or added that the base's
auditors never saw.

Here the diff was concentrated in one place. Aave V3 ships expecting Chainlink-style
*push* price feeds — feeds with a heartbeat, where freshness is the oracle's
responsibility. This fork instead priced everything through **Pyth**, a *pull* oracle,
wrapped in an adapter that presents Pyth data behind Chainlink's `AggregatorV3`
interface so the stock Aave oracle can read it unchanged.

That seam — a pull oracle dressed as a push oracle, feeding a consumer built for push
semantics — is where the entire audit lived. Four issues came out of it, in descending
order of how much they actually matter *for this deployment*.

---

## 1. No staleness bound anywhere in the price path (the live one)

**The mechanism.** The adapter's price accessors call Pyth's "unsafe" read — the variant
that, by name and design, returns the last stored price with no freshness check and no
revert on age. The stock lending oracle that consumes it, in turn, reads only the latest
answer and discards the feed's own timestamp. So *neither side* enforces a maximum price
age.

This is the crucial difference between a push and a pull oracle. A Chainlink feed carries
a heartbeat guarantee: someone is contractually keeping it fresh, so a consumer that
trusts it is usually fine. A Pyth feed is only as fresh as the last time *someone chose to
pay to push an update on-chain* — and nobody is obligated to. For a pull oracle, **stale
is the default state**, not a degraded edge case.

**Why it's real and not theoretical.** On the live deployment, the served price for
volatile assets was observed sitting several minutes to over half an hour old across
repeated samples, with updates arriving in irregular batches rather than on any tight
cadence. The most volatile listed collateral — a low-priced, high-beta token — was
collateral-enabled with a meaningful borrow allowance, and priced through exactly this
path. During a staleness window, that collateral is valued at a price the market has
already moved away from.

**Impact, stated honestly.** Windowed mispricing on volatile collateral: an actor can, in
a stale window, borrow against collateral valued stale-high (leaving bad debt), or affect
liquidations that should or shouldn't happen. The severity is **medium**, and the honest
bounding is what makes it credible: the window is *opportunistic* — an attacker exploits
market drift, they cannot force the price in a chosen direction; the staleness is
*permissionlessly refreshable* — anyone can push a fresh update to close the window; and
profit is *bounded by the volatile asset's liquidity*. It is not a drain, and calling it
one would be wrong.

**Fix.** Enforce a maximum age. Pyth exposes a "no older than" read that takes a max-age
argument; use it with a constructor-set heartbeat, or wrap the consuming oracle to check
the feed timestamp against a bound and revert when it is exceeded.

---

## 2. The confidence interval is thrown away

A Pyth price arrives with a **confidence interval** — the oracle's own statement of how
much it trusts the number, which widens during depegs, volatility spikes, and thin books.
The Chainlink interface the adapter mimics has nowhere to put that value, so it is
discarded entirely.

Staleness and confidence are *different* failure modes. A price can be seconds fresh and
still be one the oracle itself does not believe. Anything downstream of a
confidence-discarding adapter is structurally blind to that signal — it will treat a
high-uncertainty price with the same trust as a tight one. Lower severity than staleness
here, but the same root theme: a pull oracle carries risk metadata that a push-shaped
adapter silently drops on the floor.

---

## 3. A historical-round query that fabricates instead of reverting

The adapter implements the Chainlink `getRoundData(roundId)` call — the one that is
supposed to return a *specific past round* — by ignoring the requested round entirely,
returning today's price, and echoing the requested id back into the round fields. A caller
asking "what was the price at round N" receives the current price wearing a historical
label. Not a revert — a **silently wrong answer**.

For *this* deployment it does not bite, because the consuming oracle only ever reads the
latest price. That is exactly why it is reported as a low-severity note rather than a
live issue — the honest disposition depends on what actually consumes the adapter. But
the class is dangerous for any integrator that settles on a past round: options or perp
settlement at expiry, "compare to the previous round" circuit breakers, or loops that
walk back rounds looking for a non-zero answer. As a bonus, forcing the "answered-in-round
equals round" relationship also quietly defeats the legacy staleness check that compares
those two fields.

**The generalizable rule:** a data source that cannot answer a question should **revert**,
not fabricate. A revert is a bug report; a wrong number is a loss that surfaces far from
its cause.

---

## 4. Unchecked full-balance refund in the update function

The permissionless "push an update and refund my change" function refunds the *entire
contract balance* rather than the caller's actual overpayment, and does not check whether
the refund succeeded. In principle that lets value stranded in the contract (by a caller
whose refund reverts, or by force-sent ETH) be swept by the next caller.

On the live deployment this is currently **informational, not exploitable**: the contract
holds no balance and — confirmed on-chain — has never made an outbound call, so the
refund path has never executed and no value has ever been at risk. It is also not
attacker-profitable to *arm*: creating the precondition costs more than it returns, so it
is scavenging, not an exploit. Reported as hardening.

**The generalizable rule:** refund `msg.value - fee`, not `address(this).balance`; and
check the return value of every value-bearing external call. Two lines, and a whole class
of "next caller sweeps the pot" bugs disappears.

---

## What generalizes

Four issues, one root cause: **an adapter that translates between two oracle models drops
the safety metadata that the destination model assumes is someone else's job.** Push
oracles put freshness and trust on the *feed*; pull oracles put it on the *consumer*. Wrap
one as the other without carrying that responsibility across the seam, and you get exactly
this family — no staleness bound, discarded confidence, fabricated history, sloppy
value handling.

Three habits that catch all of it:

1. **On a fork, audit the diff, not the base.** The unaudited surface is whatever the team
   changed or added. Here it was the entire custom oracle path; the stock lending core was
   never the point.

2. **Price severity from live chain state, not from the mechanism.** Every claim above was
   graded against what the deployment actually does — measured staleness windows, the real
   collateral configuration, the contract's real balance and call history. The same code
   defect was a live medium in one place (staleness on volatile collateral) and a dormant
   informational in another (the refund bug that has never armed). The mechanism tells you
   a bug *exists*; only the chain state tells you whether it *bites*.

3. **A missing check is worth stating even when it currently can't fire.** The
   historical-round and refund issues don't bite this consumer today. They are still worth
   reporting, precisely bounded, because they bite the next integrator or the next config
   change — and an honest "present but not currently exploitable, here's exactly why" is
   more useful to a team than either silence or an overclaim.
