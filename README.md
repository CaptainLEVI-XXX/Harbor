# Harbor

Pooled WETH liquidity for two-way, exact-input/exact-output inventory trading
through official 1inch Aqua and a custom router derived from official SwapVM,
with asynchronous LP redemption.

## Contracts

- `HarborVault`: ERC-4626-style synchronous deposits, share accounting and
  ERC-7540 asynchronous redemption with FIFO funding and reserved cash.
- `HarborBook`: immutable issuer mandates, individually admitted receipt routes,
  shared cash/exposure checks, authenticated SwapVM callbacks, inventory basis
  and issuer claim accounting.
- `HarborSwapVMRouter`: upstream Aqua settlement plus `HarborExactFill` and
  `HarborClaimGuard`; no upstream dependency files are modified.
- `HarborExecutor`: exact trader amounts, quote verification, custom-router
  execution, fee settlement and residue checks.
- `LidoAdapter`: bounded wstETH requests, adapter-owned withdrawal rights and
  attributable ETH recovery wrapped directly to the fixed vault.
- `LidoClaimFactory` / `LidoClaimReceipt`: canonical whole-request receipts,
  pending-right trading, native export and final-holder recovery.
- `HarborPolicyReceiver`: authenticated, expiring exact-fill permits through
  Chainlink's receiver interface, with no treasury authority.

Pending issuer claims are not spendable cash. Unsolicited token transfers are
excluded from managed NAV. Book/Vault use shared transient operation contexts;
Executor and adapters use transient function guards.

## Development

Start with the [SwapVM strategy guide](src/swapvm/README.md) for opcode encoding,
register invariants, authority boundaries and focused tests. The
[contract demo](DEMO.md) provides reproducible trading, recovery and LP-exit traces.
The [redemption market guide](src/claims/README.md) covers receipt admission,
four-mode trading, accounting and `bash script/demo-redemption-market.sh`.

See [CONTRIBUTING.md](CONTRIBUTING.md) for toolchain requirements, pinned
dependencies, setup commands, coding conventions, and testing requirements.

```sh
forge install
forge build --sizes
forge test
forge fmt --check
```

The [test guide](test/README.md) explains the six folders and 50 retained tests:
46 local checks plus four separate fork checks. `forge test` runs all local checks.
See [settlement tests](test/core/README.md),
[vault standards tests](test/core/VaultStandards.md), and
[adapter tests](test/core/LidoAdapter.md) for proof scope and commands.

## Status

This is unaudited contract development, not a mainnet-ready yield product.
Local tests exercise real token-transfer calls through official Aqua and Harbor's
SwapVM-derived router, using synthetic tokens, public marks, permit approval
and issuer finalization.
[Pinned Lido fork checks](test/fork/README.md) cover native requests, actual
receipt/WETH trading and separately mature historical recovery; the different
blocks and test-only historical setup are documented.
The [receiver tests](test/core/HarborPolicyReceiver.md) use simulated forwarder delivery.
[One short stateful check](test/invariant/README.md) compares partial claims against
an independent accounting ledger. The CRE workflow/live delivery, production valuation calibration
and independent review remain
release requirements. The deployment script rejects non-local chains.

The Foundry Counter examples are development-only and have no Harbor authority.

## Dependencies

The repository uses Foundry, forge-std, Solady, and pinned 1inch Solidity
dependencies. All Solidity dependencies are pinned Forge-managed Git submodules;
contracts do not require npm installation. No live deployment addresses are published
in this repository.
