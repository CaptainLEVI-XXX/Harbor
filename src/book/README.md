# Accounting and settlement state

The Book owns managed inventory, cost basis, issuer budgets, claim identity and
fill authorization. Aqua owns published strategy allocations; the vault owns
physical custody, shares and withdrawal credits. Neither an indexed trade nor a
quoted APY authorizes spending.

## Live accounting versus history

- Native positions retain quantity, warehouse/pending cost, lifetime purchase
  debits, lifetime realized losses and economic version. Profits do not replenish
  purchase or loss budgets.
- Receipt positions retain quantity, cost and version in the same position map.
  Their native-only pending/purchase/loss fields stay zero. `ClaimMarkets.Totals`
  retains receipt cost and lifetime budgets once per source issuer, including
  disposed markets. New receipt IDs cannot reset that issuer's capacity.
- Native route mandates are stored once. `route(id)` synthesizes receipt routes
  from canonical identity, the source mandate and admitted bid/ask parameters.
  Receipt IDs remain unique and stable; an allocation counter is necessary for
  identity, not for a historical activity feed.
- Native claims retain route, cost, remaining entitlement and cumulative partial
  recovery while active. Final recovery or export clears that payload and the
  inverse protocol ID, but keeps `exists = true` and `closed = true`. Closed IDs
  cannot be imported, recovered or exported again.
- Only the last successful UTC day's redemption usage is stored per native route.
  `redemptionUsedToday(route)` returns zero when that day has expired. Request logs
  plus block timestamps supply historical daily usage.

`PositionRealized` reports retired native cost and proceeds, both in WETH wei.
Its `claimKey` is zero for a sale and the adapter-domain key for issuer recovery;
sale events join to `FillSettled` by emitter, transaction and route. A partial
recovery produces no final realization. `RedemptionRecovered` records its cash
delta and remaining right. Gains are an event projection, not a stored payout
entitlement. Native and receipt losses remain enforceable onchain.

The `RealizationLogs` test projection compares emitted results against independent
ghost accounting. Production contracts never read historical logs.

## Replaceable reads and settlement events

The read layer may use The Graph or another indexer. Its projections never
authorize a fill, mint shares or create withdrawal credit.

| Current view | Result and bound |
| --- | --- |
| `activeNativeClaims(cursor, limit)` | At most 32 live rights: adapter, issuer ID, source route, key, cost, remaining entitlement and cumulative receipts. |
| `activeReceiptRoutes(cursor, limit)` | At most 32 held receipt route IDs; `claimMarket` and `getPosition` resolve their identity and cost. |
| `withdrawalQueueBounds()` | Current internal FIFO `[head, tail)` ticket IDs. |
| `withdrawalTickets(cursor, limit)` | At most 32 live tickets with controller and pending LP units. Start at head. |
| Existing wallet views | Share balances, pending requests, funded units and claimable WETH remain authoritative point queries. |

Native/receipt page cursors are live-array offsets, not stable identifiers. Pin all
pages to one canonical block because swap-pop removal changes order. FIFO cursors
are stable ticket IDs, but a cursor below the current head is rejected. Zero or
oversized pages and cursors beyond the end revert. None of these views calls an
issuer or valuation provider, and none stores a second discovery ledger.

| Event | Historical fact |
| --- | --- |
| `IssuerRouteConfigured` | Complete native token/adapter mandate, prices, buffers and risk limits. |
| `ClaimIntegrationScheduled` | Factory, source, issuer, WETH, exact bid/ask and activation time. |
| `ClaimIntegrationStatusChanged` | Effective admission/retirement and quote epoch. |
| `StrategyPublished` | Order hash, route/publication/factory versions and quote epoch. Official Aqua `Shipped` logs retain the complete strategy bytes. |
| `LiquidityIssued` | Actual WETH payer, controller, share recipient, WETH assets and LP units. Supplements standard `Deposit`. |
| `WithdrawalQueued` | Internal ticket, owner, controller, caller and pending LP units; standard `RedeemRequest` still uses aggregate request ID zero. |
| `WithdrawalFunded` | Ticket, controller, burned units, WETH liability, remaining pending units, policy and marked versions. |
| `ValuationCommitted` | NAV, supply, cash, reserves, inventory/claim marks, policy, marked version and source observation time. |

All asset/cost/mark amounts above are WETH wei; LP quantities use share raw units.
The vault's marked version is not the Book's portfolio version or a unique event
sequence. Two checkpoints can have the same version/time and different composition.
Use `(chainId, emitter, transactionHash, logIndex)` plus canonical block hash for
log identity, and replay in block/transaction/log order. Deposit, withdrawal,
transfer and settlement events supply the intervening cash/share movements;
stale marks must not be presented as executable exit prices.

Library events execute in the Book's context: use its address as emitter and the
matching library ABI for decoding. Archive constructor inputs and deployment
manifests, factory/clone events, issuer events, token transfers, Aqua logs and
Harbor logs from deployment. Existing receipts can finalize without a Harbor
transaction, so Harbor logs alone cannot reconstruct their external lifecycle.
Retain raw logs and reversible block deltas, roll back orphaned blocks to a common
ancestor and replay canonical replacements idempotently. Reconcile projections
against contract state at one fixed block. The compact settlement suite checks
economic transitions and selected event payloads, not production indexer replay
or a network-specific finality policy.

Without Harbor's frontend/indexer, an RPC user can discover outstanding rights,
recover eligible claims and request or claim their own LP exit. New funding still
needs valid marks and cash; swaps still need signed quotes and receiver permits;
new native issuer requests still need the keeper. Discovery does not remove
issuer, oracle, signer or workflow liveness requirements. No oracle fallback,
unrestricted recovery destination or emergency sweep is introduced here.

## Deployment and ABI compatibility

This storage schema is for **fresh deployments**, not an in-place upgrade. The
core contracts, library links and existing receipt implementations are fixed.
Do not reorder an existing deployment's storage or repoint a proxy/library at it.

Clients must use the ABI for their deployment:

- `getPosition` no longer returns `realizedGains`.
- `getClaim` no longer returns `transferred`; closed payload fields are zero.
- `claimMarket` includes the receipt identity instead of an acquisition counter.
- The adapter no longer exposes `exportedTo`; its export event is the history.
- `ReceiptAcquired`/`ReceiptDisposed` replace acquisition-counter events and carry
  economic position versions. Historical event semantics must not be relabeled.
- `WithdrawalFunded` replaces the ambiguously named `WithdrawalFulfilled` schema;
  policy and marked versions are separate fields. `ValuationCommitted` replaces
  the aggregate-only checkpoint event. `StrategyPublished` and
  `ClaimIntegrationScheduled` add complete publication/admission context.

Before moving capital, review external getter consumers and publish deployment
addresses, blocks, ABIs, library/runtime hashes and canonical strategy programs.
Existing obligations must settle under their original contracts. A voluntary
withdrawal and redeposit is not an automatic migration of signatures, FIFO
priority, reserves or issuer risk budgets. No new sweep or migration authority is
introduced by this implementation.
