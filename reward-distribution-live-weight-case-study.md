# Case Study: Live-Weight Numerator Against a Frozen Denominator in a Round-Based Reward Distributor

*Anonymized write-up. Protocol name, addresses, and runnable exploit code are withheld because the issue was disclosed privately and the fix status is pending. The mechanism below is described conceptually, for educational and track-record purposes only.*

## Summary

A round-based reward distributor computed each participant's share using a numerator read **live** at distribution time while the denominator it divided against was **frozen** earlier in the round. The mismatch let a participant raise their own numerator after the denominator was locked, inflating their share at the expense of participants processed later in the same round.

## The setting

The protocol ran repeating "rounds." Each round:
1. Opened and tallied a snapshot of participants and a per-slot demand figure.
2. Froze certain round parameters at tally time (the denominators).
3. Later, in a separate distribution pass, credited each participant pro-rata from a fixed pot.

The intent was that a participant's share = (their weight) / (total weight), bounded by a per-slot cap, so the pot is divided fairly and the sum of credits never exceeds the pot.

## The defect

The distribution pass read each participant's weight **live** — by calling the current weight source at the moment of distribution — rather than reusing the weight snapshotted at tally. But the denominator it divided against (the per-slot demand figure, and a round-total weight snapshot used to size a secondary leg) was **frozen at tally / round-open**.

So the accounting mixed two clocks:
- Numerator: live, re-read during distribution.
- Denominator: frozen, captured earlier.

An invariant the code implicitly relied on — "the weights that make up the denominator are the same weights used as numerators" — was never enforced across the tally→distribute gap.

## Why it is exploitable

If a participant can raise their own live weight between tally and the moment distribution reaches them, their credited share rises super-proportionally: the numerator grows while the denominator stays fixed. Because a per-slot cap holds the *total* paid out, the excess is not minted from nowhere — it is taken from participants processed **after** the slot's pot is exhausted, who then receive zero. The round completes normally; the loss is silent, irreversible within the round, and repeatable every round.

The precondition is a permissionless, monotonic self-upgrade of one's own weight with no round/phase gate — a participant can raise their weight at any time, including mid-round, without privilege.

## Severity reasoning

Rated **Medium**, held against the instinct to call it High because "funds move." The honest magnitude check mattered:
- The loss is redistribution of a bounded per-round reward pot, not protocol principal and not a systemic solvency break.
- It is repeatable, which amplifies a Medium — but repeatability of a small, bounded theft is an amplifier, not a High trigger. High needs significant principal or systemic loss.

Reading the live on-chain magnitude of a round's pot (rather than assuming "funds move = High") pulled the severity to its true level. This is a recurring discipline: anchor severity on measured magnitude, not on the category of the bug.

## The fix

Snapshot each participant's weight **into the round at tally time**, and reuse that snapshot in the distribution and secondary legs. Never re-read a live weight in distribution while dividing against a frozen denominator. One clock for numerator and denominator.

## Takeaway

When a system freezes some round parameters and reads others live, the seam between "frozen" and "live" is where the accounting breaks. The question to ask of any pro-rata distributor: *is every number in this ratio captured at the same instant?* If the numerator and denominator come from different points in time, a participant who can move the live value in between extracts the difference — and the victims are whoever the loop reaches after the pot runs dry.
