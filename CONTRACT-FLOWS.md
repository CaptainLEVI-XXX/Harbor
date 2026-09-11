# Harbor contract flows

This describes the implemented contracts and their actual inputs. Start with the
responsibility map, then follow the numbered flows. Examples are illustrative:
use current addresses, versions, allowances and timestamps from your deployment.
This is unaudited hackathon code, not a mainnet-readiness or APY claim.

## High-level: who talks to whom?

| Component | Owns | Receives / returns |
| --- | --- | --- |
| HarborVault, per pool | Pool tokens, LP shares, withdrawal liabilities, coherent NAV | Deposits/shares; Book treasury context; funded cash payouts. |
| HarborBook, per pool | Portfolio, basis, FACE, prices, risk limits and authorization | Trade / issuer intent → computed amounts, permitted transfers and accounting. |
| HarborExecutor, shared | Thin trader-authenticated swap wrapper | Trade → actual input/output; collects input, calls Router, pays customer. |
| HarborSwapVMRouter, shared | Unmodified official VM dispatch/transfer machinery | Canonical Order + specified amount + encoded Trade → Extruction pricing and fee-aware settlement. |
| Official Aqua, shared | Maker/application/strategy/token allocations | Ship/dock/push/pull; it does not own Harbor LP entitlements or NAV. |
| LidoAdapter, pool-bound | All issuer-specific custody, valuation and recovery | Native request or NFT import → claim ID; claim observations → cash credit / fixed payout. |
| HarborClaimFactory, shared | Per-adapter admission and canonical receipt identities | Adapter + ClaimImport + receiver → one generic receipt clone. |
| HarborClaimReceipt, per claim | Transferable ownership of exactly one right | Transfer one unit; holder redemption burns it and requests its adapter credit. |

Book bases and linked libraries are implementation organization, not another set
of user-facing services. VaultCore belongs to the Vault deployment. LidoViews and
LidoClaims execute within LidoAdapter: **there is no separate LidoValuation deployment**.

```text
LP -- cash deposit --> Vault -- LP shares --> LP
                          |
                     Book ledger/rules <-- public pricing updater
                          |           |
                          |           +--> Adapter observations <-- mark publisher
                          |
Trader --> Executor --> SwapVM Router <--> Book settlement hooks
               ^              |
               |              +--> Aqua <--> Vault tokens
               +-- output     +--> fixed protocol-fee recipient

NFT owner --> Factory --> Adapter takes NFT custody
                 |
                 +--> generic receipt --> current holder
                                              |
Issuer --> Adapter's per-claim cash credit <-- receipt.redeem(receiver)
                 |
                 +--> authorized receiver, after atomic burn
```

Deposited LP funds leave the user's wallet. They stay in the pooled maker Vault
until used. An external receipt holder's NFT/cash belongs to that holder, **not**
automatically to the pool, even though its adapter is bound to that pool.

The normal swap uses one pricing calculation under lock, native SwapVM fees and
Aqua transfers. The obsolete direct/private-opcode prototype is removed;
callers use Executor's authenticated funding path. No Chainlink, per-fill signature,
report receiver or required indexer participates.

### Adding another pool

Reuse the deployed Executor, Router and Aqua. Deploy a separate Book/Vault pair
and its approved issuer adapter, then the Executor governor calls
`registerPool(book)`. Registration verifies reciprocal Book/Vault, asset, Executor,
Router and Aqua bindings, but does not prove implementation safety: governance
must review code and token behavior. `vaultOf(book)` is permanent; there is no
rebinding or deregistration. Each Book retains its own pause/risk controls.

The Book address is the pool ID supplied to quote/execute. The route number is
local to that Book. Callback data is `abi.encode(book, trade)`; VM instruction
arguments remain `abi.encode(trade)`. A transient active Book, exact order hash,
maker Vault and single-use funding capability bind settlement to that pool.
The shared Executor blocks nested execution across all pools, not just one pair.

`Book.ASSET()` and `Vault.asset()` identify pool cash. Router.WETH() is only the
official VM's wrapped-native configuration; a USDC-like pool need not use it.
Factories/receipt implementations are generic but fixed to one settlement asset.
Each integration must deliver that asset: no implicit FX or WETH-to-USDC recovery.
Lido is explicitly WETH-only; six-decimal support is exercised with a synthetic
prefunded issuer, not a newly approved production USDC strategy.

## Types, amounts and direction

Solidity integers have no fractional part. Cash and inventory use their own raw
units (approved fixed metadata: 6–18 decimals). FACE, NAV, basis, costs and fees
all use pool-cash units: 1 USDC-like token = 1e6, while 1 WETH = 1e18.
Conversion numerators/denominators map inventory raw units to cash raw units;
prices/factors use 1e18, fees use basis points, times use Unix seconds.
LP shares have a six-decimal offset (24 decimals for WETH, 12 for six-decimal cash).
A receipt has zero
decimals: **amount 1 means the whole right**, not 1e18.

Use exact integers/BigInt in tooling and decimal strings in JSON, not floating
point. A struct is an ordered ABI tuple; bytes32 is a fixed hash, while bytes is
variable-length encoded input. Calldata/memory describe Solidity data locations,
not additional client fields. Transaction receipts contain logs/status; return
values are directly available in simulations and contract-to-contract calls.

Side names are from the **Vault's perspective**:

| Customer action | Side | EXACT_IN | EXACT_OUT |
| --- | --- | --- | --- |
| Sell base/receipt for cash | BUY_BASE = 0 | Exact base units supplied | Exact net WETH received |
| Buy base/receipt with cash | SELL_BASE = 1 | Exact gross WETH supplied | Exact base units received |

Keep four quantities separate: nominal FACE, acquisition basis, current NAV mark,
and actual spendable cash. A pending entitlement may have all of the first three
and none of the fourth.

## 1. LP deposits cash or mints shares

```text
LP approves WETH to Vault
  -> deposit / mint
  -> Vault and Book coordinate and check independent fresh valuation
  -> Vault measures received cash, issues shares and commits NAV/supply together
```

Actual overloads:

```solidity
function deposit(uint256 assets, address receiver)
  public coordinated returns (uint256 shares);
function deposit(uint256 assets, address receiver, address controller)
  external coordinated returns (uint256 shares);
function mint(uint256 shares, address receiver)
  public coordinated returns (uint256 assets);
function mint(uint256 shares, address receiver, address controller)
  external coordinated returns (uint256 assets);
```

Deposit fixes cash and floors the share output; mint fixes shares and ceils the
cash input. The caller always supplies the WETH. In the three-argument versions,
the caller must be controller or its approved operator. That permission does not
allow taking the controller's WETH: the operator supplies its own cash and allowance.

```solidity
// Alice sends these; no native ETH msg.value.
weth.approve(address(vault), 5 ether);
vault.deposit(5 ether, alice);
```

Conversions use committed values, including during callbacks:

```text
shares = floor(assets * (supply + 1,000,000) / (NAV + 1))
assets = floor(shares * (NAV + 1) / (supply + 1,000,000))
mint cost uses the second calculation rounded up
```

There is no configured Vault deposit cap. maxDeposit/maxMint enforce numerical
headroom, fresh marks, physical backing, valid receiver and other entry gates.
Minimum seed/request sizes remain. Book maxBasisExposure and FACE capacity are
separate trading risk limits: depositing more does not increase them.

An exact preview is not reserved. These deposit/mint overloads have no explicit
minShares/maxAssets arguments. Unsolicited donations do not become managed income
or inflate accounted NAV. Unsafe ownerless/zero-NAV portfolios reject new issuance.

Source: [HarborVault](src/vault/HarborVault.sol), [VaultCore](src/vault/base/VaultCore.sol),
[VaultLedger](src/libraries/VaultLedger.sol).

## 2. Governance publishes an Aqua strategy

Each native RouteConfig fixes base, adapter, bid/ask bounds, buy/sell buffers,
maxExposure, maxPurchases, lossBudget and maxDailyRedemption. It is not a backend
instruction to transfer arbitrary tokens. Initially one or two native routes are
supported; each approved receipt later has its own stable route.

```solidity
function refreshStrategy(uint256 route) external returns (bytes32 hash);
```

Governor calls Vault. Vault calls Book.prepareStrategyFromVault(route, requester),
which returns canonical ISwapVM.Order, previous hash, base and managed quantity.
Vault docks the previous Aqua allocation if needed and ships the new encoded
order plus address[] tokens and uint256[] allocations.

The maker is Vault; the application is Router. Strategy salts advance on refresh.
Allocations are clamped to Aqua's uint248 domain and remain limited by Book's
shared cash/capacity checks. Two routes do not create two copies of the same cash.

Price publication alone does not replace the strategy. Refresh is needed for a
new route, changed strategy epoch or replenishment of an insufficient allocation.

## 3. Trader gets a quote and executes

```solidity
struct Trade {
  address trader;
  address receiver;
  address tokenIn;
  address tokenOut;
  uint256 route;
  Side side;
  AmountMode mode;
  uint256 amountSpecified;
  uint256 limitAmount;
  uint256 deadline;
  uint256 pricingVersion;
  uint256 configVersion;
  uint256 strategyVersion;
}

struct FillAmounts {
  uint256 traderIn;   // Actual input collected, never the full maxIn cap.
  uint256 traderOut;  // Actual output paid to receiver.
  uint256 routerIn;   // INNER pre-fee VM register.
  uint256 routerOut;  // INNER pre-fee VM register.
  uint256 fee;        // Pool-cash raw units; charged once by FeeProtocol.
}

function quote(address book, Trade calldata trade) external view returns (FillAmounts memory);
function quoteSwap(address book, Trade calldata trade)
  external view returns (uint256 input, uint256 output, bytes32 orderHash);
function execute(address book, Trade calldata trade) external returns (uint256 actualIn, uint256 actualOut);
```

For EXACT_IN, limitAmount is minOut. For EXACT_OUT, it is maxIn. Deadline is
inclusive; versions must match current pricing, configuration and strategy.

1. Read current route, versions and reusable parameters.
2. Construct Trade and call Executor.quoteSwap. It uses STATICCALL to run the
   actual canonical SwapVM program, including fees. No signature or reservation.
3. Approve tokenIn to Executor, then send execute as trade.trader.
4. Executor calls Book.prepareTrade. Book locks itself and Vault; no pricing or
   token collection occurs yet. Executor records a single-use callback context.
5. Executor passes current Order, amountSpecified and canonical taker data to
   Router.swap. FeeProtocol normalizes the specified register, then official
   Extruction calls Book.extruction with the live query, registers and Trade.
6. Book verifies the order/context/versions, reads live backing and prices once.
   It checkpoints independent pre-trade NAV and records core amounts/evidence.
   Receipt checks are part of this path, not an additional private opcode.
   Internally, its self-only `priceTrade` view shares the linked pricing boundary
   with previews; it cannot be called directly to bypass these checks.
7. After VM fees determine customer amounts, Router calls Executor's
   preTransferInCallback. It authenticates the full intent/order/token tuple,
   checks customer limits, consumes its capability, and collects actual input
   only. It then grants Router exactly that allowance.
8. Aqua moves tokens. Book's authenticated hooks measure Vault credits/debits,
   including the correct fee leg, and update inventory/basis.
9. Executor verifies Router's **customer** amount pair and order hash, clears
   allowance, pays receiver and checks that no trade residue remains.
10. Book rechecks selected live evidence, reconciles Vault cash, invalidates the
    post-trade cached mark and clears both locks.

Executor.quoteSwap runs the VM directly. Executor.quote provides the existing
five-field preview with fee breakdown; its read-only fee mapping shares the core
kernel but is not called during execution. Tests compare both paths. Upstream
uses msg.sender as query.taker; direct RPC Router simulations must use Executor
as from. quoteSwap supplies the correct caller automatically.

The encoded Trade is exactly 13 ABI words (416 bytes). There is no FillTerms,
per-fill signature, nonce or caller-supplied output-price authorization. Repeating
the same authorized intent is another trade against current state, not a replayed
permit. Failure of any callback, fee leg or final check reverts the entire swap.

### Fee arithmetic in plain words

Let G be Vault's gross bid, N its net ask and b the configured basis-point fee:

```text
Vault buys, exact base input: customer cash = G - floor(G*b/10,000)
Vault buys, exact cash output Y: inner cash = Y + floor(Y*b/(10,000-b))
Vault sells, exact base output: customer cash = N + floor(N*b/(10,000-b))
Vault sells, exact cash input X: inner cash = X - floor(X*b/10,000)
```

SwapVM uses b*1000 over its 10,000,000 denominator. Fees round down, unlike the old
ceil-fee path. Buy basis includes all Vault cash debited; sell proceeds exclude
the fee. The Executor never pays a second protocol fee.

Whole receipts cannot fill fractional/excess-cash requests. At a floor-fee
plateau, gross 999 and gross 1000 can both imply net 999 (at 10 bp). For a receipt
whose canonical bid is 999, the extension may reduce the intermediate exact-output
gross register by one, only when the authorized bid and final net output agree.
This is not a relaxation of customer exactness or a general amount override.

Source: [Executor](src/execution/HarborExecutor.sol),
[BookSettlement](src/book/base/BookSettlement.sol), [SwapVM guide](src/swapvm/README.md).

## 4. Pricing estimates are independent from NAV

```solidity
struct PricingPolicy {
  uint256 minDiscount;
  uint256 maxDiscount;
  uint256 buyMargin;
  uint256 sellMargin;
  uint256 buyCost;
  uint256 sellCost;
}
struct PricingParameters {
  uint256 discount;
  uint256 observedAt;
  uint256 validUntil;
  uint256 version;
  uint256 configVersion;
}
function configurePricing(uint256 route, PricingPolicy calldata policy) external;
function publishPricing(uint256 route, PricingParameters calldata parameters) external;
```

Governance configures a route's bounded policy once. The scoped updater publishes
only a versioned, expiring discount inside those bounds. It cannot change caps,
fees, ownership, payout recipients or NAV policy.

The backend may derive discount from joint remaining-time/recovery scenarios:

```text
discount = sum(probability * recovery_fraction / (1 + annual_rate * remaining_days/365))
value = verified nominal entitlement * discount
buy cash = value - operating cost - LP margin - incremental capacity penalty
sell cash = value + operating cost + LP margin - released capacity penalty
```

Contracts apply the existing cubic capacity potential, conservative bid/ask
rounding and a bounded integer size solver. No external call occurs inside its
inversion loop. Public mark-based bounds, cash reserves, LP exits, FACE and
basis/loss budgets remain hard gates. Parameters are assumptions, not fitted APY.

The separately authorized adapter publisher calls:

```solidity
function publish(
  uint256 inventoryFactor, uint256 claimFactor,
  uint256 time, uint256 expiry, uint256 nextVersion
) external;
```

These factors mark verified inventory and pending rights, not trade prices.
Finalized rights use verified claimable cash. Publication cannot move assets or
refresh Vault NAV by itself. Distinct delayed publisher controls remain; the
initial marking schema is fixed rather than cached as another Vault policy counter.

## 5. An external owner sells a pending withdrawal

First, factory governance approves the **adapter** with schedule(adapter), waits
the delay and calls activate(adapter). Independently, Book governance uses
scheduleClaimFactory(factory, sourceRoute, bid, ask), waits its delay and calls
activateClaimFactory(factory, adapter). Factory approval permits wrapping; Book
approval permits this pool to take exposure. Approval of one adapter is not global.

```solidity
enum CollateralKind { ERC721, ERC20_AMOUNT }

struct ClaimImport {
  CollateralKind kind;
  address asset;
  uint256 tokenId;
  uint256 amount;
  bytes data;
}

function wrap(address adapter, ClaimImport calldata input, address receiver)
  external returns (address receipt);
function receiptOf(address adapter, bytes32 claimId) external view returns (address);
```

For the initial Lido integration:

```solidity
// Alice owns the pending withdrawal NFT and sends both transactions.
queue.approve(address(adapter), withdrawalId);
address receipt = factory.wrap(
  address(adapter),
  ClaimImport(CollateralKind.ERC721, address(queue), withdrawalId, 1, ""),
  alice
);
```

The factory registers the deterministic clone before custody callbacks but mints
nothing yet. Adapter.importClaim verifies factory/canonical binding, actual owner,
supported issuer, pending status, unused identity and the exact expected NFT
callback. It takes the NFT, records TOKENIZED backing and returns the verified ID
and nominal entitlement. Only then does the factory activate one unit for Alice.
Any failure rolls back creation, registry, custody and mint together.

Lido claimId = keccak256(abi.encode(chainId, issuer, withdrawalId)).
Factory canonicality additionally keys by adapter. Closed bindings persist.
The adapter rejects ERC20_AMOUNT, foreign NFTs, amount != 1, nonempty import data
and finalized imports. A generic interface is not automatic issuer support.

Governor then calls registerClaimMarket(factory, receipt), receiving uint256 route,
configures that route's pricing and refreshes its Vault strategy. Alice approves
the receipt to Executor and sells amount 1 with BUY_BASE. Vault receives the unit;
Book adds its basis/FACE. Before acquisition it was not a pool asset.

## 6. Pool inventory becomes a native issuer claim

```solidity
struct RedeemIntent {
  uint256 chainId;
  address vault;
  address book;
  uint256 route;
  address adapter;
  uint256 adapterVersion;
  uint256 shares;          // Wrapped inventory units, NOT LP shares.
  uint256 minUnderlying;   // Minimum verified nominal entitlement.
  uint256 maxIds;
  uint256 positionVersion;
  uint256 epoch;
  uint256 nonce;
  uint256 deadline;
  bytes32 splitsHash;
}
function requestRedemption(RedeemIntent calldata intent, uint256[] calldata amounts)
  external returns (IHarborAdapter.Request[] memory);
struct Request { uint256 id; uint256 shares; uint256 entitlement; }
```

Only the configured keeper initiates a request. amounts has 1–8 wrapped-token
splits summing to intent.shares; splitsHash is keccak256(abi.encode(amounts)).
The intent binds this chain, Book, Vault, approved adapter/version, current position
version, redemption epoch, unused nonce, deadline and minimum entitlement.

Book locks, authorizes Vault's exact inventory transfer, and calls
Adapter.request(amounts, previousBalance). Adapter checks actual consumption,
creates issuer withdrawals owned by itself, verifies each ID/nominal amount and
returns Request[]. Book moves basis into NATIVE_VAULT claims and maintains FACE.
No cash is created; split-conversion floor dust is not recovery income.

For direct recovery after finalization:

```solidity
function claimRedemptions(uint256 routeId, uint256[] calldata ids, uint256[] calldata hints) external;
```

Anyone may call Book with 1–8 strictly increasing IDs and matching hints.
Book alone can call Adapter.claim(id, hint). The adapter verifies issuer state,
measures actual ETH, wraps exactly that amount and pays **the fixed Vault**.
Book records actual recovery/loss and retires the closed right's basis/FACE.
Missing quotes, retired admission or a revoked keeper cannot redirect/block this
payout. Pending issuer state still cannot be forced to finalize.

The generic ledger supports partial recovery; the initial Lido adapter closes a
whole request. Partial-ledger tests are not proof that Lido supports partial claims.

### Export instead of recovering natively

```solidity
function exportClaim(uint256 source, uint256 id, address factory)
  external returns (uint256 route);
```

Governor may export an approved pending native claim. The adapter irreversibly
changes its domain to TOKENIZED; factory issues its unit directly to Vault.
**The NFT stays in the adapter.** Book moves the same basis and FACE into the
receipt route, without profit or additional lifetime purchase usage.

The old native Book payload closes and leaves a consumed-identity tombstone.
There is no reverse conversion or second payout. Governance must still publish
the new receipt route before selling it.

## 7. Receipt recovery and final-holder payout

```text
PENDING -- issuer finalizes --> FINALIZED
   -- anyone collects --> CASH_READY (adapter credit)
   -- current holder redeems --> CLOSED (unit burned, credit paid)
```

FINALIZED is a live issuer observation, not a redundant persisted flag. Only
pending rights trade through the initial Harbor program; finalized/cash-ready
units may transfer directly until burned.

```solidity
function recover(bytes calldata data) external returns (uint256 cash);
function redeem(address receiver) external returns (uint256 cash);

// Adapter boundary, used by the generic receipt:
function recoverTokenized(bytes32 claimId, bytes calldata data) external returns (uint256 cash);
function redeemTokenized(bytes32 claimId, address receiver) external returns (uint256 cash);
```

For Lido, data is exactly abi.encode(uint256 checkpointHint), 32 bytes. Generic
components forward it opaquely; the adapter validates/decodes it. The hint helps
locate issuer proof data, not estimate waiting time or authorize payout.

Recovery is permissionless and has no receiver argument. Adapter collects exact
claim-attributable ETH, wraps it, records this claim's cash and increases
totalClaimCash. Donations are not credited. It does not pay the recovery caller.

The current holder calls receipt.redeem(receiver). An ERC-20 allowance alone
cannot authorize this payout. Receipt burns its one unit; only that canonical
receipt may debit the matching adapter credit. Adapter closes and debits before
payment, checks aggregate backing and measures the payout. Everything reverts
together on failure, restoring both unit and credit.

| Example state | What is permitted? |
| --- | --- |
| Claim A has 0.8 cash; B is pending | A may redeem; B cannot consume A's cash. |
| A has 0.8; B has 1.7; actual adapter cash is 2.5 minus 1 wei | Both payouts stop; the first caller cannot drain another claim's backing. |
| Both are backed; issuer RPC/contract observation is unavailable | Already-credited payout needs no issuer read. |
| Factory retires adapter / mark publisher disappears | Existing credited holder payout still works. |
| Payment transfer fails | Burn, closed status and credit debit all roll back. |

Receipts cannot transfer during their own recovery/redemption, including a direct
adapter recovery callback. Cash-ready/closed status uses Harbor state, not Lido.

When Vault holds the unit, anyone uses Book, not a fabricated holder call:

```solidity
function recoverClaim(uint256 route, bytes calldata data) external returns (uint256 cash);
```

Book selects the exact adapter/claim under its RECOVERY context; Vault recovers
if necessary and redeems its unit. The adapter pays Vault, Book removes the position,
and Vault records measured spendable WETH. If already CASH_READY, data may be empty.
Bob's externally held receipt can never be redirected to Vault through this path.

## 8. LP requests, funding and payout

```solidity
function requestRedeem(uint256 shares, address controller, address owner)
  external returns (uint256 requestId);
function fulfillWithdrawals(uint256 maxTickets) external;
function withdraw(uint256 assets, address receiver, address controller)
  public returns (uint256 shares);
function redeem(uint256 shares, address receiver, address controller)
  public returns (uint256 assets);
function setOperator(address operator, bool approved) external returns (bool);
```

1. Owner/operator or share-allowance-authorized requester escrows LP shares.
   Controller receives the request entitlement; internal FIFO tickets order it.
   ERC-7540 aggregate requestId is zero, distinct from the internal ticket ID.
2. Anyone funds at most maxTickets, using fresh independent NAV and only actual
   free cash. Funding burns the priced shares and reserves their WETH. An
   incompletely funded head remains at the head.
3. Controller or its operator withdraws/redeems already-funded credit. Allowance
   to request shares is not permission to steal controller credit. Cash comes
   from reserves, never a pending issuer promise.
4. Reserved cash cannot be traded or paid twice. Already-funded claims do not
   require a fresh quote/mark; physical backing remains mandatory.

Queued shares still bear portfolio risk until funded. A requested exit is not
a fixed, instant cash promise. No automatic queue cancellation is exposed.
previewWithdraw/previewRedeem revert for asynchronous exits; maxWithdraw and
maxRedeem show existing claimable amounts. Ordinary share transfer/operator updates
use the Vault's local lock; economic flows retain coordinated Book/Vault locking.

## 9. Live observations, records and replaceable indexing

```solidity
function valuation()
  external view returns (uint256 inventory, uint256 claims, uint256 observedAt, bytes32 evidence, bool valid);
function valuationIdentity() // Vault
  external view returns (bytes32 evidence, uint256 observedAt, bool fresh);
function observePortfolio(address base, uint256 quantity, bytes32[] calldata claimIds) // Adapter
  external view returns (InventoryObservation memory inventory, ClaimObservation[] memory claims);
```

InventoryObservation contains entitlement, mark, observedAt, observationHash and
valid. ClaimObservation contains domain, status, entitlement, mark, cash,
observedAt and valid. Inputs must be known, unique IDs (at most 64), and output
order matches input. Issuer pending/finalized reads are batched; credited/closed
rights do not depend on the issuer. Pool NAV includes only Book-owned rights.

For a receipt quote, the registered nominal amount supplies the whole claim's
fixed FACE. Book then reads one live adapter observation and requires that its
entitlement still equals that registered amount. It does not call the receipt's
entitlement getter to read the same issuer state again. The mutable mark, status,
custody and post-callback evidence checks still run; fixed FACE is not cached NAV.

For portfolio valuation, Book gathers native claim IDs first and held receipt IDs
second, separately for each source route. The adapter rejects unknown or duplicate
IDs without sorting the output. Book then validates each returned observation
against that right's ownership domain and backing before accepting the total.

FACE = live inventory conversion + nativeClaimsFace + heldReceiptsFace.
Request/export changes representation, not available capacity. A CASH_READY receipt
retains FACE until sale or redemption into the Vault. Exact NAV still needs a
bounded portfolio observation; it is not a constant-time cached-price shortcut.

Vault freshness compares independent current marks and evidence with its cache.
Same-block finalization, recovery or mark change invalidates reuse; timestamps
alone are insufficient. Transient preparation rechecks selected evidence across
callbacks. The supported-token assumption excludes arbitrary callbacks changing
unselected issuer state. This is a material integration trust boundary.

| Keep onchain | Why future execution needs it |
| --- | --- |
| Shares, operators, FIFO pending/funded credit, reserves | Ownership and bounded, authorized LP payout. |
| Managed quantities/basis, nominal totals, cumulative loss/purchase budgets | Exposure limits and correct eventual realization. |
| Claim domain/stage/nominal/cash, canonical receipt, totalClaimCash | Exact backing, native-versus-holder attribution, no double payment. |
| Admission, role delays, price versions/expiry, keeper nonce/tombstones | Permission, freshness, replay prevention. |
| Coherent NAV/supply/marks, validity/time/evidence | Safe conversion, new issuance and exit funding. |
| Transient locks/phase/prepared amounts/callback context | Atomic settlement authority; cleared after success. |

Histories, APY charts and activity feeds come from events, not persistent trade lists.
The reporting-only Book portfolioVersion and Vault portfolioHash round-trips are
removed. FillSettled now carries the relevant positionVersion; current position,
price, configuration and strategy versions still enforce their separate mandates.
Useful events include ClaimWrapped, ClaimImported, Activated, ClaimExported,
ClaimCashCollected, ClaimPaid, Redeemed, scoped admission events, TradeExecuted,
ReceiptAcquired/Disposed, NativeClaimExported, PositionRealized, RedemptionRequested/
Recovered, LiquidityIssued, WithdrawalQueued/Funded and ValuationCommitted.
Token Transfer logs track current receipt/share ownership. Fixed issuer/token
bindings come from verified constructor manifests and adapter getters.

The shared Executor emits `PoolRegistered(book, vault, asset)` with all three
addresses indexed. `TradeExecuted` now indexes Book, context and trader; receiver,
route, amounts, cash-denominated fee and pricing version are event data. This is
a breaking event ABI: indexers must associate local route IDs with the indexed
Book, not assume one Executor equals one pool. Onchain entitlements still come
from each Book/Vault, never from reconstructed trade history.

Use chain + emitter + transaction/log index and retain block hashes. On reorg,
undo orphaned events and replay canonical blocks. Rebuild from deployment with
ABIs/constructor/link manifests and archive/log access. Issuer finalization may
occur without a Harbor event, so refresh live issuer observations.

Direct RPC users can still quote/execute, transfer units, discover active claims,
recover, fund exits and claim without the frontend or indexer. Live pages use
activeNativeClaims, activeReceiptRoutes and withdrawalTickets (1–32 entries);
pin all pages to the same block because swap-pop offsets can change.
New issuer requests still need the keeper, admission still needs governance and
new risk-taking needs available, fresh estimates. No offchain APY is payout authority.

## 10. Deployment and review boundaries

Use fresh immutable core deployments and Aqua orders for this breaking ABI change.
New pools can subsequently reuse the new shared Executor/Router and same-asset
factory. DeployHarbor.runLido on chain 31337 creates or reuses shared dependencies,
predicts Book/Vault/adapter addresses (including the registration transaction nonce)
and checks reciprocal
bindings/runtime limits. It does not bypass governance delays or publish forecasts.

Old immutable receipts and LP obligations remain supported by their original
contracts; this refactor does not migrate them. Any funded migration needs its own
explicit authorization and reconciliation procedure. External issuer upgrades,
trusted estimates, concentrated adapter custody, tight Book bytecode margin and
real-world gas/quote acceptance remain material risks.

See [DEMO.md](DEMO.md) for local token-transfer demonstrations and four separately
pinned fork checks. The suite remains 50 entrypoints; discovery/compilation is not
evidence that an RPC-backed test ran. No mainnet, frontend or indexer deployment
is implied by this guide.
