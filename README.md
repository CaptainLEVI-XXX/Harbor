# Harbor

Pooled redemption liquidity: trade approved yield-bearing inventory and pending
withdrawal rights through official 1inch Aqua and SwapVM's Extruction extension.
The vault supports synchronous deposits and asynchronous LP exits. This is
unaudited hackathon code, not a mainnet-ready yield product.

## Contracts

| Component | Responsibility |
| --- | --- |
| `HarborVault` | Custody, LP shares, coherent NAV, FIFO withdrawal funding and reserved cash. The vault is the Aqua maker. |
| `HarborBook` | Route admission, bounded pricing publication, live risk checks, basis/claim accounting and authenticated settlement hooks. |
| `StandingPricing` / `PricingMath` | Linked live-state checks and pure discount/inventory-potential arithmetic; no independent ledger or mutable dispatch target. |
| `HarborExecutor` | Authenticate the trader, collect computed input, invoke the router, pay customer output and reject residue. |
| `HarborSwapVMRouter` | Deployment alias for the pinned official router, with no overrides. Native Extruction invokes Book pricing; FeeProtocol handles fees. |
| `LidoAdapter` | One pool-bound issuer implementation: requests/imports, NFT custody, native valuation, cash attribution and recovery. |
| `HarborClaimFactory` / `HarborClaimReceipt` | Shared, generic canonical ERC-20 ownership tokens. One indivisible clone per approved adapter claim; no issuer-specific code. |

The Book's abstract modules share one state owner. Libraries take explicit
storage references. Tokens stay in the vault until execution; deposited LP funds
do **not** remain in individual users' wallets. Aqua allocations are not extra
cash and do not determine LP ownership.

One Executor and Router serve multiple registered Book/Vault pairs, including
pools with different settlement assets. The Book address selects the pool; LP
shares, cash, reserves, pricing and claims remain isolated per pool. Executor
governance registers reciprocal immutable bindings once; it cannot rebind a Book.
Generic receipt factories are shared **per settlement asset**, not across currencies.
Lido remains WETH-only. Six-decimal cash plus eighteen-decimal inventory/receipts
is covered by a synthetic, explicitly funded issuer fixture—not a deployed USDC
issuer integration. Cross-currency/FX trading is not implemented.

## Standing pricing

The backend publishes a reusable route discount, not a signed price for each
trade. Anyone can read `Executor.quoteSwap(book, Trade)`; the trader calls
`Executor.execute(book, Trade)`. Execution obtains the canonical published order and
locks Book/Vault, then SwapVM invokes one live pricing calculation through
Extruction. An authenticated funding callback collects only actual input.

```text
Publisher -> Book.publishPricing(route, parameters)
Trader -> Executor.quoteSwap(book, intent) -> Router.quote -> Extruction -> Book/kernel
Trader -> Executor.execute(book, intent)
       -> Book/Vault lock -> SwapVM / Extruction pricing + NAV checkpoint
       -> authenticated input funding -> VM fee -> Aqua transfers / Book hooks
       -> customer payout -> measured cash accounting -> unlock
```

One `Trade` contains trader/receiver, token pair, route, side/mode, specified
amount, limit, deadline and expected pricing/config/strategy versions. It contains
no output-price authorization, fill signature or trader nonce. Only the named
trader may execute; sending another transaction is a new intent. Issuer request
nonces and closed-claim tombstones remain essential and are retained.

Side names describe the **vault**:

| Trader action | Side | Exact input / exact output |
| --- | --- | --- |
| Sell inventory for WETH | BUY_BASE | Exact base input / exact net WETH output |
| Buy inventory with WETH | SELL_BASE | Exact gross WETH input / exact base output |

The initial, uncalibrated model is:

```text
discount = sum(probability * recovery_fraction / (1 + annual_rate * remaining_days / 365))
value = nominal_entitlement * discount

excess = max(0, exposure / capacity - target)
potential(exposure) = kappa * capacity * excess^3 / (3 * (1 - target)^2)

gross_buy_payment = value - buy_cost - buy_margin * entitlement
                   - [potential(x + entitlement) - potential(x)]
net_sell_receipt  = value + sell_cost + sell_margin * entitlement
                   - [potential(x) - potential(x - entitlement)]
```

The contracts receive only the quantized discount; scenario history stays
offchain. Native inventory uses a new-redemption forecast; existing rights need
remaining-time/recovery assumptions for their own route and status. A published
factor does not automatically age toward par.

Monetary units are raw units of each pool's `ASSET`; factors use 1e18; fees use basis points; times use Unix
seconds. Bids floor, asks ceil. The integer solver makes at most 90 bisections
and calls no external contract inside its loop. Whole-receipt cash-specified
modes must equal the price of one unit: no fractional token or silent donation.

Curve capacity is fixed at deployment between one whole settlement token and
1e27 raw units (1e9 WETH, or 1e21 six-decimal cash tokens); target is at
most 90%, kappa at most 1%, discount between 50–100%, margins at most 5%, and each
operation cost at most one whole settlement token. Approved cash/inventory token
metadata must remain fixed at 6–18 decimals. Inventory conversion ratios are
restricted to 0.5–4 **whole settlement tokens per whole inventory token**, with
raw-unit decimal conversion applied separately. These are numerical safety bounds,
not recommended economic settings. Route policy is configured once by governance.
An updater cannot modify margins, costs, caps, fees, admission or its own role.
Lifetime is at most one day and may be configured shorter; expiry is inclusive.

Existing public bid ceilings, ask floors, sale-loss budgets, cash reserves,
pending exits and Aqua allocations remain independent hard gates. Valid publication
does not guarantee every size/direction is executable. In particular, a discount
can make a sale fall below its fixed public ask floor. Price policy must be chosen
together with these bounds; the contract declines instead of relaxing them.

## Redemption market

A pending unstETH NFT owner approves the admitted adapter and calls
`factory.wrap(adapter, ClaimImport, receiver)`. The factory and adapter atomically
verify custody, bind one canonical clone and issue one zero-decimal ERC-20 unit.
The adapter holds the NFT; the generic receipt holds neither NFT nor claim cash. It is a whole right, not an LP share. Governance separately
admits the receipt route, configures pricing and ships the vault's strategy.

```text
pending issuer NFT -> canonical receipt -> sell/buy through Harbor
                             |
                       issuer finalizes
                             |
                    anyone: recover(abi.encode(hint))
                             |
                 holder: redeem(recipient)
```

Only pending receipts trade in this initial market. Finalized/cash-ready receipts
can still transfer directly and recover. No buyer or resale liquidity is guaranteed.
Recovery credits only attributable cash; redemption burns the unit and pays once.
When the vault is the holder, `Book.recoverClaim` pays only the vault.

Native inventory can instead become an adapter-owned withdrawal request, then
recover directly or be exported into a vault-owned receipt without realizing
profit. Common interfaces do not imply blanket approval of other issuers. Lido
is upgradeable; immutable Harbor wrappers do not remove issuer risk.

## Accounting and public reads

Pending claims never count as spendable vault cash. Acquisition basis, nominal
FACE and NAV are different quantities:

- FACE combines live inventory conversions with maintained native/held-receipt
  nominal totals, without rescanning every claim. Request/export moves the exposure rather than releasing it.
  Final settlement clears extinguished rights even when cash recovery is zero.
- Basis/purchase/loss budgets remain enforced once per source issuer across native
  positions and receipts. Selling and reacquiring cannot reset lifetime budgets.
- Cash attributed to a receipt in its adapter is not vault trading cash; its FACE allocation
  remains occupied until the vault redeems it.
- Vault NAV uses independent public marks, not the bid. Price publication never
  checkpoints NAV. Live mark/status/validity changes make a cached NAV unusable;
  permissionless checkpointing commits a new coherent value. Execution can
  checkpoint automatically from the independently verified snapshot under its lock.
- Withdrawal funding burns queued shares and reserves actual cash. Already-funded
  credits remain claimable during pricing/valuation outages, subject to physical
  backing. Unfunded exits still need fresh marks.

There is no configured LP deposit cap; numeric issuance and Aqua allocation
headroom still apply. Acquisition-basis limits and FACE capacity remain independent.
Reporting-only global portfolio/valuation counters are removed. Position versions,
keeper nonces and price/configuration/strategy versions remain authoritative.

`LidoAdapter` reads underlying share totals, not a rounded one-token exchange
rate. Pending NAV haircuts are trusted public estimates. Finalized claims use the
queue's claimable ETH and verified custody, even when the estimate publisher is
unavailable. Publishing estimates cannot change owned units, issuer cash or fees.
Revocation and delayed rotation are separate from Book's pricing updater role.
Both roles remain trusted; this is not trustless forecasting.

Exact NAV still observes at most two native routes and 64 active native/receipt
rights. The adapter batches pending/finalized issuer reads; cash-ready/closed rights
need no issuer query. FACE and NAV are deliberately different computation paths.
Historical receipt routes are not an ever-growing settlement loop. Live discovery:

| Read | Returns |
| --- | --- |
| `activeNativeClaims(cursor, limit)` | Adapter/issuer IDs, route, cost, remaining and received amounts. |
| `activeReceiptRoutes(cursor, limit)` | Held routes; resolve with `claimMarket` / `getPosition`. |
| `withdrawalQueueBounds()` / `withdrawalTickets(cursor, limit)` | Current FIFO tickets and pending controllers. |
| `pricingParameters`, `pricingPolicy`, `pricingCurve`, `faceExposure` | Current pricing inputs and authoritative exposure. |
| Share balances, request balances, `maxWithdraw` | Ownership and funded LP entitlements. |

Pages contain 1–32 entries. Pin pages to one block because active sets use swap-pop.
Index events from deployment with ABIs, manifests and constructor inputs retained.
Use chain/emitter/transaction/log-index plus block hash; roll back orphaned blocks.
Issuer finalization can occur without a Harbor event.

`PricingParametersPublished`, `MarksPublished`, `TradeExecuted`,
`PositionRealized`, `RedemptionRecovered`, receipt transitions, LP funding and
`ValuationCommitted` reconstruct history. Library events emit at Book. Trade
context hashes can repeat; they are not unique history keys. Aqua `Shipped` logs
retain canonical order bytes. The indexer is replaceable, never payout authority.
RPC users can quote/execute, discover obligations and claim without Harbor's
frontend. New issuer requests still require the keeper; stale estimates stop
new risk taking.

## Development and testing

```sh
forge install
forge build --sizes
forge test
forge fmt --check
```

Read [CONTRIBUTING.md](CONTRIBUTING.md), the [SwapVM guide](src/swapvm/README.md)
and [demo instructions](DEMO.md). Solidity dependencies are pinned Forge-managed
submodules; contracts require no npm installation.

The suite retains **50 Solidity test/invariant entrypoints: 46 local, four fork**.

| Folder | Checks | Purpose |
| --- | ---: | --- |
| `test/base/` | — | Shared setup and clearly labeled synthetic inputs. |
| `test/core/` | 39 | Arithmetic, four-mode execution, valuation, issuer/receipt recovery, LP accounting and reentrancy. |
| `test/swapvm/` | 5 | Packed parser, registers, static-call isolation, whole receipts and rollback. |
| `test/invariant/` | 1 | Partial basis, live native/tokenized lifecycle, FACE and per-claim cash conservation. |
| `test/gas/` | 1 | Production runtime-size gate and warm entrypoint comparison at 0/1/8/64 held receipts. |
| `test/fork/` | 4 | Pinned real issuer/token interactions. |

Default fuzzing uses 64 cases. The invariant runs 32 sequences of 16 calls across
a partial-ledger handler and a real Harbor custody handler: import, acquisition,
native export, loss recovery and final holder payout. It is not an exhaustive
campaign or a claim that Lido supports partial issuer payouts. `IssuerRecoveryTest` uses the actual native
valuation implementation with synthetic issuer finalization. `StandingTradingTest`
covers repeated parameters, four modes, real transfers, curve repricing and rollback.
The same tests exercise an isolated direct-settlement harness in `test/base/`:
VM-native fees, one traced pricing-kernel call, receipt fee-rounding boundaries,
callback rollback and two pools sharing Aqua/Router. This harness is not the
production entrypoint and is not included in deployment scripts. Passing synthetic tests does not approve its deployment.

```sh
forge test --list
FOUNDRY_PROFILE=compatibility forge test
FOUNDRY_PROFILE=invariant forge test
FOUNDRY_PROFILE=gas forge test
```

The compatibility profile selects `StandingTradingTest`. Discovery is not execution.
After list-only compilation, use `forge test --force` if artifacts contain no bytecode.

### Pinned fork checks

```sh
FOUNDRY_PROFILE=fork forge test
```

Configure `HARBOR_MAINNET_RPC_URL` locally with archive access; never commit credentials.
An unavailable provider is not a passing test.

| Suite | Block | Evidence |
| --- | ---: | --- |
| `LidoAdapterForkTest` | 25,924,311 | Real new wstETH request; separately mature historical recovery to a fixed vault. |
| `RedemptionMarketForkTest` | 25,930,239 | Full Harbor pooled maker, native valuation and standing receipt buy/sell through local official Aqua/router, then LP cash payout; separately mature historical holder recovery. |

Both pin queue implementation `0xE42C659Dc09109566720EA8b2De186c2Be7D94D9`.
Historical checks transfer request 134,829 from its owner using fork impersonation
and seed test-only tracking. They do not finalize the newly created request,
modify issuer storage or inject issuer recovery cash. The production Lido adapter rejects finalized imports/exports; the historical
fork harness has an explicitly test-only export for already-mature rights. Written/compiled fork checks require an actual
successful RPC-backed run before claiming evidence.

### Deployment-size gate

Solidity 0.8.30, Cancun, via-IR, 700 optimizer runs. The gate retains the
24,576-byte absolute runtime limit and [committed sizes](snapshots/HarborRuntimeBytes.json).
Read the current sizes in that snapshot and check every linked runtime in
`forge build --sizes`. Book remains close to the limit;
source segregation alone does not reduce bytecode.

The maximum-domain arithmetic-only exact-output check measures about 374k gas
against a 2m gas ceiling. This excludes transfers, cold state and a full 64-right
portfolio. Other old snapshot files are historical, not current transaction
benchmarks. The gas test measures production Executor execution using warm and
explicitly cooled exact-input inventory purchases at 0/1/8/64 held pending receipts.
It checks actual cash and inventory, and traces exactly one core calculation
inside the official Extruction call, with no preview fee calculation. Measurements
exclude setup and transaction intrinsic gas. Cooling resets the observed accounts
and slots, not a complete mainnet transaction environment. A mixed 64-right NAV
check asserts one issuer-status and one claimable-cash batch. Other modes' detailed
gas, real-issuer worst-case observations and independent security review remain gaps.

## Pricing research

```sh
python3 -m unittest discover -s script/pricing -p 'test_*.py'
python3 script/pricing/claim_pricing.py script/pricing/claim-pricing.example.json
```

The Decimal reference uses joint recovery/time scenarios and differences of the
same capacity potential on both sides. It is not a bit-for-bit VM emulator.
Examples are assumptions, not fitted or backtested settings. Calibration still
needs chronological histories including unresolved rights, adverse selection,
quote acceptance, executable resale demand, costs and LP-exit stress.
Charging customers a larger discount is not evidence of improved prediction,
and no estimated or guaranteed APY is supplied.

## Deployment compatibility and status

Use fresh immutable core/router/library deployments and fresh Aqua orders.
The local deployment script rejects chains other than 31337. Verify deployment
addresses, links, code hashes and ABIs; dependency getters are not attestations.
`DeployHarbor.runLido` creates or reuses shared Aqua/Router/Executor/factory, predicts and
checks Book/Vault/Executor/adapter bindings, and leaves admissions disabled.
Governance separately schedules factory and Book admission, waits their delays,
configures route policies, and ships strategies. Independent publishers provide
live pricing/marks. No adapter-specific valuation deployment is needed.

Old signed-fill APIs, receiver reports, issuer-specific receipts, constructor
bindings and programs are not supported by this deployment. No proxy
upgrade or automatic migration of assets, LP shares, FIFO claims or budgets is
provided. Existing obligations must settle under their original deployment;
moving capital needs a separate explicit migration procedure.

This implementation requires no external report service, confidential workflow,
feed subscription or automation job. Parameter publication still needs an operator.
No frontend/backend deployment, calibrated pricing, mainnet launch, multi-issuer
valuation, exhaustive conformance testing or audit is claimed.
