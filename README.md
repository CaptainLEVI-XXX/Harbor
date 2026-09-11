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
| `BookExecution` / `BookContext` | Fixed linked settlement code and one Book-owned transient context; no separate custody, ledger or upgrade target. |
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
and the [pinned fork checks](#pinned-fork-checks). Solidity dependencies are pinned Forge-managed
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
The same tests exercise the production contracts through shared fixtures in `test/base/`:
VM-native fees, one traced pricing-kernel call, receipt fee-rounding boundaries,
callback rollback and two pools sharing Aqua/Router/Executor. Test-only issuer
and callback helpers are not included in deployment scripts. Arithmetic and
encoding regressions compare against straightforward test-only references;
the production contracts contain no second reference implementation.

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

Configure `HOODI_RPC_URL` in your ignored root `.env` with access to the pinned
state; no private key is required. Foundry uses the `hoodi` RPC alias. An
unavailable/pruned provider is a failed check, not a passing or silently skipped test.

| Suite | Block | Evidence |
| --- | ---: | --- |
| `LidoAdapterForkTest` | Hoodi 3,602,344 | Real new wstETH request; separate historical native and tokenized recovery using actual issuer ETH, holder-only payout and duplicate-payment rejection. |
| `RedemptionMarketForkTest` | Hoodi 3,602,344 | All four modes for wstETH inventory and pending receipts through the existing Aqua/router/WETH; quote agreement, independent price/fee checks, measured balances and LP cash payout. |

The shared [Hoodi fixture](test/base/HoodiFork.sol) pins chain 560048 and queue
implementation `0xD0a60e52837e045F4567193Cf8921191C486eCD5`. Block hash:
`0x63c38d9e4265601c8b541cf71d287c3d890f8523bfdd2f3360da08ac5ad875b8`.
It uses the WETH/Aqua/router addresses in the deployment table below and checks
the deployed Aqua/router runtime fingerprints and immutable bindings. It never
deploys substitutes for those dependencies; only Harbor contracts are created in
the local fork. There are no broadcasts, real wallet signatures or public gas costs.

Historical recovery uses requests 4989 and 4990, transferred from their actual
owners through fork-only impersonation and seeded into a test-only adapter ledger.
The production adapter rejects finalized imports/exports, so the harness explicitly
permits historical export solely to exercise generic receipt recovery. It does
not finalize the newly created request, modify issuer storage or inject recovery
cash. New-request finalization over time is **not** proven by these tests.

All four fork tests passed against this configuration. This is integration
evidence, not an audit or a guarantee of future issuer availability. To repeat
the pinned run after provider pruning, use an archive-capable Hoodi RPC; do not
change the block or claim IDs merely to suppress a failing test. No redeployment
is needed to rerun the checks.

### Deployment-size gate

Solidity 0.8.30, Cancun, via-IR, 700 optimizer runs. The gate retains the
24,576-byte absolute runtime limit and [committed sizes](snapshots/HarborRuntimeBytes.json).
Read the current sizes in that snapshot and check every linked runtime in
`forge build --sizes --skip test --skip script`. Book is 23,785 bytes, with 791
bytes of headroom. Its fixed 4,216-byte execution library moves substantive
settlement code out of Book; source segregation alone does not reduce bytecode.
This is not a proxy and does not make existing Books or receipts upgradeable.

The maximum-domain arithmetic-only exact-output check measures about 189k gas
versus 374k for the straightforward reference, against a 2m gas ceiling.
This excludes transfers, cold state and a full 64-right
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

### Hoodi dependency deployment

[Hoodi configuration](script/hoodi.config.json) records two confirmed deployments
on chain 560048, source revisions, compiler settings, transactions and verification:

| Contract | Hoodi address |
| --- | --- |
| Aqua | `0xf40826aFd0de1078bc4b39b77E87E42d3b35Fe6A` |
| AquaSwapVMRouter | `0x63C78337758eA9c98b4Ce6Cc9988E72e2D8F3303` |
| Existing WETH (not deployed by this script) | `0xE0decAa66aED871ac9eb924443D1Bf333Fdb062E` |

The router owner is `0x41363507931dd8963f5eb836e299d74272d0ccb0` and its
EIP-712 domain is `Harbor`, version `2`. Both creation inputs and deployed runtime
code were checked against the compiled pinned contracts, with runtime immutable
locations normalized and constructor arguments/getters independently checked.
The existing WETH passed a fork-only wrap/transfer/approve/unwrap check. These
checks are not an audit or a claim of explorer source verification. The instances
are user-deployed upstream code, not claimed canonical 1inch deployments; sponsor
eligibility remains separately unconfirmed.

Harbor core contracts have subsequently been deployed and the Book/Vault pair
registered with Executor. The [deployment manifest](script/harbor-hoodi.deployment.json)
records 17 successful transactions and 34 checked bindings/configuration values.
Admission activation, price/mark publication, LP deposits and strategy allocations
remain pending. No additional token mocks were deployed. Lido runtime provenance
is not independently attested by this deployment record.

Verify the Harbor receipts and configuration without sending transactions:

```sh
node --env-file=.env script/verify-harbor-hoodi.mjs
```

Use the official [SwapVM deployment guide](https://github.com/1inch/swap-vm/blob/main/DEPLOY.md)
for constructor requirements. Harbor uses the pinned `AquaSwapVMRouter` through
Foundry; do not install a separate latest Hardhat project or silently change
instruction tables, ABIs or EIP-712 domain values. The five constructor inputs
are Aqua, wrapped-native token, owner, name and version.

Add these entries manually to the ignored root `.env` when preparing a test-only
deployer; do not replace existing entries or put secrets in `.env.example`:

```dotenv
HOODI_RPC_URL=
HOODI_PRIVATE_KEY=
```

An encrypted Foundry keystore is preferable for signing. If an env key is used,
use a disposable test-only wallet with no valuable funds on any chain. Never paste
the key into chat, logs or command-line arguments. `DeployAquaHoodi` has separate
Aqua/router entrypoints restricted to Hoodi; it imports no Harbor contracts.
`hoodi-ops.mjs` supplies the named RPC alias, redacts credentials from child output,
and refuses to repeat broadcasts when a live broadcast record exists. Do not
delete that record to retry an uncertain transaction; check its receipt first.

Recheck the deployed instances without sending transactions:

```sh
node --env-file=.env script/hoodi-ops.mjs verify 0xf40826aFd0de1078bc4b39b77E87E42d3b35Fe6A 0x63C78337758eA9c98b4Ce6Cc9988E72e2D8F3303
```

SwapVM executes quotes/swaps on-chain without a continuously running 1inch backend.
Its configured dependencies and program calls must remain available. Harbor still
needs authorized pricing/mark publications and keeper transactions; expired inputs
can stop new trades. Lido finalization depends on its own protocol operations.
Graph is a read layer, not a settlement dependency. Running a custom router does
not automatically register Harbor with 1inch's hosted routing/discovery services.

### Existing deployment boundary

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

### Controlled Hoodi setup

`script/DeployHarborHoodi.s.sol` reuses the recorded Aqua/router/WETH/Lido
addresses. It deploys immutable Harbor contracts with zero protocol fees and
the signer in every administrative role. Required public configuration names
and units are in [hoodi-demo.env.example](script/hoodi-demo.env.example); fill
the existing ignored `.env`, never this example, with actual settings/credentials.

On chain 560048 only, receipt admissions still require explicit scheduling and
activation but have no waiting period. Book pricing and adapter marks allow
100-day lifetimes. Other chains retain the one-day maximum and admission delay.
Updater rotation and trading resumption retain their original governance delays.
Long-lived demo inputs are not calibrated forecasts and do not override live
claim-status, cash, exposure or slippage checks.

The script exposes independent commands:

1. `run()`: deploy Harbor and register its Book/Vault with Executor.
2. `configure(address)`: pass the Book address; admit receipts and publish native
   pricing/marks for 100 days. No LP funds move.
3. `publishStrategy(address,uint256)`: after users deposit through the frontend,
   pass the Book and route ID. Calls `Vault.refreshStrategy(route)`; Vault is the
   Aqua maker. This command does not wrap funds or deposit for users.
4. `registerReceipt(address,address)`: register an already imported pending
   receipt held by the demo trader and publish its 100-day pricing parameters.
   Call `publishStrategy` separately when the Vault has liquidity.

Approved demo settings: zero fees; inventory buy/sell margins 1%; receipts
97% bid / 98% ask of nominal entitlement before capacity adjustment. Receipt
parameters use a 97.5% discount and 0.5% nominal buy/sell margins.
Trader/receipt holder: `0x7c5437B3Ac402EE9316981a66f37Ce46E1468aea`.

Simulation example (no broadcast):

```sh
forge script script/DeployHarborHoodi.s.sol:DeployHarborHoodi --rpc-url hoodi --sig 'run()'
```

Review the explicit configuration, signer nonce, linked libraries, estimated gas
and transaction list before authorizing broadcast. The original local-only
`DeployHarbor` entrypoints remain gated. Foundry records broadcast transactions;
reconcile them before using `--resume`. Rerunning `run()` creates another pool.
Configuration can renew marks/prices; it is not a no-op inspection command.

There is no automated LP funding or seeding command. Users wrap/deposit through
their frontend wallets using the selected WETH. The script does not buy wstETH,
create withdrawal NFTs, trade, finalize claims or configure the frontend/indexer.
Reverse-direction trading needs accounted inventory acquired through a trade;
donations are not positions. Receipt markets require their own route policy and
Aqua strategy after an eligible NFT is imported. A separate trader is required:
the signer/fee recipient is excluded from trading even when the fee is zero.
