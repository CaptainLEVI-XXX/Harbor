# Execution measurements

```sh
FOUNDRY_PROFILE=gas forge test --gas-snapshot-check true --gas-snapshot-emit false
```

Reviewed baseline updates are explicit:

```sh
FOUNDRY_PROFILE=gas forge test --gas-snapshot-check false --gas-snapshot-emit true
git diff -- snapshots/
```

The committed JSON snapshots record EVM execution regions, not each whole test.
Quote generation, fixture deployment and setup are excluded. The cold snapshots
reset account/storage warmth for Harbor, official Aqua, the custom SwapVM-derived
router, assets, adapter, queue and mock observation/permit providers.
The preflight-warm case additionally
runs static quote before measurement. They are controlled comparisons, not total
transaction fees or a promise that every real caller/access list is cold.

Synthetic ERC-20s, valuation, permit lookup and issuer finalization are used.
Mainnet token implementations, authenticated receiver state, calldata/intrinsic
gas, CRE delivery and infrastructure costs need separate measurement. In
particular, the 64-claim checkpoint uses a simple mock mark provider; it does not
bound the cost of a future production valuation implementation.

Regions cover all four vault-side modes, deposit, FIFO funding of eight tickets,
funded LP claims, eight issuer requests/recoveries, a 64-claim checkpoint and
strategy refresh. Runtime byte lengths are recorded separately and checked
against Ethereum's limit in `Deployment.t.sol`. Book's current size has limited
headroom; new functionality must retain the deployment-size gate.

The deliberately simple reference profile is Solidity 0.8.30, Cancun, via-IR,
700 optimizer runs. The bounded packed-argument parser has a separate readable
reference and microbenchmark in `test/swapvm/HarborExactFill.t.sol`. Source module
extraction does not by itself imply smaller runtime code. The custom router's
runtime is measured alongside the Book; no code-size allowance is increased.

## Historical native exact-fill comparison

Earlier module/instruction refactor, before receipt-market support:

| Measurement | Generic extension | Native exact fill |
| --- | ---: | ---: |
| Book runtime bytes | 24,146 | 23,610 |
| Router runtime bytes | 20,376 | 21,059 |
| Buy exact-input cold region | 628,377 | 626,964 |
| Buy exact-output cold region | 628,485 | 627,064 |
| Sell exact-input cold region | 459,499 | 458,087 |
| Sell exact-output cold region | 460,411 | 458,991 |

The Book gains 536 bytes of headroom, while the custom router adds 683 bytes:
this is not a reduction in aggregate deployed code. Four-mode trade regions
improve by roughly 1,400 gas; several non-trade regions increase by 131 gas
(issuer requests by 168) with the revised context/module implementation.
Snapshots retain those regressions rather than reporting only improvements.
Vault and Executor runtime sizes remain unchanged. These are controlled fixture
measurements, not claims about mainnet transaction fees.

## Receipt market baseline before accounting compaction

The receipt-market baseline includes linked domain libraries and the receipt-state
guard. Its runtime measurements were Book **23,086**, router **23,017**, vault
**17,390**, executor **12,121** and Lido adapter **6,516** bytes. Fixed linked
libraries add separately deployed code; reducing Book size is not a claim of
lower aggregate deployment cost.

The baseline measured fixture-warm regions with synthetic issuer behavior:

| Region | Gas |
| --- | ---: |
| Clone wrapping, excluding request creation | 248,247 |
| Complete firm-quote receipt purchase | 756,854 |
| Complete firm-quote receipt sale | 534,819 |
| Native right export, including clone and registration | 841,510 |
| Vault recovery and redemption | 180,945 |
| Direct NFT/WETH two-transfer reference | 11,783 |

The direct reference has no signature verification, vault accounting, policy
checks, pricing guard or Aqua ledger; it is a lower bound, not a feature-equivalent
competitor. Wrapping adds real cost. Its benefit is reusable ERC-20 settlement
and explicit recovery ownership, not cheaper one-off NFT transfers. Receipt
snapshots do not reset warmth and must not be compared with the cold inventory
regions as if only the asset changed.

## Storage-only accounting comparison

Storage compaction retains source-level risk budgets and adds native realization
events. Under the same compiler and fixtures, receipt purchase changes from
756,854 to 717,352 gas; sale from 534,819 to 516,817; export from 841,510 to
654,106; and vault receipt recovery from 180,945 to 159,333. Wrapping is unchanged.
Book runtime changes from 23,086 to 23,135 bytes and the adapter from 6,516 to
6,421 bytes. Linked libraries remain separate deployment costs.

Not every region improves: native cold exact-input purchases increase from
660,427 to 667,185, and eight native recoveries from 1,243,727 to 1,261,666.
Route resolution, result events and retiring settled payloads have execution
costs. Region snapshots are not post-refund transaction receipts. The committed
JSON files remain the executable measurements for this checkout.

## Accounting with settlement events and bounded discovery

The following comparison includes the subsequent event schemas and live-position
views, using the same Solidity 0.8.30/Cancun/via-IR/700-run configuration and
unchanged measurement regions:

| Region | Before accounting changes | Current |
| --- | ---: | ---: |
| Receipt purchase, fixture-warm | 756,854 | 717,908 |
| Receipt sale, fixture-warm | 534,819 | 517,329 |
| Native export, fixture-warm | 841,510 | 654,238 |
| Vault receipt recovery, fixture-warm | 180,945 | 159,465 |
| Native buy exact-input, cold region | 660,427 | 667,741 |
| Native sell exact-input, cold region | 484,299 | 472,326 |
| Eight native recoveries, cold region | 1,243,727 | 1,261,776 |
| Deposit, cold region | 104,471 | 107,260 |
| Fund eight FIFO tickets, cold region | 271,717 | 275,010 |
| Mark 64 native claims, cold region | 790,182 | 795,152 |

Complete events and payload retirement have costs; reduced persistent history
does not imply every operation is cheaper. Receipt wrapping remains unchanged
at 248,247 fixture-warm gas. Do not mix these scopes with real transaction fees.

Current runtime sizes are Book **24,165**, vault **18,096**, executor **12,121**,
router **23,017** and adapter **6,421** bytes. The Book has only **411 bytes** of
EIP-170 headroom. Preserve the deployment test: adding more entrypoints may require
moving actual responsibility into an existing linked library, not increasing the
code-size limit. Library runtime/deployment costs remain separate.
