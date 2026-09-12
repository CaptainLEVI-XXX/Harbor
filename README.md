# Harbor

Pooled redemption liquidity: trade approved yield-bearing inventory and pending
withdrawal rights through official 1inch Aqua and SwapVM's Extruction extension.
The vault supports synchronous deposits and asynchronous LP exits. This is
unaudited hackathon code, not a mainnet-ready yield product.

## Graph analytics

Read-only Graph tooling lives in `graph/`, separate from Foundry and the client.
It includes a shared standardized-vault source inspector, exact return arithmetic,
and Harbor mappings for deposits, shares, exits, checkpoints, settled trades,
native recoveries and canonical receipt ownership/holding episodes. Full policy
history, daily rollups, read-service integration and comparison admission remain
unfinished. Harbor is deployed to Subgraph Studio on Hoodi; decentralized-network
publication and a completed live issuer-recovery lifecycle remain unverified. Analytics does
not authorize settlement or publish prices.

With Node 22 or newer and the existing Foundry artifacts:

```sh
forge build
npm --prefix graph ci --ignore-scripts
npm --prefix graph run verify
```

The verification command runs five analytics scenarios, builds the same Harbor
schema/mappings with two synthetic network configurations, and runs seven mapping
scenarios using pinned Matchstick 0.6.0. The runner may require a supported native
platform and an initial download. Fixtures are **not public deployments**;
`graph/subgraph/networks.json` separately records the actual Hoodi contracts and
Studio deployment. Default fixture builds never select those live addresses.

### Live Hoodi indexing

[Harbor Studio](https://thegraph.com/studio/subgraph/harbor) version
`0.2.0-hoodi` indexes the new single-Book deployment from each contract's creation block.
Query endpoint: `https://api.studio.thegraph.com/query/75221/harbor/0.2.0-hoodi`.
Deployment CID: `QmXa2RCMR7BR13SzYpc7poxqUvUVhbNBKiXUk6csRBfuqv`.
At indexed block 3,610,972, the provider returned the new Book/Vault, complete
bootstrap history, zero LP supply and no indexing errors. Both strategies were
present: **Lido · wstETH** through Aqua/SwapVM and **Lido · Withdrawal NFTs**
through direct NFT settlement. Periphery attribution uses the new wrapper.
This establishes bootstrap indexing before funding, not executed trading or
reorg testing. The previous deployment and its historical records remain intact.
Current contract receipts are recorded in `script/records/harbor-nft-hoodi.deployment.json`.
After indexing was ready, two LPs deposited 0.198354844916264502 WETH each
through Periphery. At indexed block 3,611,014, both deposit transaction hashes
were available, pool history was complete, and no indexing errors were reported.
The checkpoint at block 3,611,012 recorded 0.396709689832529004 WETH cash/NAV.
Funding and Aqua publication receipts are in `script/records/hoodi-nft-lp-funding.json`.
No trades were sent during deployment. Subsequent inventory seeding added
0.096125125337130969 wstETH and pending NFTs #5048–#5052 through actual sales.
At block 3,611,583 Graph had indexed all six seed trades without errors; live buy
quotes succeeded for the token inventory and all six held NFTs (including #5047
from separate activity). See the [seeding record](script/records/hoodi-inventory-seeding.json).
This is controlled testnet activity, not organic volume or completed issuer recovery.

```sh
npm --prefix graph run subgraph:build:hoodi
node --env-file=.env graph/scripts/verify-hoodi.mjs
node --env-file=.env --env-file=graph/.env graph/scripts/check-hoodi-provider.mjs
```

For a deliberately approved new Studio version, put `GRAPH_DEPLOY_KEY` and
`GRAPH_SUBGRAPH_SLUG` in ignored `graph/.env`, then run
`node --env-file=graph/.env graph/scripts/deploy-hoodi.mjs <version>`.
The wrapper rebuilds reviewed Hoodi inputs, uses the pinned CLI in-process and
keeps credentials out of OS arguments/auth files. Deployment updates Studio;
it does not publish onchain or configure billing. New versions can archive the
previous Studio version, so inspect existing versions before redeploying.

List catalogued candidates or inspect them through The Graph gateway:

```sh
npm --prefix graph run sources
node --env-file=graph/.env graph/dist/src/cli.js inspect
# Inspect only the currently working comparison candidates:
node --env-file=graph/.env graph/dist/src/cli.js inspect yearn-v2-ethereum ribbon-finance-ethereum arrakis-finance-ethereum arrakis-finance-optimism
```

Set `GRAPH_API_KEY` in ignored `graph/.env`, never in `.env.example`. The key
is transmitted only in an authorization header. The catalog pins public Messari
source IDs, observed deployment CIDs and repository metadata; it does not claim
those deployments index financially comparable data. An inspection pins queries
to a block hash, rejects indexing/version/deployment errors and reports remaining
admission checks. Explicit vault selections are used where configured; otherwise
discovery samples by source-reported TVL, not address order. A
successful query alone does not approve a source or prove current valuation.

The September 11 provider check succeeded for Yearn, Ribbon and Badger on Ethereum,
and Arrakis on Ethereum and Optimism, using the same query. Yearn Arbitrum remains
excluded for `MAINNET` metadata; Vesper remains excluded for indexing errors.
Inspecting all sources exits nonzero when any source fails, while retaining each
source's result. See [source verification](graph/sources/verification.json).

Every vault carries field-level quality and `returnComparable: false` until
financial review. Ribbon fee percentages are returned as null/`QUARANTINED`,
not zero: its pinned upstream [fee mapping](https://github.com/messari/subgraphs/blob/2711ac91ef119f321f65b339e10a57f9aa74f9d8/subgraphs/ribbon-finance/src/modules/Transaction.ts#L195)
has identifier/scaling defects; exact deployed-source correspondence is unproven.
Other fee values remain explicitly source-reported, not independently verified.
Missing share prices, including the selected Arrakis vaults, exclude returns
without discarding the source's other observations. No source has passed
financial-comparison admission. An indexed head does not make an old mark fresh.

For Ethereum history, set `GRAPH_RPC_URL_1` in ignored `graph/.env` to an approved
HTTPS RPC endpoint supporting `eth_chainId`, `finalized` and historical headers:

```sh
node --env-file=graph/.env graph/dist/src/cli.js history yearn-v2-ethereum 0xa258c4606ca8206d8aa700ce2143d7db854d168c 25800000 25950000
```

This explicit `FINALIZED_NUMBER` mode validates chain/finality, brackets the read
with canonical-header checks and rejects deployment changes. Historical Graph
hashes can remain null; the separately observed RPC hash is never substituted
into Graph metadata. Observation timestamps remain distinct from query-block
timestamps. See [historical verification](graph/sources/history-verification.json).
The existing hash-pinned reader still rejects missing hashes. Number-mode finality
is currently reviewed only for Ethereum; other chains fail explicitly pending a
chain-specific policy. Provider-trusted headers are not contract-value proofs:
archive `eth_call` parity, mark-update semantics and return admission remain
outstanding. This command emits observations, not an APY ranking.

Harbor checkpoint records describe their event position. Pending exit shares,
funded controller credit and actual payouts remain separate; no ticket-level
payout attribution is invented. Current NAV and executable limits still require
contract reads. External protocol comparisons require explicit asset, history,
fee/reward and methodology review, not matching token symbols or headline APYs.

Trade history joins the Book settlement to its matching, manifest-pinned Executor
completion inside the transaction receipt. Repeated intents remain distinct;
exact-input/output mode stays `UNKNOWN` when logs cannot prove it. Customer cash,
protocol fees and Vault cash are separate values. Final native realization does
not count cumulative proceeds as another recovery. Receipt sale/rebuy episodes
preserve their own basis, and a holder's payout is not automatically Vault income.

Canonical receipt templates replay creation-transaction mint/activation/transfer
logs idempotently. Matchstick tests cover that interpreter, not Graph Node's actual
template scheduling or reorg behavior; an engine-level smoke check remains required.
Each route's totals are route-local: receipt routes link to their source strategy,
but automatic parent/day rollups are not implemented yet. Use the shared queries
under `graph/queries/`; current claim status and valuations still need pinned RPC reads.

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

## Native ETH periphery

[`Periphery`](src/Periphery.sol) is an optional, immutable wrapper around the
existing Executor and its registered WETH pools. It is deployed on Hoodi at
`0x7f66f42dff023f5BDb6F12E471F9Ac90c0011FB8`, recorded with the
[current pool](script/records/harbor-nft-hoodi.deployment.json). Its native deposits,
token sales and raw-NFT sales were used in the recorded funding/seeding runs.
Older Periphery deployments remain in `script/records/archive/`; do not use
their addresses for the current pool. Approvals and Vault operator permissions
are address-specific and do not carry over between deployments. Constructor
arguments are the reviewed WETH and Executor addresses.

| Call | Value and result |
| --- | --- |
| `deposit(book, minShares)` | Send exact ETH; receive floor-rounded LP shares directly. |
| `mint(book, shares)` | Send maximum ETH; receive exact raw LP shares and an ETH refund. |
| `execute(book, trade)` | ETH in: receive tokens/whole receipts and refund unused ETH. Tokens/receipts in: send no ETH; receive native ETH. |
| `withdraw(book, assets)` | Claim exact funded WETH credit as ETH; returns claim units consumed. |
| `redeem(book, shares, minAssets)` | Consume exact funded claim units, receive ETH subject to minimum proceeds. |

For swaps, obtain the normal `Executor.quoteSwap(book, trade)` with
`trade.trader = periphery`, `trade.receiver = connectedWallet`. Encode that same
Trade into `Periphery.execute`. When WETH is input, exact input sends
`amountSpecified` ETH; exact output sends `limitAmount` (`maxIn`) ETH. When WETH
is output, approve the input token/receipt to Periphery and send zero ETH. The current VM
still enforces pricing, versions, deadlines, fees and indivisible receipts.
Periphery is the actual funding trader, not a trusted forwarder impersonating
the wallet. `NativeTrade` identifies the paying wallet for indexers alongside
the Executor event. For token/receipt sales the wrapper first quotes to validate
the original recipient and size collection, then executes with itself as WETH
receiver and unwraps to the caller. Only actual quoted input is pulled, so unused
`maxIn` remains in the user's wallet—even if maxIn is two and the user owns one
whole receipt. Locked execution must match this preview after token callbacks
or the entire transaction reverts. There is no fractional receipt trading.

LP exits remain asynchronous: call `Vault.requestRedeem` as the user, wait for
funding, then claim through Periphery. First grant
`Vault.setOperator(periphery, true)` from the controller wallet; ERC-20 share
approval alone does not grant claim authority. Periphery fixes both controller
and final ETH recipient to its caller. Operator authority can be revoked at any
time. Withdrawal calls do not checkpoint NAV: already-funded cash stays claimable
during a pricing/valuation outage. Receipt redemption is a separate issuer flow.

Security boundaries: only registered WETH Vaults and the fixed Executor can be
called, using typed entrypoints rather than arbitrary calldata. Allowances are
bounded by supplied ETH or quoted token input and cleared after execution. The shared Solady transient
guard remains held through unwrap/refund callbacks (Cancun required). Native
refund rejection rolls back the entire operation, including claim consumption.
Pre-existing donated WETH or forced ETH is never included in payouts; it has no
sweep path and must not be deliberately sent here. WETH's exact 1:1 semantics and
the Executor governor's reviewed registry remain trust assumptions. No unchecked
math or custom assembly is introduced, and no gas-saving claim is made.

Compact regression suite (real local Harbor/Aqua/VM, synthetic issuer marks):

```sh
forge test --match-contract PeripheryTest -vv
```

The fork tests are pinned to block 3,608,981. Three tests passed using the existing
deployed Harbor, Aqua, SwapVM, WETH and Lido: deposit/mint/refund and funded native
claims, all four inventory modes, and all four whole-receipt modes. Only the new
Periphery is deployed inside the fork. Test ETH and receipt-route operator calls
are fork-only; no token storage is edited. Nine local tests also passed, including
native sell payout failure/reentrancy and donation isolation. Reproduction needs
an RPC serving this block; missing historical state is not a pass.

```sh
FOUNDRY_PROFILE=fork forge test --match-path test/fork/Periphery.fork.t.sol -vv
```

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

[Hoodi configuration](script/config/hoodi.config.json) records two confirmed deployments
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
registered with Executor. The [deployment manifest](script/records/archive/harbor-hoodi.deployment.json)
records 17 successful transactions and 34 checked bindings/configuration values.
Admission activation and the approved 100-day price/mark publications succeeded
in eight subsequent transactions. Two LPs subsequently deposited
0.198241597034305708 WETH each, and route 0 was published as Aqua strategy version 1.
The [funding verification](script/records/archive/hoodi-lp-funding.verification.json) records
actual balances, fresh valuation, Aqua cash allocation and 16 successful receipts.
No additional token mocks were deployed. Lido runtime provenance
is not independently attested by this deployment record.

These are historical records for the previous pool, not the current deployment.
Its one-off verification and funding runners have been removed. Retain the records
for reconciliation; do not repeat that funding against the old pool.

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
node --env-file=.env script/deploy/hoodi-ops.mjs verify 0xf40826aFd0de1078bc4b39b77E87E42d3b35Fe6A 0x63C78337758eA9c98b4Ce6Cc9988E72e2D8F3303
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

`script/deploy/DeployHarborHoodi.s.sol` reuses the recorded Aqua/router/WETH/Lido
addresses. It deploys immutable Harbor contracts with zero protocol fees and
the signer in every administrative role. Required public configuration names
and units are in [hoodi-demo.env.example](script/config/hoodi-demo.env.example); fill
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
forge script script/deploy/DeployHarborHoodi.s.sol:DeployHarborHoodi --rpc-url hoodi --sig 'run()'
```

Review the explicit configuration, signer nonce, linked libraries, estimated gas
and transaction list before authorizing broadcast. The original local-only
`DeployHarbor` entrypoints remain gated. Foundry records broadcast transactions;
reconcile them before using `--resume`. Rerunning `run()` creates another pool.
Configuration can renew marks/prices; it is not a no-op inspection command.

The historical two-LP setup used [SeedHarborHoodi](test/base/SeedHarborHoodi.s.sol),
now retained only as a fork regression fixture. It wrapped
deployer ETH, transferred WETH and gas to each LP, deposited from each LP wallet,
refreshed valuation and published the Vault's Aqua strategy. The exact amounts
and mainnet USD reference are in [the funding manifest](script/records/archive/hoodi-lp-funding.json);
Hoodi assets have no monetary value. Keep broadcast records and do not repeat
initial funding. Other users can wrap/deposit through their frontend wallets.

The old funding/verification wrappers are removed. Current raw-NFT trading uses
issuer-wide Book policy, not per-ID receipt admission or an Aqua strategy per NFT.
Wrapped ERC-20 receipt markets remain a distinct, optional path.

### Script directory and current workflow

Run commands from the repository root. Keep credentials in ignored `.env`, never
in command arguments or public records.

```text
script/
  deploy/          local/core deployment, Hoodi setup and Aqua operations
  seed/            current trader inventory seeding and its operating guide
  config/          public network configuration and blank env templates
  records/         current deployment, LP funding and inventory receipts
    archive/       superseded deployment records; not active configuration
  demo/            local redemption demonstration
  pricing/         offchain pricing model and arithmetic tests
```

| Task | Entry point |
| --- | --- |
| Deploy/configure the current single-Book token + NFT pool | `script/deploy/deploy-nft-hoodi.mjs` |
| Deploy/check the reused Aqua and SwapVM dependencies | `script/deploy/hoodi-ops.mjs` |
| Add trader-owned wstETH and pending NFTs to existing inventory | `script/seed/seed-inventory-hoodi.mjs` |
| Review seeding amounts, approvals and stage ordering | [Inventory seeding guide](script/seed/INVENTORY-SEEDING.md) |
| Find current addresses | [Current deployment record](script/records/harbor-nft-hoodi.deployment.json) |
| Review completed inventory trades | [Inventory run record](script/records/hoodi-inventory-seeding.json) |

`DeployHarborNftHoodi` inherits the shared Hoodi/core deployment scripts; those
parents are dependencies, not duplicate deployments to run separately. Its `setup`
stage also deploys Periphery. Use the current wrapper's `run`, `setup`, and `seed`
stages only for a newly authorized deployment; the existing pool is already funded.

Moving source files has not moved or reset `broadcast/` or `cache/`. Script
basenames and broadcast entrypoints are unchanged, so existing receipt journals
still prevent accidental repeats. Never delete a journal to bypass reconciliation.
Historical JSON fields record their original commands; they are evidence, not
instructions to rerun removed scripts.
