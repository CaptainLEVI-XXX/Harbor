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

Before moving capital, review external getter consumers and publish deployment
addresses, blocks, ABIs, library/runtime hashes and canonical strategy programs.
Existing obligations must settle under their original contracts. A voluntary
withdrawal and redeposit is not an automatic migration of signatures, FIFO
priority, reserves or issuer risk budgets. No new sweep or migration authority is
introduced by this implementation.
