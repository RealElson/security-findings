# Deposit pause and per-token limits bypassable via alternate entry points

**Severity:** Medium
**Target:** Rhino.fi bridge — EVM contracts
**Status:** Reported, fixed

## Summary

The deposit pause and per-token maximum deposit limits were enforced
on `deposit()` and `depositNative()`, but not on three alternate
deposit entry points — including the paths the front end actually
calls. A paused bridge continued to credit deposits.

## Affected functions

- `depositWithId()`
- `depositWithPermit()`
- `depositNativeWithId()`

## Description

The contract exposes several deposit entry points. Two of them carry
the pause check and the per-token max-deposit check. The other three
do not, despite reaching the same accounting logic and emitting the
same credit events.

The unguarded functions are not edge cases — `depositWithId()` is a
primary UI path, so ordinary user traffic bypassed both controls by
default.

## Impact

- Deposits credited while the protocol believes itself paused
- Per-token deposit caps bypassed
- The pause is not a reliable safety control: an operator pausing in
  response to an incident would not actually stop inbound deposits

## Proof of concept

A four-test Foundry suite confirmed credit-while-paused via
`BridgedDepositWithId` event emission on a paused contract.

*PoC source available on request.*

## Recommended fix

Apply the pause and limit modifiers to every deposit entry point,
and add a test asserting each one reverts when the contract is
paused. Where several functions share accounting logic, route them
through a single internal function carrying the checks, so a new
entry point cannot be added without them.

## Note

The guard was on the right door. The attacker walks through a
different one.