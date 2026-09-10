# Harbor's Aqua / SwapVM strategy

Harbor subclasses the pinned official `AquaSwapVMRouter`, adding two local
instructions without changing upstream accounting, VM execution or token transfers.
The unmodified official router cannot execute this program.

## Ownership

| Component | Responsibility |
| --- | --- |
| `HarborProgram.sol` | Vault maker traits, authenticated Book hooks and canonical program. |
| `instructions/HarborPricing.sol` | Ask Book to compute live prices; preserve the specified register and fill the other. |
| `instructions/HarborClaimGuard.sol` | Canonical pending custody and exactly one whole receipt. |
| `HarborSwapVMRouter.sol` | Local dispatch, delegating every other opcode to upstream. |
| `../book/base/BookPricing.sol` | Parameter authority and shared public/execution pricing path. |
| `../libraries/StandingPricing.sol` | Live state and independent economic gates. |
| `../libraries/PricingMath.sol` | Pure potential, conservative rounding and bounded inversion. |
| `../book/base/BookSettlement.sol` | Authenticate context and verify measured token deltas. |

Book modules share one BookState. Linked libraries have explicit storage references
and immutable compiler linkage; none has an independent portfolio ledger.

## Program and payload

```text
Salt(version) -> HarborPricing(book, route, strategyVersion)
             -> HarborClaimGuard(receipt, factory, factoryVersion) [receipts only]

Pricing instruction:
[0,1)   opcode 0x57
[1,2)   argument length 84
[2,22)  packed Book address
[22,54) uint256 route
[54,86) uint256 strategy version

Remaining taker arguments: abi.encode(Trade), exactly 13 ABI words / 416 bytes.
No FillTerms, bespoke quote signature or report.

Receipt guard:
opcode 0x56, length 96, abi.encode(receipt, factory, factoryVersion)
```

These are Harbor-local opcode assignments, unused by the pinned upstream dispatch.
Recheck collisions on dependency upgrades. The old 0x55 program is not retained.
Router capability getters prevent accidental binding to an old implementation;
deployment provenance and runtime verification are still required.

The vault calls Aqua `ship`, or docks/replaces an old order with a fresh salt.
The router is Aqua's registered application. Price updates do not re-ship orders;
allocation replenishment or mandate replacement can still require a refresh.
Aqua allocations bound transfers, but never override Book's shared cash/risk limits.

## Pricing and registers

Book takes the trader's intent and verifies current parameters, nominal FACE,
independent valuation, cash, reserves, inventory, public bounds and issuer budgets.
The pricing kernel computes the pair, including customer exactness and fees.
The opcode itself does not implement a second rounding convention.

| VM field | Exact input | Exact output |
| --- | --- | --- |
| amountIn | Validate and preserve | Set computed input |
| amountOut | Set computed output | Validate and preserve |
| balanceIn, balanceOut, query, fees, nextPC | Preserve | Preserve |

Both amounts must be positive. The pricing instruction consumes all remaining
taker arguments. No fee/amount transformation follows it in the canonical program;
Book hooks bind the computed pair. The guard changes no registers.

A static quote invokes Book using STATICCALL, even if the router was invoked by
a normal call. Quote computation cannot write persistent or transient state.
Execution uses CALL and binds the computed amount pair to the active lock.

## Settlement lifecycle

```text
Executor: caller == trade.trader; read live amounts
  -> checkpoint independent NAV if needed
  -> open Book/Vault lock [OPENED]
  -> collect exactly computed customer input
Router pricing -> Book recomputes and binds pair [AUTHORIZED]
Router/Aqua input -> Book measures vault credit [INPUT_RECEIVED]
Book authorizes output [OUTPUT_AUTHORIZED]
Router/Aqua output -> Book measures debit and records position [OUTPUT_SENT]
Executor checks pair/hash, zeros allowance, pays fee/customer, rejects residue
Book/Vault reconcile actual cash and clear all transient context [IDLE]
```

The Book verifies router, maker, executor taker, order hash, route/versions,
tokens, amount mode and canonical payload. The context hash identifies the exact
intent within this transaction; it is not a signature or a durable nonce.
Any failure rolls back transfers and accounting together. Repeated identical
caller-authenticated intents are legal new trades when live limits permit them.

The receipt guard checks factory identity/version, issuer, chain, recovery token,
pending NFT custody and one-unit amount. Book repeats the relevant checks before
recording final settlement. Finalized/cash-ready rights recover, but do not trade
through this initial pending-right program.

## Low-level code and tests

Three bounded `calldataload` operations parse the packed authority/route/version.
The 84-byte length check precedes every load; the last word ends at byte 84.
The 20-byte address is shifted explicitly. Assembly reads calldata only.
Typed transient storage owns cross-call locks; durable balances/nonces remain
ordinary auditable storage. Arithmetic uses full-precision reviewed primitives.

```sh
forge test --match-path 'test/swapvm/*.t.sol' -vv
forge test --match-contract StandingTradingTest -vvvv
forge test --match-contract RedemptionMarketTest -vvvv
forge test --match-contract PricingTest -vv
```

Five instruction regressions cover parsing against a readable reference,
register preservation, static-write rejection, whole-unit quantity and late
rollback. Core tests exercise actual Aqua transfers, the shared kernel, all
four modes, exposure-driven repricing and late payout failure.
These are focused hackathon checks, not an exhaustive VM audit.

See the [demo](../../DEMO.md) and [test scope](../../README.md#development-and-testing).
Use fresh router/core deployments and orders; no old signed-fill ABI is supported.
