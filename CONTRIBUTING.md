# Contributing Guidelines

This repository contains smart contracts. Contributions should be small,
well-tested, and easy to review. A reviewer should be able to understand the
whole change, including its permissions and accounting consequences.

## Code of Conduct

Be respectful, constructive, and professional. Focus feedback on the work,
not the person. Harassment, personal attacks, and abusive behaviour are not
acceptable.

## Getting Started

1. Fork the repository and create a branch from the latest `main`.
2. Install Foundry. The development toolchain is Foundry v1.8.1.
3. Install the pinned Solidity dependencies with Forge:

```sh
forge install
```

All Solidity dependencies are Git submodules under `lib/`, pinned by Git links
and `foundry.lock`. No npm installation is required for contracts. The selected
releases are 1inch solidity-utils 6.9.10 and OpenZeppelin 5.4.0; Aqua remains
`9c5c42e5840e8741fba3597c48456c9510212b66` and SwapVM remains
`f09a41e689240adc645934f965c8061749397cd2`.

Chainlink's `IReceiver` comes from `chainlink-evm` commit
`b6427ea1f4847d640abdf24dbd6c6f01d7799d59`. Its version-qualified IERC165
import alone is mapped to the existing OpenZeppelin 5.4.0 interface: the
`supportsInterface(bytes4)` ABI is unchanged. This is not a remapping of all
OpenZeppelin 5.0.2 implementations to another release. No Chainlink npm tree is
needed for the Solidity receiver.

Build, test, and check formatting:

```sh
forge build --sizes
forge test
forge fmt --check
```

Run `forge fmt` on the files you changed before submitting. Avoid unrelated
formatting churn. Use only profiles and test paths that exist in the checkout;
an empty or filtered test run is not evidence that an integration works.
Use `forge test --list` with the intended profile and filters to confirm the
expected suites are discovered before relying on a test run.

Fork tests must identify the network, block, deployed contracts, and required
RPC configuration. Missing RPC access is a skipped check, not a passing test.
Normal local tests should not depend on external infrastructure.

Never commit private keys, authenticated RPC URLs, access tokens, or real
credentials in examples. Dependency versions, lockfiles, and remappings must
remain consistent. Do not modify installed third-party code in place.

## Repository Layout

Organize code by responsibility. Keep paths predictable and avoid directories
that only wrap another directory. Do not introduce a deployed contract solely
to split a source file.

```text
src/             contract entrypoints and implementations
  adapters/      protocol-specific integrations
  interfaces/    first-party interfaces
  libraries/     reusable types, accounting, hashing, and math
  swapvm/        program construction and execution extensions
test/            unit, differential, integration, and security tests
  base/          shared fixtures and test-only helpers
  core/          accounting, vault, adapter, permit, and settlement tests
  swapvm/        custom instruction parsing, registers, and rollback
  invariant/     stateful accounting checks and handlers
  fork/          pinned-block issuer and token evidence
  gas/           deployed-size gate and snapshot reference
script/          reproducible setup and operational scripts
lib/             pinned third-party Solidity sources
```

This is a placement convention, not a claim that every directory or component
already exists. Create a directory when it has actual code to contain.

First matching answer determines where new code belongs:

| Question | Location |
| --- | --- |
| Does it define a first-party external interface? | `src/interfaces/` |
| Is it reusable accounting, encoding, or arithmetic? | `src/libraries/` |
| Does it encode a SwapVM program or implement its extension? | `src/swapvm/` |
| Does it translate one protocol's request or claim semantics? | `src/adapters/` |
| Does it own permissions, persistent accounting, or an entrypoint? | The responsible contract under `src/` |
| Is it a fixture, mock, harness, or reference implementation? | `test/` |

Import pinned upstream interfaces rather than copying their declarations.
Keep utility dependencies below the contract layer; a math library should not
depend on an executor or adapter implementation.

## Branch Naming

Use the kind of change and the behaviour it affects:

```text
feat/inventory-sales
fix/claim-beneficiary-check
test/settlement-rollback
docs/contribution-guide
refactor/quote-validation
```

## Commit Message Format

Use Conventional Commits:

```text
<type>(optional-scope): <short summary>

optional body

optional footer
```

- Summary: imperative mood, fewer than 72 characters, no trailing period.
- Body: optional. Use it for a necessary constraint or context, wrapped at 72
  characters. Keep extended design rationale in the pull request or code.
- Describe the actual change, not the process used to produce it.
- References must make sense from a public clone. Do not refer to private
  notes, local documents, task identifiers, or another local repository.
- Leave a blank line between summary, body, and footer.
- Use the configured Git identity. Do not pass `--author` to reattribute work.
- Commits are single-author; do not add `Co-Authored-By` or `Signed-off-by`
  trailers under this repository's contribution policy.

Types: `feat`, `fix`, `test`, `docs`, `refactor`, `perf`, `chore`, `audit`, `ci`.

```text
feat(swap): support inventory sales
fix(redemption): reject mismatched claim beneficiaries
test(accounting): preserve cost basis when splitting requests
perf(encoding): reduce quote hashing allocations
```

Keep one logical change per commit. Separate unrelated concerns. Commit work
as it is completed; do not fabricate dates, execution evidence, or history.

Do not bypass configured checks with `--no-verify`. If a check is wrong,
correct it in a reviewable change. This repository does not currently install
local Git hooks; do not assume these message rules are mechanically enforced.

## Coding Conventions

### Engineering references

Use [3F Labs](https://github.com/3FLabs/grunt) as a reference for readable
contract boundaries, domain libraries and differential tests, and
[Solady](https://github.com/Vectorized/solady) for precise primitive semantics
and measured optimization. Follow the practical discipline of
[Andrej Karpathy's coding observations](https://x.com/karpathy/status/2015883857489522876):
surface assumptions, keep changes surgical, and define verifiable outcomes.
These are references, not mandates to reproduce inheritance trees, assembly,
storage layouts or decorative comment styles. Dependency licenses still apply.

### Style and documentation

- Use two-space indentation, enforced by `forge fmt`.
- Use explicit visibility, mutability, and imports.
- Add an SPDX identifier and a compiler pragma compatible with pinned imports.
- Document contracts and libraries with `@title`, `@notice`, and useful `@dev`
  context. Author attribution must be accurate; never invent an attribution.
- Document parameters and return values, including units and rounding. Internal
  helpers need the same clarity when their safety depends on caller checks.
- Document struct fields, custom errors, events, and important storage fields.
- Use restrained ASCII section dividers in longer files, consistently.
- Explain invariants and non-obvious decisions; do not narrate obvious syntax.

### Imports

- Use named imports; no wildcard imports.
- Use remappings for external dependencies.
- Use repository-root paths for first-party imports, such as
  `src/interfaces/IHarborAdapter.sol`.
- Group related imports consistently with blank lines between groups.
- Do not copy or locally patch an upstream implementation to avoid a proper
  dependency/version decision.

### State and permissions

Persistent state belongs to the contract that owns its accounting and authority.
Keep that ownership explicit. Inherited modules must not introduce competing
copies of the same position, nonce, or balance ledger.

Use ordinary typed storage unless a concrete layout requirement justifies a
namespaced struct. Do not introduce proxies or ERC-7201 slot machinery only
for stylistic consistency. If namespaced storage is used, document and test the
slot derivation and keep the accessor in one place.

Transient storage is for transaction-local locks and callback context. Never
use it for claims, consumed nonces, cancellation versions, or durable budgets.
Clear successful-operation context explicitly so sequential calls in the same
transaction work. Static quote paths must not write transient storage.

Authenticate callbacks by caller and expected operation context. A trusted
router address alone does not authenticate every order it can execute. Keep
public interfaces narrow; avoid arbitrary targets, selectors, or unrestricted
`delegatecall`.

### Errors and libraries

Use custom errors with useful offending values or expected/actual values.
Parameterless errors are appropriate when there is no useful diagnostic value.
Revert directly; an assembly revert helper needs measured justification.

Keep error definitions beside their owning interface or in a shared domain
library when several modules use them. Avoid duplicate definitions with
different meanings.

Libraries should have a clear subject and no hidden authority. Pass storage
references explicitly when library logic updates state. Use `self` for a
subject parameter when that improves readability. Avoid single-use abstraction
layers that only rename an existing dependency function.

### Arithmetic and assembly

Use reviewed full-precision math and transfer helpers. State every primitive's
input domain, scale, and rounding direction. An observed conversion is not a
guarantee of future recovery; an allowance is not an available cash balance.

Assembly is permitted only for a demonstrated need. Every block must:

- Explain its layout, bounds, and caller obligations.
- Document any skipped checks in a `Safety considerations` comment.
- Use `assembly ("memory-safe")` only when its memory behaviour actually meets
  that contract; the annotation does not make unsafe code safe.
- Have differential correctness tests against a readable reference.
- Show a relevant gas or bytecode improvement before replacing readable code.

Use `unchecked` only with a documented bound. Validate narrowing casts before
packing. Do not reuse cached storage across an external call unless its validity
is proved. Do not replace checked financial arithmetic with Yul for appearance.

## Testing Requirements

Code changes must include proportionate tests. Documentation-only changes need
accurate commands, working references, and a check for accidental disclosure.

The retained suite has 50 test/invariant entrypoints: 46 local and four fork
checks. Prefer improving these flow tests to growing a second exhaustive suite.
Default fuzzing uses 64 cases; the single stateful campaign uses 32 x 16 calls.

- Start with a compact suite covering accounting, authorization, payouts and
  replay protection. Exercise one complete lifecycle with actual balances and
  entitlements, then add distinct failure cases rather than repetitive variants.
- Reuse shared setup and existing fixtures. Prefer one main test file for a
  cohesive change; do not add mocks, getter tests or upstream-library tests
  without a concrete first-party risk.
- Use compact arithmetic fuzzing where useful, with independently calculated
  expected results and meaningful boundary inputs. Fuzz runs must reach useful
  states, not merely avoid reverting.
- Add stateful invariants only when transaction sequences create a concrete
  risk. Use independent accounting and successful actions; an all-reverting
  campaign proves little. Do not require a new harness for every change.
- Every additional test should identify a plausible bug existing coverage misses.
  Keep the default workflow lightweight; expand campaigns or CI only for an
  unresolved risk. Report tests written separately from tests actually executed,
  with one focused run command and material gaps.
- Integration tests distinguish local mock assets from deployed protocol tests.
- Every bug fix gets a permanent regression test named for what it prevents.
  Do not delete coverage merely because the original bug is old.
- Test unauthorized callers, malformed inputs, expiry, replay, rounding,
  external-call failure, reentrancy, and complete rollback where relevant.
- Include sequential calls in one transaction when transient context is used.
- Record gas snapshots for execution changes once a reproducible baseline
  exists. Report compiler settings and cold/warm conditions with comparisons.

References and fixtures required by public tests must be available from the
checkout or reproducibly obtainable from documented public inputs. Tests must
not depend on unpublished local documents or private working directories.

Do not claim a suite passed if it was skipped, filtered to zero tests, or run
against different code. Record the actual command and relevant environment.
Synthetic finalization or loss fixtures must be labelled as synthetic.

## Pull Requests

Keep changes small and explain why they are needed. Public descriptions should
stand on their own without a private conversation or unpublished document.

Before opening:

- [ ] Build succeeds; no new unexplained warnings.
- [ ] Formatting checks pass for the changed code.
- [ ] Relevant unit, fuzz, integration, and invariant tests ran successfully.
- [ ] Required fork checks ran, or missing access is clearly disclosed.
- [ ] Gas evidence is included when execution costs change.
- [ ] Units, rounding, authority, and state ownership are documented.
- [ ] External calls, callbacks, and failure rollback have been reviewed.
- [ ] Any assembly has a reference test and measured justification.
- [ ] Dependency versions, remappings, and setup instructions agree.
- [ ] The staged diff contains only intended public files.
- [ ] No credentials, private notes, or unpublished working material are included.
- [ ] No configured hook or security check was bypassed.

Security-relevant changes must identify the invariant preserved or deliberately
changed. Do not describe unaudited code as production-ready.

## Publication Boundary

Publish implementation, reproducible tests, dependency information, and useful
contributor/user documentation. Keep local planning material, private research,
working notes, and review conversations out of commits, issues, pull requests,
release notes, generated artifacts, and public test output.

Describe behaviour in public filenames, branches, commits, comments, and test
names. Do not use private work-item labels or progress markers. Contract
lifecycle states are technical behaviour and should still be named clearly.

Before staging or pushing, inspect what Git will actually include:

```sh
git status --short
git diff --cached --name-only
git diff --cached
git diff --cached --check
```

Ignore rules are safeguards, not a confidentiality boundary: they do not
untrack existing files or prevent `git add -f`. Never force-add private material.
Review generated files and every commit being pushed, not only the working tree.

## Reporting Vulnerabilities

Do not disclose an unresolved vulnerability in a public issue or pull request.
Contact the maintainers privately with a reproduction and, where possible, a
failing test. Publish a sanitized regression test after coordinated resolution;
do not include credentials, private incident data, or exploitable deployment
details before disclosure is approved.
