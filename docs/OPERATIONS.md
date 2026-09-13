# Harbor operating reference

Commands are run from the repository root. Historical counts and observations
describe their recorded runs, not live guarantees. Broadcasts require approval.

## Development and testing

```sh
forge install
forge build --sizes
forge test
forge fmt --check
```

Read [CONTRIBUTING.md](../CONTRIBUTING.md), the [SwapVM guide](#aquaswapvm-execution)
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

The shared [Hoodi fixture](../test/base/HoodiFork.sol) pins chain 560048 and queue
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
24,576-byte absolute runtime limit and [committed sizes](../snapshots/HarborRuntimeBytes.json).
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

### Controlled Hoodi setup

`script/deploy/DeployHarborHoodi.s.sol` reuses the recorded Aqua/router/WETH/Lido
addresses. It deploys immutable Harbor contracts with zero protocol fees and
the signer in every administrative role. Required public configuration names
and units are in [hoodi-demo.env.example](../script/config/hoodi-demo.env.example); fill
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

The historical two-LP setup used [SeedHarborHoodi](../test/base/SeedHarborHoodi.s.sol),
now retained only as a fork regression fixture. It wrapped
deployer ETH, transferred WETH and gas to each LP, deposited from each LP wallet,
refreshed valuation and published the Vault's Aqua strategy. The exact amounts
and mainnet USD reference are in [the funding manifest](../script/records/archive/hoodi-lp-funding.json);
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
  seed/            inventory seeding and staged Earn activity
  config/          public network configuration and blank env templates
  records/         current deployment, LP funding and inventory receipts
    archive/       superseded deployment records; not active configuration
  pricing/         offchain pricing model and arithmetic tests
```

| Task | Entry point |
| --- | --- |
| Deploy/configure the current single-Book token + NFT pool | `script/deploy/deploy-nft-hoodi.mjs` |
| Deploy/check the reused Aqua and SwapVM dependencies | `script/deploy/hoodi-ops.mjs` |
| Add trader-owned wstETH and pending NFTs to existing inventory | `script/seed/seed-inventory-hoodi.mjs` |
| Populate Earn activity on the existing pool | `script/seed/PopulateEarnHoodi.s.sol` |
| Review seeding amounts, approvals and stage ordering | [Inventory seeding](#hoodi-inventory-seeding) |
| Find current addresses | [Current deployment record](../script/records/harbor-nft-hoodi.deployment.json) |
| Review completed inventory trades | [Inventory run record](../script/records/hoodi-inventory-seeding.json) |

`DeployHarborNftHoodi` inherits the shared Hoodi/core deployment scripts; those
parents are dependencies, not duplicate deployments to run separately. Its `setup`
stage also deploys Periphery. Use the current wrapper's `run`, `setup`, and `seed`
stages only for a newly authorized deployment; the existing pool is already funded.

Moving source files has not moved or reset `broadcast/` or `cache/`. Script
basenames and broadcast entrypoints are unchanged, so existing receipt journals
still prevent accidental repeats. Never delete a journal to bypass reconciliation.
Historical JSON fields record their original commands; they are evidence, not
instructions to rerun removed scripts.

## Aqua/SwapVM execution

Ordinary ERC-20 swaps use the pinned official router and Extruction to invoke
Book pricing. HarborProgram supplies the version salt, hooks and native VM fee
branches; HarborPricing encodes the extension arguments. The Book authenticates
context, computes the core amount pair, binds settlement and checks actual
transfers. Raw issuer NFTs use the same Book through direct NFT settlement,
not a separate Aqua strategy per token ID.

Use Executor.quoteSwap(book, Trade) to evaluate the complete VM program.
Execution recomputes against current state; a quote reserves no liquidity.
The funding callback is bound to the selected Book/Vault, router, order and
trade. Pending claims never become spendable cash until actual recovery.

Run the local settlement demonstrations directly:

```sh
forge test --match-contract RedemptionMarketTest --match-test "test_(FourModes|ExportSell)"
forge test --match-contract HarborSettlementTest --match-test testFuzz_DepositPurchaseClaimRecoveryAndLpPayout --fuzz-runs 1
```

## Hoodi inventory seeding

This script populates the existing, funded Harbor Vault. It does not deploy contracts,
repeat LP deposits, create a buyer, buy back inventory, or fabricate activity.
LP_A and LP_B retain their shares. Trader A supplies token inventory; Trader B supplies
pending withdrawal NFTs. Sale proceeds remain with their respective traders.

### Inputs before broadcast

Use ignored `.env` for existing `HOODI_PRIVATE_KEY`, `HOODI_RPC_URL`, `LP_A`, `LP_B`
and two distinct signing keys, `TRADER_A` and `TRADER_B`. See
`script/config/inventory-hoodi.env.example` for public pool overrides. Do not put keys in
commands or committed files. This workflow does not generate or print private keys.

Agree the two new trader funding budgets, gas allowance, token inventory lot, NFT
count/sizes and minimum remaining Vault cash before broadcasting. Amount arguments
are integer wei, **not dollars**. For USD budgets, freeze a named ETH/USD observation
and its timestamp in the operator run record before converting to wei.
There is no default percentage allocation and no automatic sweep of wallet balances.

### Sequence

Every command below simulates only. Add `--broadcast` after reviewing the amounts
and explicit authorization. Replace uppercase placeholders; quote arrays without spaces.

1. **Fund traders, not LPs.** New principal plus a separate native gas top-up:

   `node --env-file=.env script/seed/seed-inventory-hoodi.mjs fund A_PRINCIPAL B_PRINCIPAL GAS_FLOOR`

2. **Acquire wstETH through Lido**, using explicit native amounts:

   `node --env-file=.env script/seed/seed-inventory-hoodi.mjs stake-a A_ETH MIN_A_WSTETH`

   `node --env-file=.env script/seed/seed-inventory-hoodi.mjs stake-b B_ETH MIN_B_WSTETH`

   The script checks the wstETH balance increase. This minimum is a simulation/
   receipt-review condition, not an onchain min-mint argument to Lido's receive function.
   Other wallet assets remain untouched. Leave native ETH for gas.

3. **Create 1–8 differently sized pending NFTs** from Trader B's wstETH:

   `node --env-file=.env script/seed/seed-inventory-hoodi.mjs request '[AMOUNT_1,AMOUNT_2,AMOUNT_3]'`

   Amounts are wstETH raw units. The script checks their stETH conversions against
   Lido's request bounds. The wrapper prints **confirmed IDs from mined
   WithdrawalRequested events** after broadcast. Never use IDs from Forge's simulation
   output for the next step: another user may mint before this transaction.

4. **Sell Trader A's chosen wstETH lot into Harbor**:

   `node --env-file=.env script/seed/seed-inventory-hoodi.mjs token WSTETH_AMOUNT MIN_ETH_OUT CASH_FLOOR`

   Exact token approval → Periphery → Aqua/SwapVM → Vault inventory.
   The Vault pays WETH; Periphery returns native ETH to Trader A.

5. **Sell the confirmed pending NFTs into Harbor**:

   `node --env-file=.env script/seed/seed-inventory-hoodi.mjs nfts '[ID_1,ID_2,ID_3]' '[MIN_ETH_1,MIN_ETH_2,MIN_ETH_3]' CASH_FLOOR`

   Per-ID NFT spending approvals are user permissions to Periphery, **not governor
   admission**. Book's issuer-wide policy prices the IDs. The adapter holds the NFTs
   and Book records their backing. There are no receipt clones or direct donations.

6. **Checkpoint NAV and refresh the Aqua allocation**:

   `node --env-file=.env script/seed/seed-inventory-hoodi.mjs publish`

   Token inventory is now allocated alongside remaining WETH. Raw NFTs use the
   same Book's direct settlement and do not need individual Aqua strategies.
   No buyer is used: inventory stays available for incoming users.

### Safety and operating limits

- The script targets Hoodi, the reviewed WETH/wstETH bindings, and zero protocol fees.
- Positive minimum sale proceeds are encoded in every actual Harbor trade.
- The remaining-cash floor is checked during simulation, using trading cash after
  funded-exit reserves. It is **not an atomic cash reservation across broadcasts**.
  Other trades can change balances between transactions. Re-simulate each stage;
  Harbor still enforces its onchain cash/risk gates. Do not run stages concurrently.
- Fresh pricing versions/generation and deadlines can invalidate prepared trades.
  Newly minted claims must still be pending at execution; finalization cannot be postponed.
- Stages contain multiple transactions. A later failure does not undo earlier mined
  funding, staking or approvals. The wrapper writes an exclusive per-stage journal
  before broadcast and blocks duplicate attempts. Preserve it, reconcile mined
  receipts and resume only known unmined transactions; never blindly clear the journal.
- Publish again only as a separately reviewed operation after reconciling the journal.
- Graph is already indexing this pool from deployment. Confirm its two strategy rows,
  trades and held NFT IDs catch up; do not present testnet activity as organic volume.

### Focused test

The existing fork deployment lifecycle is extended, not duplicated: two LPs, two
traders, real Lido staking/request creation, token/NFT sales, retained inventory,
cash/payout reconciliation, unchanged LP shares, executable asks and rejection of
duplicate NFT sales or a breached cash floor. All funds and identities are test-only.

`FOUNDRY_PROFILE=fork forge test --match-contract DirectNftForkTest --match-test test_ForkDeploymentScriptTwoLPsPoliciesAllocationAndFreshNftQuote -vv`

The fixture pins Hoodi block 3,612,478 and needs an RPC serving that historical state.
No live transaction is sent by this test.

## Populate the Hoodi Earn history

`PopulateEarnHoodi.s.sol` operates the **existing indexed pool**. It deploys nothing.
Run each stage separately; this is not a single atomic or automatically scheduled run.
No live transactions were authorized merely by writing this script.

### Wallets and requirements

Keep these existing values in the repository's ignored `.env`:

- `HOODI_RPC_URL`, `HOODI_PRIVATE_KEY` (current governor/deployer).
- `LP_A`, `LP_B` (existing LP signing keys).
- `TRADER_A`, `TRADER_B` (two distinct existing test traders).
- Optional `INVENTORY_BOOK`, `INVENTORY_PERIPHERY` overrides from the existing inventory workflow.

No random wallets or additional keys are needed. Never paste keys into a command,
chat, source file or committed example. Foundry loads the repository `.env`.
The base script verifies Hoodi 560048, current WETH/wstETH/queue and pool bindings,
distinct traders, zero protocol fees, and that both existing LPs retain shares.
This is not a fresh-pool deployment tool or a full-LP-exit tool.

All money is integer **wei**, not dollars. ETH, WETH and wstETH have 18 decimals;
LP shares have 24. `1000000000000000` means 0.001 ETH or wstETH;
`100000000000000000000` means 0.0001 whole LP shares. Do not confuse the units.
Minimum shares must come from the current `previewDeposit`, with an explicitly
accepted tolerance. Trade limits must come from current quotes, not this document.

Required balances depend on your chosen lots. Reuse existing inventory first.
For small ~0.001–0.005 ETH-equivalent trades, a **reviewed** 0.03 ETH total balance
per trader is a reasonable demo starting budget, not an automatic transfer.
Leave a separate gas allowance (for example 0.002 ETH; actual gas can differ).
Deployer pays only explicit top-ups and keeper/checkpoint transactions.
Traders pay trading gas; LPs pay their own deposit/request/claim gas.

### Invocation

From the Harbor contract repository:

```sh
EARN_SCRIPT=script/seed/PopulateEarnHoodi.s.sol:PopulateEarnHoodi
forge build script/seed/PopulateEarnHoodi.s.sol
forge script "$EARN_SCRIPT" --rpc-url hoodi --sig 'checkpoint()' -q
```

Every command below **simulates only** unless you append `--broadcast --slow`.
Use `-q` with real credentials so verbose script traces do not expose environment
reads. Never enable `-vvvv` or publish raw traces containing signing keys.
Review the intended calldata/amounts before broadcasting, and keep Foundry's
ignored `broadcast/PopulateEarnHoodi.s.sol/560048/` records for reconciliation.
Do not run stages concurrently. A failed later transaction does not undo earlier
mined approvals, deposits or transfers. Reconcile every receipt before retrying;
do not blindly rerun a stage or use `--resume` after its trade deadline expires.
Top-ups are balance-targeted, but deposits/trades/staking are intentionally repeatable.

Replace uppercase placeholders with reviewed integer values; they are not defaults.
`first=true` selects A and `false` selects B. `sell=true` means the **trader sells**.

### Stage 1 — optional funding and asset acquisition

Skip new funding/staking if existing wallet assets suffice. These are not chart profit.

```sh
## lp=false: trader. lp=true: LP. Target is the TOTAL native balance, not an increment.
forge script "$EARN_SCRIPT" --rpc-url hoodi --sig 'topUp(bool,bool,uint256)' false true TARGET_A_WEI -q
forge script "$EARN_SCRIPT" --rpc-url hoodi --sig 'topUp(bool,bool,uint256)' false false TARGET_B_WEI -q

## Lido's native receive entrypoint stakes and wraps. ETH amount excludes the gas reserve.
forge script "$EARN_SCRIPT" --rpc-url hoodi --sig 'stake(bool,uint256,uint256)' true ETH_WEI MIN_WSTETH -q
forge script "$EARN_SCRIPT" --rpc-url hoodi --sig 'stake(bool,uint256,uint256)' false ETH_WEI MIN_WSTETH -q

## Trader B creates 1–8 pending withdrawal NFTs from explicit wstETH lots.
forge script "$EARN_SCRIPT" --rpc-url hoodi --sig 'requestNfts(uint256[])' '[LOT_1,LOT_2]' -q
```

After minting, obtain **actual token IDs from the mined Lido `WithdrawalRequested`
logs**, or read `getWithdrawalRequests(traderB)` and verify ownership/status.
Forge's simulation IDs are predictions and MUST NOT drive later live trades.
Lido staking's min-minted check is simulation-only; its receive function has no
onchain min-output argument. Keep the staking budget small and explicit.

### Stage 2 — token trading, all four modes

```sh
## first, sell, exactIn, amountSpecified, limit, remaining cash floor, remaining inventory floor
forge script "$EARN_SCRIPT" --rpc-url hoodi --sig 'tradeToken(bool,bool,bool,uint256,uint256,uint256,uint256)' true true true WSTETH_IN MIN_ETH CASH_FLOOR WSTETH_FLOOR -q
forge script "$EARN_SCRIPT" --rpc-url hoodi --sig 'tradeToken(bool,bool,bool,uint256,uint256,uint256,uint256)' true true false ETH_OUT MAX_WSTETH CASH_FLOOR WSTETH_FLOOR -q
forge script "$EARN_SCRIPT" --rpc-url hoodi --sig 'tradeToken(bool,bool,bool,uint256,uint256,uint256,uint256)' false false false WSTETH_OUT MAX_ETH CASH_FLOOR WSTETH_FLOOR -q
forge script "$EARN_SCRIPT" --rpc-url hoodi --sig 'tradeToken(bool,bool,bool,uint256,uint256,uint256,uint256)' false false true ETH_IN MIN_WSTETH CASH_FLOOR WSTETH_FLOOR -q
```

Sales approve only the chosen token budget to Periphery, then receive ETH.
Purchases fund Periphery with ETH; it wraps WETH, trades through Aqua/SwapVM,
and returns any exact-output refund. The Vault's sales can realize trading P/L;
acquisitions alone increase inventory and cost basis, not realized profit.
After adding inventory or materially changing cash, use inherited `publish()`
to checkpoint and refresh the existing Aqua allocation. This does not publish prices.

### Stage 3 — NFT trading, all four modes

```sh
## first, sell, exactIn, confirmed token ID, cash min/max, remaining cash floor
forge script "$EARN_SCRIPT" --rpc-url hoodi --sig 'tradeNft(bool,bool,bool,uint256,uint256,uint256)' false true true OWNED_ID MIN_ETH CASH_FLOOR -q
forge script "$EARN_SCRIPT" --rpc-url hoodi --sig 'tradeNft(bool,bool,bool,uint256,uint256,uint256)' true false false HELD_ID MAX_ETH CASH_FLOOR -q
forge script "$EARN_SCRIPT" --rpc-url hoodi --sig 'tradeNft(bool,bool,bool,uint256,uint256,uint256)' true true false OWNED_ID MIN_ETH CASH_FLOOR -q
forge script "$EARN_SCRIPT" --rpc-url hoodi --sig 'tradeNft(bool,bool,bool,uint256,uint256,uint256)' false false true HELD_ID MAX_ETH CASH_FLOOR -q
```

Every operation settles **one original NFT**. Cash-exact modes derive their exact
cash amount from the canonical one-NFT quote; an intervening price change can
revert rather than fractionalize the right. `quoteNft(bool,bool,uint256)` is a
read-only script entrypoint. Ordinary `tradeNft` already validates its live quote.
Do not exhaust inventory just to produce a chart: keep several pending IDs available
for visitors. Finalized IDs are recovery-only, not available at the pending ask.

### Stage 4 — LP activity and the existing queue

```sh
## Optional additional deposit; explicit assets and minimum shares, never all wallet funds.
forge script "$EARN_SCRIPT" --rpc-url hoodi --sig 'depositLp(bool,uint256,uint256)' true ETH_WEI MIN_SHARES -q

## Skip requestExit when that LP already has a pending request. Funding can serve any user.
forge script "$EARN_SCRIPT" --rpc-url hoodi --sig 'requestExit(bool,uint256)' true SHARES_RAW -q
forge script "$EARN_SCRIPT" --rpc-url hoodi --sig 'fundExits()' -q

## Read maxWithdraw(LP) first. Exact cash in wei, not LP shares or pending entitlement.
forge script "$EARN_SCRIPT" --rpc-url hoodi --sig 'claimExit(bool,uint256)' true FUNDED_ASSETS_WEI -q
```

`requestExit` retains some LP shares and rejects an existing pending request to
catch accidental repetition. `fundExits` processes at most eight FIFO tickets;
it may fund other users, partially fund a request, or fund nobody. `claimExit`
grants operator permission if necessary, then claims through Periphery as native ETH.
Only the controller can authorize this payout. The script cannot claim for a
connected frontend user whose key it does not possess; that user claims in the UI.
No automatic claim is bundled into the request/funding stage.

### Stage 5 — issuer requests and real recovery

```sh
forge script "$EARN_SCRIPT" --rpc-url hoodi --sig 'requestIssuer(uint256,uint256,uint256,uint256)' WSTETH_RAW MIN_UNDERLYING UNUSED_NONCE WSTETH_FLOOR -q
## Later, only after Lido actually finalizes the sorted, tracked IDs:
forge script "$EARN_SCRIPT" --rpc-url hoodi --sig 'recoverIssuer(uint256[])' '[FINALIZED_ID_1,FINALIZED_ID_2]' -q
```

The current governor must also be the configured keeper for `requestIssuer`.
It records a used nonce and moves inventory into a native claim; cash does not increase.
Use mined `RedemptionRequested` IDs, never simulated IDs. Recovery discovers Lido
checkpoint hints and pays the fixed Vault. It supports vault-owned raw NFT and
native requests, rejects pending/claimed IDs, and never impersonates a historical owner.
If there is no finalized tracked claim, **skip recovery** and show zero recovered cash.

### Stage 6 — observations and timing

```sh
forge script "$EARN_SCRIPT" --rpc-url hoodi --sig 'checkpoint()' -q
## Only when the Aqua allocation also needs refreshing; governor signs:
forge script "$EARN_SCRIPT" --rpc-url hoodi --sig 'publish()' -q
```

Use a few small trading sessions separated by hours over 12–24 hours, checkpointing
after each session. Returns use hourly buckets; many transactions in one minute
do not create a day's history. Checkpointing changes neither prices nor their expiry.
Do not alter marks to draw a profit curve. Respect independent valuation/pricing
expiry, pending LP exits and Harbor's onchain capacity gates.

Cash/inventory floors are **simulation guards**, not locks over multiple live
transactions. Encoded minOut/maxIn, versions, whole-ID checks, actual custody and
accounting remain enforced by Harbor. Re-simulate after other activity.
The current client reads at most 100 checkpoints and 1,000 trade/realization points;
do not spam checkpoints and assume unlimited history appears in one response.
Allow Graph to catch up and the API's cache to refresh. Deposits, payouts, trades,
realizations and recovery must be backed by real events and explorer hashes.
Label all seeded activity as controlled testnet activity, not organic volume or sustainable APY.


These stages use Foundry signing with configured test EOAs, not Privy. A live embedded-wallet flow must be demonstrated separately. No withdrawal is automatic: requestExit, fundExits and claimExit are separate opt-in stages. Omit requestExit and claimExit for inventory-only sessions.

## Historical issuer subgraph

This package indexes withdrawal requests, inclusive finalization ranges, and actual claims. It does not run the Harbor pricing model or store simulated trades. The research runner remains outside the repository; `backtesting/` is not needed.

### Current scope

The implemented issuer adapter is `lido-inclusive-v1`, with Ethereum history frozen at block 22,000,000. The second configuration (`fixture-arbitrum`) tests another chain ID and six-decimal metadata. It is not a deployed Arbitrum issuer or an additional historical dataset.

The data contract is reusable across chains. A new EVM deployment needs a reviewed chain/network binding, actual issuer address and ABI, start/cutoff blocks and canonical hash, chain-scoped assets, finality support, and reference evidence. A different issuer needs a semantic adapter. Non-EVM chains need a different ingestion implementation. One Graph deployment indexes one chain.

### Build and test

From the repository root, with Node 22+ and `graph/` dependencies installed:

```sh
npm --prefix graph run history:verify
```

This runs existing analytics checks, focused exporter/normalizer tests, identical-source Ethereum/Arbitrum builds, and native Matchstick fixtures on both builds. Matchstick 0.6.0 is required; Graph CLI uses its cached binary or downloads it on supported platforms. Build artifacts are isolated under `graph/history/.build/<series>/`.

For the full archived event replay:

```sh
npm --prefix graph run history:replay -- --reference "$RESEARCH_ROOT"
```

Run `history:build` first. The replay covers every archived event in bounded chronological windows using the production stub runtime. Each window starts from independently reconciled prior counters and the request prefixes needed by that window, then executes the compiled handlers and compares every stored field and closing counter. This avoids retaining an entire multi-year replay in one WASM allocation. It is a handler fixture replay, not continuous Graph Node indexing or rollback verification.

### Export a dataset

The reference archive contains `work/raw/{requested_complete,finalized_complete,claimed_complete}.json.gz`, `checkpoint_rates.json`, `study_snapshot.json`, frozen deployed-source evidence, `work/decoded/{requests,finalizations,claims}.csv`, and `outputs/boundary_audit.json`. Exact file hashes are pinned in `graph/history/evidence/<series>.json`; the original source files are not copied here.

```sh
npm --prefix graph run history:cache -- --reference "$RESEARCH_ROOT" --out "$DATASET_DIR"
```

Use a new external output directory or `graph/.local/history/<dataset>/`. This command always produces `CACHED_RESEARCH`, checks every historical record and exact cutoff totals, and refuses output overwrites. Amounts, shares, rates and IDs remain integer strings. Raw facts and future outcome labels are separate files.

After deploying the generated finite subgraph and checking the provider's retained history, set `HISTORY_GRAPH_URL`, `HISTORY_RPC_URL`, and the reviewed deployment CID in your environment. Do not put credentials in source files or command-line URLs.

```sh
npm --prefix graph run history:export -- --reference "$RESEARCH_ROOT" --out "$DATASET_DIR" --series ethereum-lido-2025-03 --deployment "$REVIEWED_DEPLOYMENT_CID" --mode STUDIO
```

Modes: `STUDIO` permits `https://api.studio.thegraph.com/query/...`; `GATEWAY` permits `https://gateway.thegraph.com/api/subgraphs/id/...` with `GRAPH_API_KEY` in the authorization header; `LOCAL` permits local Graph Node `/subgraphs/name/...` URLs. RPC header verification uses the existing HTTPS-only reader and requires `eth_chainId`, a numeric cutoff header, and `finalized`.

Every page is pinned to the same canonical block hash and deployment. Partial GraphQL errors, indexing errors, incomplete series, count/cursor mismatches, foreign series, and canonical changes abort the export. Resume files beside the output are bound to the query/configuration/deployment/cutoff identity and integrity-checked. Only successful Graph/reference comparison yields `GRAPH_VERIFIED`.

Datasets contain `manifest.json`, `facts.json`, `outcomes.json`, `checkpoints.json`, and `reconciliation.json`. Manifest content hashes use SHA-256 of JSON with lexically sorted object keys; source hashes are SHA-256 of exact bytes. Checkpoint evidence remains explicitly identified as cached cutoff storage, reconciled to observed claims. These labels must never be presented as historical Harbor executions.

### Adapter invariants

- Request IDs must start at 1 and be contiguous. Starting mid-queue without a separate verified bootstrap fails closed.
- Prefix sums let a finalization handler read at most two requests, regardless of batch size. The mapping stores a single inclusive range; expansion occurs offchain.
- Claims preserve both owner and receiver. A claim must follow finalization; exact checkpoint payout validation occurs in the normalizer.
- Recovery follows the deployed integer branch: use face unless `floor(face * 10^27 / shares) > checkpointRate`; otherwise use `floor(shares * checkpointRate / 10^27)`. A `min` simplification differs at rounding boundaries.
- Event replay is idempotent. Conflicting logical IDs or missing history leave a persistent incomplete flag and issue record.
- Network, series and entity domains are encoded into IDs. Monetary values are raw units; changing display decimals never rescales stored values.

### Adding a chain or issuer

1. Add and review the EVM chain ID/network binding in `graph/history/chains.json`. This does not by itself admit provider finality or source coverage.
2. Add a separate series in `graph/history/networks.json`, with actual onchain identities, complete coverage, immutable cutoff and reviewed finality. Use a new dataset version when extending a cutoff.
3. Reuse the Lido adapter only if the issuer's semantics and event signatures match. Otherwise implement and test a new adapter, including its prefix/range/recovery semantics and conversion rules.
4. Add a separately frozen reference evidence file and normalizer support. The current cache importer is for the Lido archive format; it is not a generic arbitrary-CSV upload API.
5. Compile and run fixtures, then index on Graph Node, test controlled canonical rollback, query the pinned cutoff, and reconcile real data. Promote source status only after those checks.

Build, replay and export commands do not change contracts or the live Harbor subgraph. Historical deployment is a separate command below. Offline checks do not establish live indexing, Graph Node rollback or hosted Graph export.

### Website pricing analytics

The client `/analytics` page reads a small checked artifact produced by `history:publish-analytics`. The graph indexes issuer facts; the external research study supplies the frozen pricing simulation. No research runner or raw simulation ledger is added to the contract repository.

The four display names are **Harbor**, **Fixed-delay pricing**, **Age-based pricing**, and **Queue-aware valuation**. Harbor is the main FACE research replay. Queue-aware valuation is the no-capacity comparison. They share a valuation forecast. Exact-contract parity and protocol-venue comparisons are not established by this study.

```sh
npm --prefix graph run history:publish-analytics -- "$DATASET_DIR" "$BENCHMARK_PREVIEW_DIR" "$CLIENT_DIR/data/analytics/benchmark.json"
```

This verifies the history manifest and every content hash, normalizes issuer outcomes, checks the original research input hashes, and reconciles the exact face, recovery and settlement time of all simulated fills against issuer history. All four ledger aggregates and histogram counts must match. It writes an atomic compact artifact with no credentials or local research paths. The command supports this frozen Ethereum Lido study only; another chain needs its own matching research dataset, not a metadata rename.

A cache export stays `CACHED_RESEARCH` in the page. Only a successful `history:export` followed by the publisher produces `GRAPH_VERIFIED`; this label describes issuer-history evidence, never live Harbor executions. The website can also read an atomically replaced artifact through its server-only `HARBOR_ANALYTICS_FILE` variable. With the bundled file, rebuild/redeploy the client after publication.

#### Completing the live hosting step

Use a separate historical subgraph slug, preserving the existing Hoodi trading subgraph:

```sh
## Configure GRAPH_DEPLOY_KEY and HISTORY_GRAPH_SLUG in the process environment.
npm --prefix graph run history:deploy -- ethereum-lido-2025-03 0.1.0
## Once indexing reaches the cutoff, configure HISTORY_GRAPH_URL and HISTORY_RPC_URL.
npm --prefix graph run history:export -- --reference "$RESEARCH_ROOT" --out "$GRAPH_DATASET_DIR" --series ethereum-lido-2025-03 --deployment "$REVIEWED_DEPLOYMENT_CID" --mode STUDIO
npm --prefix graph run history:publish-analytics -- "$GRAPH_DATASET_DIR" "$BENCHMARK_PREVIEW_DIR" "$CLIENT_DIR/data/analytics/benchmark.json"
```

`history:deploy` rejects the current `harbor` live slug, unknown series and build fixtures. It keeps the deploy key out of OS arguments and redacts credentials from CLI output. Deploying to Studio is distinct from publishing to the decentralized network; this command does not submit an onchain publication transaction.

At website implementation time no historical Graph endpoint, deployment CID or deployment credentials were configured. Live indexing/export and a controlled Graph Node rollback test therefore remain unexecuted. Offline checks must not be reported as those live tests.
