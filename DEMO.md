# Harbor contract demo

This demo is test-driven; it does not broadcast transactions or require a client.

```sh
forge install
forge test --list
forge test
```

## Four-way trading

```sh
forge test --match-contract PermitTradingTest --match-test test_AuthenticatedPermitSettlesAllFourModes -vvvv
```

The trace shows the pooled vault as the maker, official Aqua transfers through
Harbor's SwapVM-derived router, the real Harbor permit receiver, exact user
limits, WETH fees, and consumed
quote/trader nonces. Workflow report delivery and asset/valuation inputs are
synthetic; this is not a live CRE or confidential-computing demonstration.

| Vault action | Trader action | Modes |
| --- | --- | --- |
| Buys wrapped inventory | Sells wrapped inventory for net WETH | Exact input / exact output |
| Sells wrapped inventory | Buys wrapped inventory with gross WETH | Exact input / exact output |

## Claims, cash and LP exits

```sh
forge test --match-contract HarborSettlementTest --match-test testFuzz_DepositPurchaseClaimRecoveryAndLpPayout --fuzz-runs 1 -vvvv
forge test --match-contract IssuerRecoveryTest --match-test test_RecoveryFundsPendingFIFOExitsUsingActualWETH -vvvv
```

Observe inventory leaving the vault only for the fixed adapter, ownership of
issuer rights, unchanged cash while requests are pending, and cash recognition
only after measured WETH arrives. In the LP example, available cash funds the
oldest request partially; actual recovery enables the remainder. Funding burns
escrowed LP shares and reserves WETH; claiming pays that fixed credit without a
second burn. Issuer finalization in these two tests is explicitly synthetic.

## Real Lido fork evidence

```sh
FOUNDRY_PROFILE=fork forge test --match-contract LidoAdapterForkTest -vvvv
```

See [pinned block and proof boundaries](README.md#pinned-fork-checks). The first test creates
a real unfinalized request. The second exercises inherited production claim code
with a separately mature historical NFT and a test-only tracking setup. The
observed historical recovery is 807,507,852,022,935,682 wei, sent as WETH to the
fixed beneficiary. No time warp or fake oracle finalization links those two tests.

## Failure and consistency checks

```sh
forge test --match-contract '.*ReentrancyTest'
forge test --match-contract PermitTradingTest
FOUNDRY_PROFILE=invariant forge test
FOUNDRY_PROFILE=gas forge test --gas-snapshot-check true --gas-snapshot-emit false
```

The invariant profile checks partial-claim accounting in 32 short sequences of
16 calls. The gas profile now retains only the deployment-size gate; its scope
is documented [here](README.md#deployment-size-gate).
The deployment script is local-only. No mainnet readiness, calibrated APY,
live confidential underwriting, or second-issuer integration is claimed by this
demo. Those require their own measured evidence and security review.
