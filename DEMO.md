# Harbor contract demo

Test-driven execution with actual token transfers in the local EVM; no frontend
or transaction broadcast is required. Synthetic issuer finalization is labeled
separately from real pinned-fork evidence.

## 1. Standing four-way swaps

```sh
forge test --match-contract StandingTradingTest -vvvv
```

Show `publishPricing` once, then two trades with the same parameter version.
The caller submits a registered Book address and Trade. Executor opens that pool's lock, then the official
SwapVM `Extruction` instruction calls Book to compute one price from live state.
Its authenticated funding callback collects the actual input. Aqua moves tokens,
the VM's `FeeProtocol` instruction collects the WETH fee,
Book checks actual vault deltas, and Executor pays the customer. A separate case crosses 60% FACE utilization,
observes a lower next bid and rejects the old minimum-output expectation.

`test_StandingProgramSettlesAllFourModes` demonstrates exact input/output in both
directions. Prices and parameters in this demo are illustrative, not calibrated.

### Shared pools and six-decimal cash

```sh
forge test --match-test test_TwoRoutesCannotSpendSameCash -vvvv
```

The existing test also runs `CashPoolChecks`: one shared Executor/Router/Aqua
serves two WETH pools plus a six-decimal synthetic cash pool. The cash pool
deposits 1,000 tokens, prices eighteen-decimal inventory and one-unit receipts in
all four modes, checks exact cash/fees, recovers native and tokenized rights,
and pays the LP's funded exit. Other pools' cash, FACE and funded credit remain
unchanged. Registration rejects unauthorized/mismatched bindings; token callbacks
cannot enter another registered pool. These are actual local token transfers
against production Harbor/VM code, with a **synthetic, explicitly prefunded issuer**.
They do not establish a production USDC integration or cross-currency recovery.

## 2. Deposit, issuer request, recovery and LP payout

```sh
forge test --match-contract IssuerRecoveryTest --match-test test_RecoveryFundsPendingFIFOExitsUsingActualWETH -vvvv
```

Two LPs seed 20 WETH. The vault purchases 16 synthetic wstETH representing 19.2
WETH nominal entitlement, using the adapter's native valuation methods.
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

Follow NFT in adapter custody -> generic one-unit receipt -> vault purchase/resale
-> adapter cash credit -> final holder payout. The same lifecycle test checks two
claims with different recoveries, aggregate backing shortages, failed payment
rollback, direct-recovery transfer callbacks, and payout during issuer outage.
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

Use an archive-capable provider (the suite has run against `https://eth.drpc.org`).
The default PublicNode attempt lacked historical state. Public endpoint access is
not guaranteed. No transactions are broadcast by these tests.

Final-source verification on **11 September 2026**: all four Ethereum fork tests
passed against that archive RPC. The fresh request was **135,146** and the LP's
actual cash payout was **2.01 WETH** after its 2 WETH deposit and the illustrative
round trip. A separate mature-request test recovered **0.807507852022935682 ETH**
from the real issuer contract. These are test outcomes, not projected returns.

At block 25,930,239, the full Harbor Book, vault, issuer adapter and executor
use locally deployed official Aqua/Harbor router against real issuer/token state.
The test creates a genuine pending withdrawal, wraps it, trades it both ways
with standing prices and pays an LP from measured vault cash. Its time warps
satisfy Harbor's factory/Book admission delays only; it does not finalize the new request.

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
real-issuer worst-case gas, audits and any funded deployment migration remain open.

## 6. Public testnet and the existing UI

**Hoodi is the real-issuer candidate; Base Sepolia is not a verified full-stack
deployment.** [Lido publishes Hoodi stETH, wstETH and its withdrawal queue](https://docs.lido.fi/deployed-contracts/hoodi/).
Read-only RPC checks on 11 September 2026 found no code at either of the
[published Aqua / SwapVM addresses](https://business.1inch.com/portal/documentation/aqua/reference/contract-addresses)
on Hoodi or Base Sepolia. No official Lido withdrawal queue was found on Base
Sepolia. This does not mean the official Aqua/SwapVM source cannot run on a testnet.

The existing fresh-request fork test can run against Hoodi without increasing
the 50-test suite:

```sh
HARBOR_HOODI_RPC_URL=https://hoodi.drpc.org HARBOR_TEST_HOODI=true FOUNDRY_PROFILE=fork forge test --match-test test_ForkNewLidoClaimTradesForRealWethThroughAquaSwapVM -vv
```

It pins Hoodi block **3,598,213**, uses real wstETH
`0x7E99eE3C66636DE415D2d7C880938F2f40f94De4` and withdrawal queue
`0xfe56573178f1bcdf53F01A6E9977670dcBBD9186`, and deploys official Aqua,
the pinned router and a wrapped-ETH contract **inside the fork**. It requests,
imports, quotes/trades the pending right both ways and pays the LP from realized
trading cash. Test ETH is supplied with `vm.deal`; issuer storage is not rewritten.
The historical Ethereum recovery tests are not portable to Hoodi request IDs.

Final-source Hoodi run on **11 September 2026: passed**, with fresh request
**5035** and actual LP payout **2.01 locally wrapped test ETH**. This reuses one
of the 50 tests in another environment; it is not a 51st test entrypoint or a
public-chain transaction. The trader explicitly wraps additional test ETH for
the buyback spread/fees, rather than relying on pre-existing fork-address cash.
The shared-pool revision also passed this replay through the alternate RPC above;
the default PublicNode endpoint returned unavailable historical storage during
that run. Use an archive-capable provider; an RPC error is not passing evidence.

For a public Hoodi demo, deploy these dependencies and Harbor with test ETH, verify
their addresses/links, complete real governance admission delays, publish fresh
valuation/pricing parameters, and connect the UI to Hoodi. **That deployment has
not happened.** The current deployment script deliberately rejects chains other
than 31337; a reviewed Hoodi configuration/script is still needed. Real issuer
finalization takes issuer/oracle time and cannot be accelerated by the UI.

For a UI demo with the existing local deployment script, use a persistent Anvil
fork rather than a Forge test's temporary EVM:

```sh
anvil --fork-url "$HARBOR_MAINNET_RPC_URL" --fork-block-number 25930239 --chain-id 31337
```

Deploy/seed Harbor on that RPC, then configure the UI wallet for chain 31337 and
the resulting contract addresses. `http://127.0.0.1:8545` works on the presenter's
machine, not a remote judge's machine. Remote access needs a safely hosted demo
RPC or public testnet; do not expose unlocked development accounts with real funds.

### SDK and ABI boundary

The existing UI can use viem/ethers directly; installing another SDK is not a
prerequisite. Its swap flow is:

1. Read the current route/order, pricing/config/strategy versions and pool limits.
2. Call `Executor.quoteSwap(book, Trade)` for the canonical VM's customer input/output
   and order hash. Keep a realistic `minOut` / `maxIn` and deadline.
3. Approve **Executor** for the input token; simulate and call `execute(book, Trade)`.
4. Display actual amounts/fee from `TradeExecuted`, not a pre-trade estimate.

`Executor.quote(book, Trade)` remains a compatibility preview with a fee breakdown;
execution does not call it. LP deposits approve **Vault**, then call its deposit
methods; exits use its asynchronous request/funding/claim flow. LPs do not need
to approve Aqua directly. ABI tuple details remain in [CONTRACT-FLOWS.md](CONTRACT-FLOWS.md).

The Aqua SDK is optional for strategy publication/discovery tooling. The SwapVM
SDK is optional for applications constructing raw orders/programs/taker data;
Harbor's on-chain builders already construct them for the UI flow above.

**Version boundary:** this checkout pins SwapVM
`f09a41e689240adc645934f965c8061749397cd2`. Its three-argument quote/swap ABI and
four-register extension are not interchangeable with the newer five-argument /
five-register interfaces in the current online documentation. Use generated
ABIs and the router deployed from the pinned source; do not substitute the
published vanity address or newest SDK encoding without a compatibility pass.
[Extruction is the official external-pricing extension](https://business.1inch.com/portal/documentation/aqua/swapvm/aqua-router-opcodes/extruction),
but supporting it does **not** automatically list Harbor in 1inch's production
route discovery. Solver onboarding and permitted-program review remain separate.
