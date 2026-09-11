# Harbor's Aqua / SwapVM strategy

Harbor uses the pinned official AquaSwapVMRouter without a dispatch override.
HarborSwapVMRouter is only a deployment alias. Its canonical strategy uses
official Extruction to invoke the immutable Book's custom pricing logic.
No private opcode numbers, bespoke fill signature or patched dependency is needed.

## Responsibilities

| Component | Responsibility |
| --- | --- |
| HarborProgram | Maker traits, Book hooks, version salt and native fee branches. |
| HarborPricing | Extruction argument encoding and strict register/whole-lot validation. |
| Book.extruction | Authenticate VM context, price once, checkpoint independent NAV and bind settlement. |
| StandingPricing / PricingMath | Live risk gates and bounded, fee-free core pricing. |
| HarborClaimGuard | Shared Book custody/identity checks, not a separate opcode. |
| HarborExecutor | Authenticate trader, lock pool, fund the computed input in a callback, pay output. |
| Official Aqua / SwapVM | Allocations, VM evaluation, native fee calculation and token transfers. |

The pricing target is non-upgradeable. Authorized publishers may still update
bounded, expiring parameters; that trust is explicit and distinct from NAV.
The Book's linked libraries are fixed at deployment and share its accounting.
`Book.priceTrade` is a self-call-only, read-only ABI boundary shared by the
preview and extension. External callers cannot bypass the entrypoint's lock and
context checks. It avoids duplicating large configuration/ledger encoders in
Book runtime; settlement recording and final observations stay in fixed linked
accounting libraries. There is no caller-selected delegatecall or mutable target.

## Canonical program

```text
Salt(strategyVersion) -> direction branch
  Vault buys:  FeeProtocol(output cash) -> Extruction(Book, route/version) -> end
  Vault sells: FeeProtocol(input cash)  -> Extruction(Book, route/version)
  zero fee:    Extruction(Book, route/version)

Extruction arguments: [Book address:20][route:uint256][strategyVersion:uint256]
Book receives only the last 64 bytes; upstream parses the target address.
Taker instruction arguments: abi.encode(Trade), exactly 13 words / 416 bytes.
```

The builder uses the pinned upstream Extruction encoder, JumpIfTokenIn and Jump.
Do not copy opcode numbers or ABIs from a different published release.
Aqua allocations and Book's cash/reserve/exposure gates must both permit the swap.

The official extension receives isStaticContext, nextPC, SwapQuery,
SwapRegisters, maker args and remaining taker data. Harbor returns unchanged
nextPC, the consumed Trade length and updated amounts. Reserve registers are
preserved. User-supplied values never become a supplied executable price pair.

## Quote and execution

```text
quoteSwap(book, Trade)
  -> Router.quote [STATICCALL]
  -> FeeProtocol normalizes the specified register
  -> Extruction -> Book -> live state + one core calculation
  -> FeeProtocol completes customer amounts -> customer limits -> quote

execute(book, Trade)
  -> authenticate trader -> Book.prepareTrade [lock only]
  -> Router.swap -> the same fee/Extruction calculation
  -> Book checkpoints independent pre-trade NAV and binds core amounts
  -> Executor.preTransferInCallback [authenticate, consume capability, fund exact input]
  -> native VM fees + Aqua transfers + measured Book hooks
  -> Executor verifies output, clears allowance, pays customer
  -> Book.finishTrade [recheck custody/evidence, settle Vault cash, clear locks]
```

Pricing occurs before input collection. The funding callback binds the router,
selected Book, registered Vault, Executor, order hash, tokens and hash of
`abi.encode(book, Trade)`. It consumes its
transaction-local capability before any user-token call. Subsequent callbacks
cannot spend the same allowance again. Locks span fees and customer payout.

Book hooks obtain the actual fee as the difference between the authorized core
cash and final customer cash, checking the VM-reported fee and measured balances.
They do not recompute the percentage. Only the canonical shipped program can
reach this authority, with its fixed recipient and fee rate.

Executor.quote(book, Trade) provides a FillAmounts preview using
the same pure core and a read-only fee mapping. It is not the execution path.
Use Executor.quoteSwap(book, Trade) when demonstrating/evaluating the complete VM
program. It returns customer input, customer output and order hash; quote() also
returns core registers and fee breakdown. Tests compare both against settlement.
Quotes reserve no capital. Identical inputs and prestate must agree; changed
state requires a new quote or can cause slippage/version/expiry rejection.

## Whole receipts and rounding

One raw receipt unit represents the entire claim. Book verifies canonicality,
admission, live pending status and nominal backing during pricing, then repeats
the required live checks at final settlement. No redundant claim opcode runs
between those boundaries. Finalized/cash-ready claims recover but do not trade.

Bids floor and asks ceil. Native fees floor at bps*1000 / 10,000,000.
Cash-specified receipt trades must match the indivisible lot's customer price.

At 10 bp, canonical gross bid 999 pays net 999, but the VM's exact-out inverse
first produces gross 1000. Harbor permits ONLY a one-wei intermediate reduction
when the verified canonical bid still pays the exact requested customer output.
For receipt sales, excess input on a fee plateau is rejected, not donated.
Those narrow lot checks retain fee arithmetic; generic execution does not
repeat the VM fee computation. No output-price change overrides customer limits.

## Verification and deployment

```sh
forge test
forge build --sizes
forge fmt --check
```

The existing compact suite exercises official Extruction dispatch, static-write
rejection, malformed args, four modes, whole-unit fee boundaries, one traced
core calculation inside the VM call, callback rollback and two-pool isolation.
Synthetic fixtures and pinned real-issuer fork evidence are distinguished in
[DEMO.md](../../DEMO.md). This is not an audit or a production routing approval.

Use fresh deployments and orders. The published v1.0.2 router documentation
describes a different ABI from this pinned source: compatibility with this
revision is demonstrated, not automatic compatibility with a vanity address.
1inch production resolver acceptance is a separate integration/review step.

Measured with solc 0.8.30, Cancun, via-IR and optimizer 700: Book 24,402 bytes,
Router 20,376 and shared Executor 8,492. Book has only 174 bytes below EIP-170.
Shared-pool routing and currency checks increase the zero-held-receipt inventory
benchmark from 467,154 to 476,167 gas warm, and 632,607 to 645,731 with observed
accounts/slots cooled. This buys explicit pool isolation and decimal support;
it is not a per-trade gas optimization. Router dispatch remains unmodified.
