# Redemption market

Harbor trades **one entire pending Lido withdrawal right for WETH**. A user
approves their unstETH NFT to a reviewed factory and calls `wrap(requestId)`.
The factory escrows the NFT and mints one zero-decimal ERC-20 receipt. The
receipt owner owns the eventual recovery; the factory governor cannot redirect it.

```text
Pending unstETH NFT -> canonical receipt -> WETH trade through Aqua/SwapVM
                              |
                     issuer finalizes
                              |
                  anyone calls recover(hint)
                              |
                 holder redeems receipt for WETH
```

The pooled Harbor vault can buy or sell the receipt. Both directions support
exact input and exact output; the receipt leg must always equal **1**, not 1e18.
Buying/selling is named from the vault's perspective in `Side`. Trades require
a live signed firm quote and an independent policy permit; no automated quoting
service or secondary buyer is implied. Finalized or recovered receipts cannot
trade through this initial market, but their holder can still transfer them
directly and redeem. This avoids selling stale pending-state quotes after issuer
finalization.

## Responsibilities and admission

| Component | Owns |
| --- | --- |
| `LidoClaimFactory` | Canonical request-to-receipt identity and irreversible import retirement. |
| `LidoClaimReceipt` | Exact NFT custody, attributable recovery, whole-unit ownership and final payout. |
| `BookClaims` / `ClaimMarkets` | Delayed admission, stable receipt routes, native exports and acquisitions. |
| `BookPortfolio` | Shared issuer limits, public claim marks and receipt lifecycle freshness. |
| Existing executor and SwapVM instructions | Firm-quote authority, exact amounts, claim-state checks and atomic settlement. |
| Existing vault | LP shares, cash, reserved withdrawals and Book-only treasury callbacks. |

The governor schedules a factory against an existing native issuer route, waits
the Book's governance delay, activates it, then admits each pending canonical
receipt. The vault governor publishes its WETH/receipt order through
`refreshStrategy`. Interface compatibility is **not** admission. Other protocols
require individual custody, beneficiary, cancellation, pause and upgrade reviews;
account-bound request IDs and revocable approvals are not transferable rights.

Factory receipts are deterministic Solady clones of one fixed implementation.
Issuer, WETH, factory and chain are fixed in that implementation; each clone's
request/importer is initialized exactly once by the factory. There is no mutable
implementation pointer, administrator sweep or recovery-beneficiary override.
Book domain libraries have fixed compiler links and explicit storage references;
their addresses and code must be verified as deployment dependencies. These are
new immutable deployments, not upgrades of existing Harbor contracts. Lido itself
is upgradeable; the wrapper cannot eliminate issuer upgrade or liveness risk.

## Accounting and quote identity

Receipt purchase debits actual WETH and records cost. Selling removes that
cost once and records net proceeds. Reacquisition advances the economic position
version; it does not reset spending or loss budgets. Exporting an adapter-owned
right moves its existing basis into a vault-owned receipt without realizing PnL.
The native record retains consumed-identity flags; its completed accounting payload
and reverse issuer-ID lookup are cleared. `NativeClaimExported` records the source,
issuer ID, destination receipt route and preserved WETH basis.

`ReceiptAcquired` and `ReceiptDisposed` identify the resulting position version.
They do not share a separate acquisition counter: indexers pair transitions in log
order within each route. Receipt positions retain quantity, cost and version;
their native-only purchase/loss fields remain zero. Receipt lifetime purchase and
loss authority lives in the source issuer's `claimTotals`, including disposed routes.

Native inventory, native rights and receipt descendants share the original
issuer's exposure, lifetime-purchase and realized-loss limits. At most 64 native
rights and held receipts are active in aggregate. Historical receipt routes are
stable, but valuation loops visit only active positions, never all historical IDs.

Pending receipt marks count as **claims NAV, never spendable cash**. Even WETH
already recovered into an escrow becomes vault cash only when the vault redeems
its receipt and measures the WETH credit. Unsolicited donations are excluded.
Receipt finalization, recovery or ownership changes invalidate the cached receipt
state fingerprint: deposits and withdrawal funding require a fresh checkpoint.
Already-funded LP withdrawals remain claimable. Stopped trading, stale marks,
retired factories and unavailable policy permits do not block recovery.

The existing `Trade` and `FillTerms` formats are reused. Receipt identity is bound
by its registered route, canonical program hash and public observation hash.
The published factory version occupies `adapterVersion`; factory retirement
invalidates old programs, while a fresh publication can permit sales only.
Book retirement separately disables new exposure and advances the quote epoch.
Signatures retain trader/recipient, amounts, expiry, nonces, portfolio, position,
valuation and strategy versions. The public policy is fixed at version 1.

For receipt routes the public price reference is the claim's conservative mark,
not its face entitlement. The observation hash includes factory, receipt, issuer,
request, entitlement, mark, timestamp and policy. Bid/ask multipliers are scaled
by 1e18; all cash amounts and cost basis are WETH wei. Existing fee rounding and
minimal exact-output input checks still apply. Private forecasts and inventory
preferences stay offchain; signed prices, public checks and accepted permit
digests are onchain. The receiver gains no recovery or treasury permission.

## Reproduce and interpret evidence

```sh
bash script/demo-redemption-market.sh
bash script/demo-redemption-market.sh --fork
FOUNDRY_PROFILE=invariant forge test
FOUNDRY_PROFILE=gas forge test
python3 -m unittest discover -s script/pricing -p 'test_*.py'
python3 script/pricing/claim_pricing.py script/pricing/claim-pricing.example.json
```

Local tests use synthetic issuer finalization, marks and permits, with actual
EVM token transfers through official Aqua. The [fork fixtures](../../test/fork/README.md)
separately prove real Lido import/trading and historical recovery. They do not
prove a newly created request maturing immediately.

The offline calculator discounts joint recovery/time scenarios using simple
annual funding, then subtracts present-value operating costs, risk buffer,
capacity charge and minimum profit. It floors the maximum maker payment to
WETH wei. Its JSON example is assumed, not backtested. Keep the same funding cost
out of both the rate and capacity charge. Trader net output additionally follows
the protocol fee calculation. The calculator neither signs quotes nor supplies
LP NAV; its model label is an offchain audit label, not a new onchain permission.

Chronological calibration still requires issuer history, censored pending
requests, actual gas and failures, executable secondary bids, liquidity gaps
and LP withdrawal stress. Hold-to-recovery, forced resale and selective resale
must be compared out of sample. No public APY, resale guarantee or production
readiness is claimed. Production valuation, live Chainlink delivery and an
independent audit remain release requirements.
