# Harbor

Pooled WETH liquidity for two-way, exact-input/exact-output inventory trading
through official 1inch Aqua and a custom router derived from official SwapVM,
with asynchronous LP redemption.

## Contracts

- `HarborVault`: ERC-4626-style synchronous deposits, share accounting and
  ERC-7540 asynchronous redemption with FIFO funding and reserved cash.
- `HarborBook`: immutable issuer mandates, individually admitted receipt routes,
  shared cash/exposure checks, authenticated SwapVM callbacks, inventory basis
  and issuer claim accounting.
- `HarborSwapVMRouter`: upstream Aqua settlement plus `HarborExactFill` and
  `HarborClaimGuard`; no upstream dependency files are modified.
- `HarborExecutor`: exact trader amounts, quote verification, custom-router
  execution, fee settlement and residue checks.
- `LidoAdapter`: bounded wstETH requests, adapter-owned withdrawal rights and
  attributable ETH recovery wrapped directly to the fixed vault.
- `LidoClaimFactory` / `LidoClaimReceipt`: canonical whole-request receipts,
  pending-right trading, native export and final-holder recovery.
- `HarborPolicyReceiver`: authenticated, expiring exact-fill permits through
  Chainlink's receiver interface, with no treasury authority.

Pending issuer claims are not spendable cash. Unsolicited token transfers are
excluded from managed NAV. Book/Vault use shared transient operation contexts;
Executor and adapters use transient function guards.

## Redemption market

A user approves a pending unstETH NFT to an admitted factory and calls
`wrap(requestId)`. The factory escrows that NFT and mints one zero-decimal
ERC-20 receipt. One unit owns the whole right; it is not an LP share.

```text
Pending unstETH NFT -> canonical receipt -> WETH trade through Aqua/SwapVM
                              |
                       issuer finalizes
                              |
                  anyone calls recover(hint)
                              |
                 holder burns receipt for WETH
```

The vault buys or sells receipts in all four exact-input/output modes.
`Side` names the vault's action. The receipt leg must equal **1**, not 1e18.
Trades need a signed firm quote and an independent permit. Only pending receipts
trade through this initial market; finalized or cash-ready receipts can still
transfer directly and redeem. A buyer or executable resale quote is not guaranteed.

Recovery and payout are separate: `recover(hint)` puts attributable WETH into
receipt escrow without paying its caller. Only the holder of the unit can call
`redeem(recipient)`, which burns the unit, clears its recovery credit, closes
the receipt and pays once. A previous seller cannot claim the recovery.
When the vault owns the receipt, Book's `recoverClaim` directs payment only to
the vault. Stopped trading, retired integrations or stale marks do not block
recovery; deposits and new withdrawal funding still need current valuation.

Admission is explicit: the governor schedules a factory against a native issuer
route, waits the governance delay, activates it, then admits each pending
canonical receipt. Vault governance publishes its strategy with `refreshStrategy`.
Interface compatibility alone is not approval. Each additional issuer needs its
own custody, beneficiary, cancellation, pause and upgrade review.

Factory receipts are deterministic Solady clones of a fixed implementation,
with issuer, WETH, factory and chain fixed and per-request initialization once.
There is no administrator sweep or beneficiary override. Import retirement is
irreversible. Lido itself is upgradeable; a wrapper cannot remove issuer upgrade
or liveness risk.

## Accounting and public reads

The Book owns positions, cost basis, claim identity, budgets and fill nonces.
The vault owns custody, LP shares and withdrawal credits. Aqua owns published
strategy allocations; neither an indexed profit nor an APY estimate grants authority.

- Native positions retain inventory, warehouse/pending cost, purchase debits,
  realized losses and economic version. Receipt positions retain quantity, cost
  and version; their purchase/loss budgets live once per source issuer in
  `claimTotals`. Selling and reacquiring a receipt cannot reset those budgets.
  Profits do not replenish lifetime purchase/loss limits.
- Native export moves basis into the receipt without cash or realized profit.
  Final recovery/export clears the native claim payload but preserves
  `exists = true` and `closed = true`, preventing identity reuse.
- Native mandates are stored once; `route(id)` derives receipt routes from their
  canonical identity, source mandate and admitted prices. Native inventory,
  rights and receipt descendants share the source issuer's risk limits.
- At most 64 native rights and held receipts are active together. Valuation
  traverses active positions, not every historical route. Only the last successful
  UTC day's request usage is stored; `redemptionUsedToday` handles day rollover.
- Pending claims and WETH inside receipt escrow are claims NAV, not vault cash.
  Receipt lifecycle changes invalidate cached marks. Funding burns queued LP
  shares and reserves actual WETH; already-funded credit remains claimable
  without a new valuation, subject to physical reserve backing.

Receipt quotes use a conservative public mark, not face entitlement. The
observation binds factory, receipt, issuer, request, entitlement, mark, time
and policy. Bid/ask multipliers use 1e18 scale; costs and cash are WETH wei.
Existing fee rounding and minimal exact-output checks apply. Factory versions
bind published programs; retirement invalidates old programs, and a new publication
can allow sales only. Book retirement separately disables new exposure and
advances the quote epoch. Private forecasts remain offchain; signed amounts,
public limits, versions and accepted permit digests are enforced onchain.

| Current read | Scope |
| --- | --- |
| `activeNativeClaims(cursor, limit)` | Live rights with adapter, issuer ID, route, key, cost and remaining/recovered amounts. |
| `activeReceiptRoutes(cursor, limit)` | Held receipt routes; resolve identity and cost with `claimMarket` and `getPosition`. |
| `withdrawalQueueBounds()` / `withdrawalTickets(cursor, limit)` | Current FIFO head/tail and pending controller units. |
| Share balances, pending/claimable requests, `maxWithdraw` | Authoritative wallet balances and funded entitlements. |

Pages contain 1–32 entries and make no issuer/valuation calls. Native/receipt
cursors are live-array offsets; pin every page to one canonical block because
swap-pop removal changes order. FIFO cursors are ticket IDs; start at the current
head, not an already-consumed ticket. Discovery does not bypass settlement checks.

History comes from events: `PositionRealized`, `RedemptionRecovered`,
`NativeClaimExported`, `ReceiptAcquired`/`ReceiptDisposed`, `LiquidityIssued`,
`WithdrawalQueued`/`WithdrawalFunded` and `ValuationCommitted`.
Configuration and strategy events supply admission/version context; official Aqua
`Shipped` logs retain full strategy bytes. Native realization records final
retired cost and proceeds, not an LP payout entitlement; partial recovery logs
its cash delta without retiring the full cost. Receipt events use economic
position versions, not a separate acquisition-history counter. Withdrawal
funding distinguishes policy and marked versions; aggregate ERC-7540 request ID
zero is separate from internal FIFO ticket IDs.

Library events emit at the Book address. Amounts are WETH wei unless explicitly
LP units or receipt quantity. Indexers must retain constructor inputs, deployment
manifests, ABIs and logs from deployment, including issuer, token, factory and
Aqua events. Issuers can finalize without a Harbor transaction. Identify logs by
chain/emitter/transaction/log index and canonical block hash, roll back orphaned
blocks and replay replacements in order. Reconcile against fixed-block state;
a marked version or timestamp is not a unique event ID. An indexer is replaceable
and never the authority over payouts.

Without Harbor's frontend/indexer, RPC users can discover outstanding rights,
trigger eligible recovery and request/claim their LP exits. Swaps still require
quotes and permits; new native requests require the keeper; funding requires
cash and fresh marks. No oracle fallback or emergency sweep is implied.

## Development

Use the [SwapVM strategy guide](src/swapvm/README.md) for custom instruction
encoding, register invariants and authority boundaries, and the
[contract demo](DEMO.md) for narrated trading, recovery and LP-exit traces.
[CONTRIBUTING.md](CONTRIBUTING.md) covers pinned dependencies and engineering rules.
These are the two first-party README locations: this file and `src/swapvm/README.md`.

```sh
forge install
forge build --sizes
forge test
forge fmt --check
```

## Testing

There are **50 Solidity test/invariant entrypoints**: 46 local checks plus
four fork checks. Excess tests were removed, not hidden behind filters.
`forge test` runs all 46 local checks without RPC access.

| Folder | Checks | Purpose |
| --- | ---: | --- |
| `test/base/` | — | Shared fixtures and synthetic issuer/valuation inputs. |
| `test/core/` | 39 | Deposit, four-mode trades, native/receipt recovery, LP exits, accounting, permits and reentrancy. |
| `test/swapvm/` | 5 | Packed parser reference, registers, static authorization, receipt quantity and rollback. |
| `test/invariant/` | 1 | Partial recovery retains outstanding cost until the right closes. |
| `test/gas/` | 1 | Deployed runtime size of Book, Vault, Executor, router and adapter. |
| `test/fork/` | 4 | Real issuer/token interactions at pinned Ethereum blocks. |

Core checks occupy eight flat files. Start with
[HarborSettlement.t.sol](test/core/HarborSettlement.t.sol) for
deposit → purchase → native claim → receipt → cash → LP payout.
[Trading.t.sol](test/core/Trading.t.sol) covers four native trading modes through
the real permit receiver and official Aqua.
[RedemptionMarket.t.sol](test/core/RedemptionMarket.t.sol) covers four receipt
modes, export/sale and exact final-holder WETH payout, receipt burn, cleared
recovery credit and rejection of non-holder/duplicate redemption.

Other core files cover issuance, FIFO rounding/reserves, keeper intents, issuer
failures, receiver authentication and reentrancy. Domain notes remain available:
[vault semantics](test/core/VaultStandards.md),
[issuer scope](test/core/LidoAdapter.md) and
[policy receiver](test/core/HarborPolicyReceiver.md).

Default fuzzing uses 64 cases per test. The invariant runs 32 sequences of 16
calls against independent two-route accounting. Setup reaches partial and closed
states; subsequent handler calls may be no-ops. This is a library-level synthetic
partial-right check, not a partial-claim Lido integration or a randomized
whole-vault campaign. Lido's supported native path closes whole requests.

```sh
bash script/demo-redemption-market.sh
FOUNDRY_PROFILE=compatibility forge test
FOUNDRY_PROFILE=invariant forge test
FOUNDRY_PROFILE=gas forge test
```

The compatibility profile selects `PermitTradingTest`; settlement/unit profiles
run the local suite. `forge test --list` shows discovery, not execution. If a
list-only compile leaves empty bytecode artifacts, rerun the intended test
command with `--force`. A zero-test run is not a pass.

### Pinned fork checks

```sh
FOUNDRY_PROFILE=fork forge test
```

Set `HARBOR_MAINNET_RPC_URL` locally to an archive-capable Ethereum RPC.
The public fallback may lack historical access. Never commit RPC credentials;
compilation, discovery or an RPC failure is not a passing fork run.

| Fixture | Block | Two separate checks |
| --- | ---: | --- |
| [LidoAdapterForkTest](test/fork/LidoAdapter.fork.t.sol) | 25,924,311 | Real new wstETH withdrawal with adapter NFT custody; separately mature historical recovery to the fixed vault. |
| [RedemptionMarketForkTest](test/fork/RedemptionMarket.fork.t.sol) | 25,930,239 | Wrap and sell a new right for 0.99 WETH through locally deployed official Aqua/Harbor SwapVM; separately mature historical holder payout and burn. |

Both assert queue proxy `0x889edC2eDab5f40e902b864aD4d7AdE8E412F9B1` uses
implementation `0xE42C659Dc09109566720EA8b2De186c2Be7D94D9` at their pinned
block. This says nothing about future issuer upgrades. The recorded adapter-block
hash is `0xfb055f2fab35bcaa52709f6013b6cb5766fefeb4537d61e033a30167f196ebba`;
the test selects by block number and asserts implementation, not that block hash.

Historical checks use request **134,829**, impersonate its owner to transfer the
NFT locally and seed test-only adapter/receipt tracking. They execute inherited
production recovery against actual issuer ETH, without fake finalization,
queue-storage rewrites or injected recovery cash. Canonical factory receipts
cannot import finalized rights; the historical harness is not a production
import capability. The receipt-trading fork uses maker/authorization fixtures,
not the full pooled Book.

These checks do not show a newly created request maturing or a full multi-day
Harbor lifecycle. Local synthetic tests supply complementary accounting evidence,
not proof of issuer finalization timing.

### Deployment-size gate

The single gate enforces the 24,576-byte runtime limit and the committed
`HarborRuntimeBytes` snapshot with Solidity 0.8.30, Cancun, via-IR and 700
optimizer runs. Recorded sizes: Book 24,165, Vault 18,096, Executor 12,121,
router 23,017 and adapter 6,421 bytes. Book has only 411 bytes of headroom.
This is not a check of every linked library/receipt or aggregate deployment cost.
Other snapshot files are historical measurements, not current gas assertions.
Baseline updates require a reviewed diff; never raise the absolute runtime limit.

### Coverage limits

This is hackathon coverage, not an audit or full standards-conformance claim.
Local marks, issuer finalization and report delivery are synthetic. Exhaustive
configuration/decoder matrices, long portfolio histories, live CRE delivery,
indexer reorg replay and production valuation calibration are outside this suite.
Removed coverage remains recoverable in Git. Test execution must be reported
separately from tests merely written or compiled.

## Pricing research

```sh
python3 -m unittest discover -s script/pricing -p 'test_*.py'
python3 script/pricing/claim_pricing.py script/pricing/claim-pricing.example.json
```

The offline calculator discounts joint recovery/time scenarios using simple annual
funding, subtracts present-value operating costs, risk buffer, capacity charge and
minimum profit, then floors maker payment to WETH wei. Funding cost must not also
be counted inside capacity charge. Trader proceeds additionally follow swap fees.
The JSON example is assumed, not backtested; this calculator neither signs quotes
nor supplies LP NAV. Its model label grants no onchain authority.

Calibration needs chronological issuer history including still-pending requests,
gas/failures, executable resale bids, liquidity gaps and LP exit stress.
Hold-to-recovery and forced/selective resale need out-of-sample comparison.
No calibrated public APY or resale guarantee is claimed.

## Deployment compatibility and status

This is unaudited, fresh-deployment code, not an in-place storage upgrade or a
mainnet-ready yield product. Core contracts, linked libraries and receipt logic
are fixed. Publish deployment addresses/blocks, ABIs, runtime/library hashes and
canonical programs before moving capital; use the ABI for that deployment.

The current ABI omits `getPosition.realizedGains`, `getClaim.transferred` and
adapter `exportedTo`; history comes from events. `claimMarket` carries receipt
identity rather than an acquisition counter. `ReceiptAcquired`/`ReceiptDisposed`,
`WithdrawalFunded`, `ValuationCommitted` and publication/admission events must
not be decoded as older schemas. Existing obligations settle under their original
contracts: voluntary withdrawal/redeposit does not migrate signatures, FIFO
priority, reserves or risk budgets. No migration sweep authority is added.

The deployment script rejects non-local chains. Live Chainlink delivery,
production valuation and independent security review remain release requirements.
The Foundry Counter examples are development-only and have no Harbor authority.

Solidity dependencies are pinned Forge-managed Git submodules: forge-std,
Solady and the 1inch/Chainlink sources listed in CONTRIBUTING.
Contracts do not require npm installation. No live deployment addresses are
published in this repository.
