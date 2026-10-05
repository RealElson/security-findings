# Case Study: Live-Priced Redemption Lets a Pending Request Front-Run the Settlement

*Anonymized write-up. Protocol name, addresses, and runnable exploit code are withheld because the issue was disclosed privately and the fix status is pending. The mechanism below is described conceptually, for educational and track-record purposes only.*

## Summary

A two-step redemption queue priced each payout on the **live** backing ratio at execution time rather than on the ratio captured when the redemption was requested. A holder with a pending request could donate assets to the backing pool just before settlement to inflate the ratio — and therefore their own payout — then have the inflated amount paid out to them.

## The setting

The redemption flow had two steps:
1. **Request** (permissionless): a holder locks shares and joins a redemption queue.
2. **Execute** (owner-only): the operator processes the queue and pays each requester a basket of underlying assets.

Payout per requester was computed as a function of the backing pool's composition — effectively `(requester's share) × (current backing / current supply)`.

## The defect

The payout was priced on the pool's **spot balance ratio at execute time**. Nothing captured the ratio at request time. So the figure that determined how much a requester received was still mutable *after* they had committed to redeeming, right up until the operator's execute transaction landed.

The implicit assumption — "the backing ratio at execution reflects honest pool state" — ignored that anyone can change a pool's spot balance by simply sending it tokens.

## Why it is exploitable

A holder with a pending request front-runs the operator's execute transaction with a plain token donation to the backing pool. The donation inflates the numerator of the backing ratio. When execute then prices the payout on that freshly inflated ratio, the requester receives far more than their honest share. In a proof of concept on a local fork, a donation inflated a single requester's payout to roughly **11× the honest amount** — via an ordinary transfer, no approval, no privileged role, with the inflated payout routed to the original requester.

## Severity reasoning

Rated **Medium**, and deliberately not higher, for two honest reasons:
- The execute step is operator-gated, so this is a *front-run of a benign privileged transaction*, not a fully self-triggered atomic exploit — the attacker needs the operator to call execute in the window after the donation.
- Crucially, the payout path was **live-when-funded**: at the time of review the backing pool held no pending real assets, so the bug was proven and real but not yet triggerable in production. The write-up stated this plainly and did **not** overclaim it as a live drain. A proven mechanism on an empty pool is a latent Medium, not an active theft — saying so protects credibility.

## The fix

Lock the payout basis — the gross claim and the outstanding supply figures (or the resulting per-asset amounts) — **at request time**, and reuse those locked values at execute. Once a requester has committed, their payout should be fixed; later changes to the pool's spot balance must not move it.

## Takeaway

Any redemption, withdrawal, or settlement that prices on *live* pool state at execution is exposed to donation/balance manipulation by anyone who can transfer a token into that pool. The defense is to snapshot the pricing basis at the moment of commitment, not at the moment of settlement. The general question: *between the user committing and the protocol paying, can anyone move the number the payout depends on?* If yes, lock it at commitment.
