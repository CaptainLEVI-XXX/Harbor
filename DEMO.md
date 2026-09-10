# Harbor contract demo

Test-driven execution with actual token transfers in the local EVM; no frontend
or transaction broadcast is required. Synthetic issuer finalization is labeled
separately from real pinned-fork evidence.

## 1. Standing four-way swaps

```sh
forge test --match-contract StandingTradingTest -vvvv
```

Show `publishPricing` once, then two trades with the same parameter version.
The caller submits only Trade. The custom SwapVM instruction computes from
Book's current state; Aqua moves the tokens; Book measures vault deltas; Executor
pays customer and protocol fee. A separate case crosses 60% FACE utilization,
observes a lower next bid and rejects the old minimum-output expectation.

`test_StandingProgramSettlesAllFourModes` demonstrates exact input/output in both
directions. Prices and parameters in this demo are illustrative, not calibrated.

## 2. Deposit, issuer request, recovery and LP payout

```sh
forge test --match-contract IssuerRecoveryTest --match-test test_RecoveryFundsPendingFIFOExitsUsingActualWETH -vvvv
```

Two LPs seed 20 WETH. The vault purchases 16 synthetic wstETH representing 19.2
WETH nominal entitlement, using the actual native valuation implementation.
Requesting withdrawal changes custody but leaves 19.2 FACE outstanding and only
0.992 WETH liquid. FIFO funding reserves that available cash first. Synthetic
issuer finalization/recovery then clears FACE, brings actual WETH into the vault
and funds the remaining LP exit. Only the controller claims its funded credit.

`test_KeeperIntentDomainReplayAndExactInventoryAreEnforced` additionally proves
keeper replay checks and independently authorized NAV publication. Changing
marks invalidates a cached NAV even at the same timestamp. Finalized issuer
evidence remains available when estimates expire or their publisher is revoked.

## 3. Pending rights as transferable inventory

```sh
bash script/demo-redemption-market.sh
```

Follow NFT -> one-unit receipt -> vault purchase/resale -> holder recovery.
Only pending rights trade; arbitrary exact-cash requests cannot buy a fraction
or donate the difference. Native export transfers existing basis and FACE
rather than creating cash/profit. Holder redemption burns the receipt and pays
attributable recovery once. The fuzzed complete lifecycle includes loss cases.

## 4. Real Ethereum fork

```sh
FOUNDRY_PROFILE=fork forge test -vvvv
```

Set an archive-capable `HARBOR_MAINNET_RPC_URL` locally. Public endpoints may
reject history; missing RPC access is not a passing fork test.

At block 25,930,239, the full Harbor Book, vault, native valuation and executor
use locally deployed official Aqua/Harbor router against real issuer/token state.
The test creates a genuine pending withdrawal, wraps it, trades it both ways
with standing prices and pays an LP from measured vault cash. Its one-day warp
satisfies Harbor factory admission only; it does not finalize the new request.

Separate historical tests use mature request 134,829, fork-only owner
impersonation and explicitly test-only tracking to execute issuer recovery.
They do not prove the newly created request matures, change issuer storage or
inject issuer recovery cash. See [fork scope](README.md#pinned-fork-checks).
Report the actual run result separately from code merely written or compiled.

## 5. Review gates

```sh
forge test
forge build --sizes
forge fmt --check
python3 -m unittest discover -s script/pricing -v
```

The Solidity suite stays at 50 entrypoints: 46 local plus four fork.
No external report service, signature server, confidential workflow or indexer
is required. Native estimates still need an authorized publisher.
The deployment script is restricted to local chain 31337. Pricing calibration,
maximum-portfolio gas, audits and any funded deployment migration remain open.
