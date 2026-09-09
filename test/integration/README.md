# Pooled settlement tests

## Compact settlement check

```sh
FOUNDRY_PROFILE=settlement forge test
```

Seven tests in `HarborSettlement.t.sol` reuse the shared base in
`test/helpers/RedemptionMarketFixture.sol`. The profile also selects six existing
deposit/mint tests, seven reentrancy checks and one claim-accounting invariant:
21 tests, with no new mocks or harnesses. Shared setup stays outside executable
test files; assertions stay beside the behavior they check.

Both fuzz tests run 64 cases. The lifecycle bounds recovery to 0–4.8 WETH and
always reaches an actual LP payout. Issuance uses independently calculated
rounding, including a nontrivial NAV/share rate. The existing stateful test runs
32 sequences of 16 calls: partial recovery must not retire cost or release the
remaining claim. This is synthetic partial-right behavior, not Lido settlement.

| Check | Plausible bug it catches |
| --- | --- |
| Deposit → purchase → claim export → recovery → LP payout | Lost/double-counted basis, duplicate recovery, wrong loss or payout rounding, conflated policy/mark event versions. |
| Cash-limited FIFO funding | Pending rights treated as cash, or a partially funded head dropped. |
| Funded credit failures | Another wallet steals credit, overdraws it, or claims it twice. |
| Receipt sale, reacquisition and loss | Recycling a receipt resets the issuer's lifetime risk budgets. |
| Quote deadline and replay | Expired fills transfer tokens or consume nonces; a fill executes twice. |
| Live discovery during an outage | Swap-pop cleanup hides another outstanding obligation or requires working marks to recover. |
| Operator deposit | Funds charged to the controller instead of the payer, or shares sent to the wrong recipient. |
| Deposit/mint regressions | Incorrect floor/ceiling conversion, donation dilution, stale issuance, reused escrow or failed-call state leakage. |
| Existing reentrancy regressions | Nested callbacks bypass Book/Vault/Executor locks or observe intermediate accounting. |
| Existing claim-accounting invariant | Multiple partial recoveries retire cost too early or misstate final losses. |

This replaces four event/discovery-specific files with one economic suite. The
other established unit, four-mode trading, security and invariant regressions
remain available; this command is a focused check, not a full-suite replacement.
No additional invariant harness, dependencies or CI are needed here. Boilerplate
Counter tests and upstream-only wiring/unused-instruction checks are excluded
from the repository. Duplicate operator/reacquisition assertions live in the main
suite. First-party SwapVM parser boundaries, differential wire/register checks,
rollback tests and measured optimization evidence remain in `test/swapvm/`.

Material gaps: synthetic issuer finalization, prices and permits do not validate
mainnet economics, live oracle/CRE delivery or issuer upgrades. Full event-history
reconstruction and indexer reorg handling are not exercised. Fork tests and longer
stateful campaigns remain separate; passing this check is not an audit.

## Broader integration coverage

`forge test --match-path 'test/integration/*.t.sol'` runs the real Harbor Vault,
Book and Executor against official Aqua and Harbor's router derived from the
pinned official SwapVM implementation. Two synthetic wrapped assets share one
WETH-denominated pool. Token movements are
real local-EVM calls; assets, valuation and policy permits are test fixtures.
They are not live issuer, mainnet, oracle or confidential-workflow evidence.

## Settlement

1. Trader identity, exact input/output limits and normalized WETH fee are checked.
2. Book validates the quote signature, independent permit, current versions,
   public price bounds, inventory, shared cash and funded LP reserves.
3. Executor acquires Book then Vault context and collects only actual input.
4. The inherited VM loop executes upstream Salt and custom HarborExactFill.
   Book authenticates the router, executor, vault, order, route/version and
   complete payload, then consumes both the quote nonce and trader nonce.
   The instruction validates the specified register and sets its complement.
5. Input-first hooks verify vault token deltas and commit inventory basis.
6. Executor checks returned amounts, removes router approval, pays the fee and
   trader, and verifies its original donated balances remain unchanged.
7. Book commits the measured WETH leg, invalidates the portfolio mark, and
   releases Vault then Book. Executor's transient guard releases last.

Any late failure rolls the entire operation back. Static quote runs without
writes and is not a substitute for simulating the complete transaction.

## Deployment and approvals

Vault and Executor creation code is not embedded into Book. A deterministic
CREATE sequence binds the three addresses in constructors, with no mutable
initializer or runtime factory. `script/DeployHarbor.s.sol` verifies those
bindings and is restricted to local chain ID 31337. Deploy the Harbor router
first and supply it in configuration; the unmodified router is rejected. Do not
publish partially deployed addresses or insert unrelated transactions into that
nonce sequence.

The vault approves only official Aqua for its supported route tokens. Approval
is unbounded so both directions can reuse newly received inventory; it is not
the spending budget. Aqua allocation counters, canonical order identity and
Book's live managed-inventory/cash/reserve checks bound each actual transfer.
Executor approvals to the Harbor router are exact-size and cleared after use.
LPs approve the vault, never Aqua, Book or a redemption adapter.

The Book's route universe, caps, fee recipient, fee rate and observation provider
are immutable. Guardian can stop new risk and invalidate cached issuance marks.
Signer changes and resumption require the configured governance delay; neither
operation can sweep tokens, replace an adapter, increase a cap or price an LP exit.
Test settings (including 10 bps fees and 60-second freshness) are synthetic,
not calibrated production recommendations.
## Issuer settlement

`IssuerRecovery.t.sol` connects the real Harbor Book, Vault and LidoAdapter to a
synthetic issuer queue. It covers purchases becoming non-cash claims, basis
conservation, fixed-vault receipts, queued LP funding, losses, keeper revocation
and recovery during a valuation outage. Synthetic finalization is not mainnet
finalization evidence.

`HarborExecutor.fillDigest` is the canonical digest view. The immutable Executor
also provides read-only normalization, observation, price, allocation and
signature checks. Book calls those checks and separately enforces immutable
mandates, replay, inventory, shared cash/exposure and policy approval. Calling a
read-only verifier directly grants no settlement authority.

This division keeps Book within EIP-170 without a larger code-size limit, proxy,
delegatecall module, or separately linked state library. `Deployment.t.sol`
explicitly checks the Book, Vault, Executor and custom router runtimes against
24,576 bytes; Solidity test deployment alone is insufficient evidence of
deployability.
