# Core flow checks

`forge test` runs the complete 46-check local suite. This folder contributes
39 checks, grouped by the obligation being tested.

| File | Checks | Why retain it? |
| --- | ---: | --- |
| `HarborSettlement.t.sol` | 7 | Deposit → purchase → native claim → receipt → cash → LP payout; loss budgets, FIFO, credit ownership, duplicate claims, expiry and live discovery. |
| `Trading.t.sol` | 7 | All four native trading modes with actual balances and real receiver logic; signer/permit separation, shared cash, trader authority, stale quotes and late-fee rollback. |
| `Vault.t.sol` | 5 | Independently priced issuance, donation exclusion, callback-failure rollback, controller-credit authority and physical reserve deficits. |
| `Accounting.t.sol` | 6 | Partial-credit rounding, cash conservation, zero-NAV/dust distinction, closed-claim identity and daily request-counter rollback. |
| `Issuer.t.sol` | 4 | Recovery funds queued exits; keeper intent/nonces are bound; malformed issuer requests and false closure cannot corrupt accounting. |
| `RedemptionMarket.t.sol` | 4 | All four receipt modes, final-holder payout after export, lifecycle-invalidated quotes/NAV and rejection of fake/unadmitted receipts. |
| `Reentrancy.t.sol` | 3 | Token and issuer callbacks cannot enter conflicting Book/Vault/Executor operations. |
| `HarborPolicyReceiver.t.sol` | 3 | Forwarder/workflow authentication, duplicate delivery without expiry extension and cancellation without revival. |

Shared fixtures are in `test/base/`. Keep assertions with their flow and reuse
the fixture; do not add another inheritance layer or a separate file per failure.

## What actually executes

Full settlement uses the real Harbor Book, Vault and Executor, official Aqua,
and Harbor's router derived from the pinned official SwapVM implementation.
LPs approve and fund the pooled vault; it is the Aqua maker. Traders approve
Executor, which collects only the exact quoted input and pays output/fees.
Custom instructions authenticate the complete fill; late failures roll back
token movements, accounting and consumed nonces together.

The tests compare physical balances and onchain entitlements. Issuance/funding
expectations use independent integer arithmetic, not just matching production
previews. Public valuation, issuer finalization and workflow delivery are still
synthetic fixtures, not production pricing or live Chainlink evidence.

The 39 checks intentionally do not enumerate every supported ABI path or
governance configuration. The surrounding [suite guide](../README.md) describes
what was retained and what requires separate validation.

Related notes: [vault semantics](VaultStandards.md), [issuer scope](LidoAdapter.md),
and [policy receiver](HarborPolicyReceiver.md).
