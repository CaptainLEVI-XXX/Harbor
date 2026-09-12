#!/usr/bin/env bash
set -euo pipefail

# Local synthetic issuer; actual receipt/WETH transfers through official Aqua.
# Run from the repository root. No broadcast, indexer or client is required.
forge test --match-contract RedemptionMarketTest \
  --match-test 'test_(FourModes|ExportSell)' -vvvv
forge test --match-contract HarborSettlementTest \
  --match-test testFuzz_DepositPurchaseClaimRecoveryAndLpPayout --fuzz-runs 1 -vvvv

if [[ "${1:-}" == "--fork" ]]; then
  # Requires pinned Hoodi state through HOODI_RPC_URL. Reads only; no broadcast.
  FOUNDRY_PROFILE=fork forge test -vvvv
fi
