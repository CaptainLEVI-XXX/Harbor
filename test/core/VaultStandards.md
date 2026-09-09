# Vault standards verification

Foundation: Solady v0.1.26 (`acd959aa4bd04720d640bf4e6a5c71037510cc4b`).
Tests use synthetic assets and a mock Book. They do not certify live valuation,
issuer integration, complete standards conformance, or production readiness.

The retained `Vault.t.sol` contains five selected checks. The matrix below
describes contract behavior; it does not claim that every row still has a
dedicated test. Full standards-conformance and operator-mode matrices were cut
from the hackathon suite.

Deposit/mint fuzz expectations use explicit virtual-share arithmetic, not the
vault's previews as the reference. A synthetic noncash gain exercises upward
mint rounding at a nontrivial exchange rate; both previews and real balances
must agree with the independently computed result. Operator funding and its
unauthorized-call regression live in `test/core/HarborSettlement.t.sol`.

## Inherited-path override matrix

| Path | Harbor behavior |
| --- | --- |
| ERC-20 balances, allowances, nonces, permit | Solady owns the only share ledger. Permit only changes allowance. Implicit infinite Permit2 allowance is disabled. |
| totalSupply / totalAssets | Matching committed supply/NAV, including during asset callbacks. |
| convertToShares / convertToAssets | Full-precision downward rounding, one virtual wei and 1e6 virtual shares. |
| previewDeposit / previewMint | Downward issuance shares / upward required assets; no execution guarantee. |
| deposit / mint, both overloads | Common Book/Vault lock, fresh NAV and exact receipt. Caller supplies WETH. Overloads authenticate controller/operator and emit controller as deposit sender. |
| maxDeposit / maxMint | Zero when locked, stale, physically underbacked, orphaned, or capped. |
| withdraw / redeem | Claim already-funded receipts; never collect or burn shares again. |
| previewWithdraw / previewRedeem | Always revert for asynchronous redemption. |
| maxWithdraw / maxRedeem | Controller's reserved assets / receipt units, not wallet share balance. |
| requestRedeem | Owner, share allowance, or operator permission; escrow without burning. All public request IDs are zero. |
| transfer / transferFrom | Common lock; no external transfer into or out of escrow. |
| _beforeTokenTransfer | Only an explicitly authorized internal share mutation inside the common lock. |
| _withdraw | Synchronous base helper disabled as defense in depth. |
| share / vault / supportsInterface | Combined share/vault, WETH lookup, ERC-165, ERC-7575 and asynchronous-redemption/operator IDs. No asynchronous-deposit claim. |

The compiler reports unreachable synchronous base withdrawal code because both
asynchronous previews unconditionally revert. That warning is expected; upstream
source is not patched. Tests must still prove every public withdrawal selector
uses the asynchronous implementation.

## Operation lifetime

`Book acquire → Vault acquire → operation and callbacks → commit NAV/supply →
Vault release → Book release`.

The lock is explicit transient context, not a function guard that unlocks when
the begin method returns. Share mutation permission surrounds internal Solady
mint/burn/transfer calls only, with no external call inside that permission window.
Asset callbacks see the prior coherent NAV/supply snapshot and cannot mutate LP
state. Ordinary ERC-20 approvals/permit do not move shares or spend vault assets.

Request and claim require separate calls. Pending shares retain portfolio risk;
fulfillment burns them and reserves actual WETH. Claims require reserve backing,
but no fresh valuation or quote service. Zero-value loss credits are acknowledged
through redeem rather than discarded. Partial asset claims cannot consume the
last receipt unit while leaving cash behind.

Run `forge test --match-contract 'ERC(4626Deposit|7540Redeem)Test'` and
`forge test --match-contract '.*ReentrancyTest'`. Token-callback tests are
adversarial synthetic fixtures, not evidence that arbitrary tokens are supported.
