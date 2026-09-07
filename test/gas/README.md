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

## Native exact-fill comparison

Combined module/instruction refactor, against the preceding committed snapshots:

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
