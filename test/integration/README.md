# Pooled settlement tests

`forge test --match-path 'test/integration/*.t.sol'` runs the real Harbor Vault,
Book and Executor against the pinned official Aqua/SwapVM contracts. Two
synthetic wrapped assets share one WETH-denominated pool. Token movements are
real local-EVM calls; assets, valuation and policy permits are test fixtures.
They are not live issuer, mainnet, oracle or confidential-workflow evidence.

## Settlement

1. Trader identity, exact input/output limits and normalized WETH fee are checked.
2. Book validates the quote signature, independent permit, current versions,
   public price bounds, inventory, shared cash and funded LP reserves.
3. Executor acquires Book then Vault context and collects only actual input.
4. Official SwapVM executes Salt/Extruction. Book authenticates the router,
   executor, vault, order, metadata and complete payload, then consumes both
   the quote nonce and trader nonce.
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
bindings and is restricted to local chain ID 31337. Do not publish partially
deployed addresses or insert unrelated transactions into that nonce sequence.

The vault approves only official Aqua for its supported route tokens. Approval
is unbounded so both directions can reuse newly received inventory; it is not
the spending budget. Aqua allocation counters, canonical order identity and
Book's live managed-inventory/cash/reserve checks bound each actual transfer.
Executor approvals to the official router are exact-size and cleared after use.
LPs approve the vault, never Aqua, Book or a redemption adapter.

The Book's route universe, caps, fee recipient, fee rate and observation provider
are immutable. Guardian can stop new risk and invalidate cached issuance marks.
Signer changes and resumption require the configured governance delay; neither
operation can sweep tokens, replace an adapter, increase a cap or price an LP exit.
Test settings (including 10 bps fees and 60-second freshness) are synthetic,
not calibrated production recommendations.
