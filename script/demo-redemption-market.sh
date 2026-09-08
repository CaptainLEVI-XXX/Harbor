#!/usr/bin/env bash
set -euo pipefail

# Local synthetic issuer; actual receipt/WETH transfers through official Aqua.
# Run from the repository root. No broadcast, indexer or client is required.
forge test --match-contract RedemptionMarketTest \
  --match-test 'test_(FourModes|ExportSell|VaultRecovery|ZeroRecovery)' -vvvv

if [[ "${1:-}" == "--fork" ]]; then
  # Requires an archive-capable Ethereum RPC in HARBOR_MAINNET_RPC_URL.
  FOUNDRY_PROFILE=fork forge test --match-contract RedemptionMarketForkTest -vvvv
fi
