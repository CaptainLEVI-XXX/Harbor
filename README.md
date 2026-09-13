# Harbor

### Instant liquidity for redeemable assets and pending withdrawal rights

Harbor is an onchain market for **assets you can redeem and money you are still
waiting to receive**. Users can swap supported yield-bearing assets, sell an
eligible pending withdrawal right for immediate payment, or buy a right from
pool inventory and receive its eventual recovery.

Harbor connects people who need liquidity now with capital willing to wait.
Liquidity providers fund a shared vault that buys and sells across approved
strategies. Its pricing engine values expected recovery, accounts for the cost
of waiting and adjusts quotes to the pool's existing exposure. The pool can
resell what it buys or hold it through redemption; LPs share the resulting gains
and losses.

**The idea is simple: sell the right to wait, without waiting for the right to
settle.** Harbor does not accelerate the issuer's withdrawal queue. It gives
that obligation a buyer and a price.

The current demo runs on **Hoodi**. Contracts are unaudited. Instant execution
depends on an eligible asset, valid pricing and available pool liquidity.

## The problem

An asset can be redeemable without being cash today. Exit queues, issuer
finalization and settlement delays separate the right to receive funds from the
ability to spend them. This affects staking positions, yield-bearing dollar
assets and other vaults with asynchronous withdrawals. A token may trade freely
before redemption, while the resulting withdrawal claim has different ownership,
transfer and settlement rules.

Selling the original asset can provide an exit before redemption. Once a
withdrawal is requested, however, the holder may own a claim instead of that
asset—and an ordinary token swap cannot necessarily transfer or settle it.

Harbor serves both stages through one pool and a shared pricing and accounting
system. It treats a pending withdrawal as an obligation with a verifiable owner,
an estimated recovery and an uncertain settlement time, rather than assuming
its face value is already spendable cash.

## Market

The opportunity spans multiple redemption mechanisms:

- **Staking withdrawals.** Issuer queues and validator exits determine when
  underlying funds become available. Some protocols represent the right with a
  transferable NFT. [Lido withdrawal mechanics](https://lido.fi/how-lido-works/withdrawals)
- **Yield-bearing dollar assets.** Ethena's staking design includes an unstaking
  cooldown and a separate silo holding funds before withdrawal. The cooldown is
  configurable, so an integration must read its actual rules rather than assume
  a permanent seven-day delay. [Ethena staking](https://docs.ethena.fi/technical-design/staking-usde)
  · [Contract controls](https://docs.ethena.fi/technical-design/staking-usde/staking-key-functions)
- **Pending withdrawal rights.** The immediate liquidity opportunity is the
  outstanding claim, not the full value of the protocol that issued it. Harbor
  must establish enforceable control over recovery before buying that right.

### Market size and withdrawal activity

| Indicator | Reported scale | Date and source |
| --- | ---: | --- |
| Ethereum staking asset base | Approximately **$68B**; 43.1M ETH, including entry queue and excluding exit queue | June 30, 2026; [Lido H1 report](https://lido.fi/ldo-hub/reports/h1-2026) |
| Ethena USDe protocol TVL | Approximately **$4.60B** | Observed September 13, 2026; [DefiLlama](https://defillama.com/protocol/ethena-usde) |
| Lido gross staking outflows | Approximately **1.51M ETH** over six months | Sum of January–June 2026 monthly outflows in the [Lido H1 report](https://lido.fi/ldo-hub/reports/h1-2026) |

These measure different things: asset stock, protocol TVL and redemption-related
flow. Ethena's figure is neither its staked share alone nor its cooldown balance;
Lido's outflows are not outstanding claims. They should not be added together as
Harbor's addressable market, and underlying exposures can overlap.

The narrower market is **eligible redemption flow whose holders will accept a
discount for immediate liquidity**. Its size requires issuer-level outstanding
claims, settlement times, transferability and observed seller acceptance. We do
not yet have a verified cross-protocol dollar total for that market.

Ethena is a prospective integration, not a currently supported Harbor strategy.
Buying an asset before its cooldown and acquiring an already-pending cooldown
claim are different capabilities. Each issuer needs an individually approved
adapter; account-bound claims cannot simply use the existing NFT transfer path.

## Product features

1. **Exit before or during redemption.** Swap a supported asset, or sell an
   eligible original withdrawal NFT without waiting for issuer finalization.
   The NFT path trades whole rights: no fractional NFTs, wrapper deployment or
   fresh governor approval for every ID within an approved integration.
2. **Buy from the same inventory.** Traders can buy assets or available
   withdrawal rights back from the pool. A claim buyer takes ownership of the
   right to recovery, including its remaining wait and recovery risk.
3. **Choose how much to trade.** Ordinary token swaps support exact input and
   exact output in both directions. Native-token wrapping and unwrapping are
   available through the periphery where supported.
4. **Provide liquidity across strategies.** LPs deposit into a share-based vault
   whose capital supports approved markets. The pool earns or loses through
   trading and recovery, while funded LP withdrawal claims remain protected
   from trading.
5. **Follow the economics.** Transaction-linked analytics distinguish trading
   activity, inventory, pending recoveries and realized results. Acquisition
   basis and actual proceeds determine realized profit; deposits are not
   earnings, and outstanding claims are not cash.

For example, a user with a pending withdrawal can sell the whole right to
Harbor and receive liquid funds. The pool now owns that right. Another user can
buy it from inventory, or the pool can retain it until recovery. Whoever owns
the right receives its payout through the supported settlement path—not
necessarily the person who originally requested the withdrawal.

LPs own pool shares rather than merely approving funds that might never trade.
This provides common accounting for deployed capital, pending claims and returns.
LP exits follow available liquidity and FIFO funding; they are not guaranteed to
be immediate.

## Pricing engine

Harbor prices the economics of redemption, not just a fixed exchange rate.
It combines a reusable recovery discount with live inventory pressure.
The engine asks two questions: **what might this right recover, and how much
additional redemption exposure should this pool take?**

The core model, before external fees and integer rounding, is:

```text
recovery_value = nominal_entitlement × recovery_discount

pool_bid = recovery_value − operating_cost − buy_margin
           − [capacity_penalty(exposure + entitlement) − capacity_penalty(exposure)]

pool_ask = recovery_value + operating_cost + sell_margin
           − [capacity_penalty(exposure) − capacity_penalty(exposure − entitlement)]

capacity_penalty(x) = kappa × capacity / [3 × (1 − target_utilization)²]
                      × max(0, x / capacity − target_utilization)³
```

The margins above are cash amounts: configured margin rates multiplied by nominal
entitlement. Buy and sell operating-cost parameters can differ. Exposure includes
inventory and pending issuer claims; requesting redemption does not release it.

Below the utilization target, the capacity term is zero. Above it, new purchases
receive progressively lower bids, while inventory sales receive a price adjustment
that encourages reducing exposure. Hard cash, capacity and loss gates still apply.
The curve influences a feasible quote; it cannot create liquidity.

The research model estimates the recovery discount across waiting-time scenarios:

```text
recovery_discount = sum(probability × recovery_fraction
                        / (1 + annual_funding_rate × remaining_days / 365))
```

`remaining_days` means time **from the quote until spendable recovery**, not how
long the user has already held the asset. Authorized publishers provide bounded,
expiring discount parameters; contracts apply the live state and enforce policy.
The Solidity engine does not fit a statistical model inside each swap. Bids round
down, asks round up, and independent valuation protects LP accounting.

Implementation: [PricingMath](src/libraries/PricingMath.sol) and
[standing pricing](src/libraries/StandingPricing.sol). The Hoodi demonstration
uses illustrative settings, including zero capacity penalty; the parameterized
research replay below is not the live demo configuration.

## Four parallel pricing simulations

We evaluated four pricing policies against the same frozen Lido withdrawal
history. The retrospective window is **July 1, 2024–March 8, 2025**, with
**16,452 valuation opportunities** and
**5,985 matched fills** for the economic comparison.
All models use identical starting capital. Results below are normalized to that
capital so the comparison does not imply support for a particular settlement token.

| Model | What changes | Simulated period profit / starting capital |
| --- | --- | ---: |
| Fixed-delay pricing | One fitted waiting-time estimate | 2.16% |
| Age-based pricing | Remaining wait conditioned on claim age | 2.58% |
| Queue-aware valuation | Age and queue conditions | 2.21% |
| **Harbor** | Same queue-aware forecast plus FACE capacity pricing | **3.17%** |

Profit here is recovery minus purchase payments and modeled operating costs,
**before a separate funding-opportunity-cost deduction**. The study uses a 5%
annual funding hurdle, 2 bp margin, fixed operating costs per acquisition,
10 bp external fee and a modeled six-hour recovery-operation lag. Harbor's
capacity variant uses a 60% target and 25 bp penalty coefficient.

### Findings

Harbor's simulated period profit was approximately **0.95 percentage points
higher** than the same forecast without the capacity adjustment. This improvement
came mainly from lower payments to sellers, not from additional recoveries.
The finding is an inventory-pricing tradeoff, not evidence of free additional yield
or a superior forecast. A better maker price can also lose the customer.

Every feasible scheduled offer was assumed accepted, and the simulation had no
pending LP exits. This is retrospective, already-inspected research—not an untouched
out-of-sample result, a live demand study or exact current-contract parity. The
source artifact is labeled `CACHED_RESEARCH` and `SIMULATED`. These four policies
are model baselines, not four competing live protocols; the results are not APY.

The analytics presentation separates valuation accuracy, cumulative simulated
profit, per-trade surplus and maker/seller tradeoffs. The historical pipeline
reconciles issuer facts and checks artifact provenance before publication. See
[historical data pipeline](docs/OPERATIONS.md#historical-issuer-subgraph)
and the [benchmark publication code](graph/scripts/publish-history-analytics.mjs).
The research runner and full input archive are maintained separately; this
checkout alone does not reproduce the complete study.

## Technology

| Technology | Role |
| --- | --- |
| **1inch SwapVM** | Runs executable ERC-20 quotes through official Extruction and Harbor's live pricing logic; not a backend-signed exact-fill passthrough |
| **1inch Aqua** | Treats the Vault as the maker and manages its strategy allocations; Book cash/reserve limits remain authoritative |
| **The Graph** | Reconstructs trades, positions, LP activity and recoveries; reuses standardized vault queries and supports evidence-backed historical research |
| **Privy** | Embedded-wallet onboarding alongside external wallets, with one shared transaction layer |
| **EIP-7702 / wallet batching** | Capability-aware atomic calls where supported and explicitly approved; ordinary transaction flows when batching is unavailable |
| **Foundry, Solidity and Solady** | Contract implementation, accounting tests and fork-based integration evidence |

Aqua is used at the pool boundary deliberately: individual-wallet liquidity would
require wallet selection and uneven capital/recovery attribution. Pooling gives
LPs a coherent share and withdrawal model. Raw NFTs use direct settlement through
the same Book because the ERC-20 Aqua path does not carry NFT IDs.

Privy's embedded wallets handle onboarding; the client checks wallet and chain
capabilities before attempting batches. A 7702 upgrade requires consent. An
uncertain submitted batch is never blindly replayed as individual transactions.
Support is wallet-dependent; this is not a claim that every wallet batches or
that Hoodi gas sponsorship is enabled. [Privy 7702 integration](https://docs.privy.io/recipes/react/eip-7702)
· [Batch transactions](https://docs.privy.io/recipes/batch-transactions)

## Repository structure

```text
src/          Contracts: Book, Vault, Executor, adapters, claims and SwapVM
graph/        Live indexing, standardized readers and historical analytics
script/       Deployment, inventory seeding, configuration and run records
test/         Contract lifecycle, arithmetic, invariant and fork tests
snapshots/    Committed gas and runtime-size measurements
lib/          Pinned third-party Solidity dependencies
docs/         Detailed specifications and operating reference
client/       Frontend on feat/client-foundation; not merged into this branch yet
```

Start with the [Graph source](graph/), [contract source](src/),
[contribution guide](CONTRIBUTING.md), or [operating reference](docs/OPERATIONS.md).
Current deployment addresses are recorded in the
[Hoodi manifest](script/records/harbor-nft-hoodi.deployment.json).
