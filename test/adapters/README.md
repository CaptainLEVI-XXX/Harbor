# Issuer adapter tests

`forge test --match-path 'test/adapters/*.t.sol'`

These tests use synthetic wrapped tokens, a fault-injecting queue, and synthetic
finalization. They prove adapter mechanics, not a live issuer deployment or an
elapsed-time guarantee.

Lido's ABI and request/claim behavior were reviewed against
[core v4.0.0](https://github.com/lidofinance/core/tree/17005714f151e5502c559932319a3f2f74ac2436/contracts/0.8.9):
request bounds apply after wstETH conversion; the NFT owner must claim; the
request path emits ownership events without a receiver callback. The adapter
uses bounded, caller-provided checkpoint hints and verifies each right separately.

Tests cover eight-way splitting, underlying-unit bounds, issuer faults, exact
consumption, ownership, allowance cleanup, donation exclusion, zero/loss recovery,
closure verification, and reentry through an otherwise authorized Book caller.
Lido does not provide native partial claims through this path.

Mainnet use additionally requires a pinned-block request test, an independently
mature historical recovery test, proxy implementation verification, and the
portfolio's valuation/security release gates. Advancing a fork clock does not
finalize an issuer request.
