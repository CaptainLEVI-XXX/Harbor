# Harbor

Solidity contracts and supporting tools for Harbor.

## Development

See [CONTRIBUTING.md](CONTRIBUTING.md) for toolchain requirements, pinned
dependencies, setup commands, coding conventions, and testing requirements.

```sh
forge build --sizes
forge test
forge fmt --check
```

The included Counter contract, deployment script, and unit/fuzz tests are
development examples, not a Harbor vault or trading implementation.

## Dependencies

The repository uses Foundry, forge-std, Solady, and pinned 1inch Solidity
dependencies. Aqua and SwapVM sources are installed using the exact revisions
documented in the contribution guide. No live deployment addresses are published
in this repository.
