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
reset account/storage warmth for Harbor, official Aqua/SwapVM, assets, adapter,
queue and mock observation/permit providers. The preflight-warm case additionally
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
700 optimizer runs. No custom Yul optimization or increased code-size allowance
is justified merely by producing a gas report.
