# Harbor

Pooled WETH liquidity for two-way, exact-input/exact-output inventory trading
through official 1inch Aqua and SwapVM, with asynchronous LP redemption.

## Contracts

- `HarborVault`: ERC-4626-style synchronous deposits, share accounting and
  ERC-7540 asynchronous redemption with FIFO funding and reserved cash.
- `HarborBook`: immutable route mandates, shared cash/exposure checks, authenticated
  SwapVM callbacks, inventory basis and issuer claim accounting.
- `HarborExecutor`: exact trader amounts, quote verification, official-router
  execution, fee settlement and residue checks.
- `LidoAdapter`: bounded wstETH requests, adapter-owned withdrawal rights and
  attributable ETH recovery wrapped directly to the fixed vault.

Pending issuer claims are not spendable cash. Unsolicited token transfers are
excluded from managed NAV. Book/Vault use shared transient operation contexts;
Executor and adapters use transient function guards.

## Development

See [CONTRIBUTING.md](CONTRIBUTING.md) for toolchain requirements, pinned
dependencies, setup commands, coding conventions, and testing requirements.

```sh
forge install
forge build --sizes
forge test
forge fmt --check
```

See [settlement tests](test/integration/README.md),
[vault standards tests](test/standards/README.md), and
[adapter tests](test/adapters/README.md) for proof scope and commands.

## Status

This is unaudited contract development, not a mainnet-ready yield product.
Local tests exercise real token-transfer calls through official Aqua/SwapVM,
using synthetic tokens, public marks, permit approval and issuer finalization.
The authenticated CRE receiver/workflow, real issuer fork evidence, production
valuation calibration, stateful portfolio tests and independent review remain
release requirements. The deployment script rejects non-local chains.

The Foundry Counter examples are development-only and have no Harbor authority.

## Dependencies

The repository uses Foundry, forge-std, Solady, and pinned 1inch Solidity
dependencies. All Solidity dependencies are pinned Forge-managed Git submodules;
contracts do not require npm installation. No live deployment addresses are published
in this repository.
