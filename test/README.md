# Harbor tests

There are **50 test/invariant entrypoints in the repository**, not a filtered
view of a larger suite: 46 local checks and four separate Ethereum fork checks.

```sh
forge test
```

## Layout and scope

| Folder | Tests | Purpose |
| --- | ---: | --- |
| `base/` | — | Shared setup, synthetic issuers and minimal helpers. |
| `core/` | 39 | Complete trading/redemption/LP flows, accounting, permissions, reports and reentrancy. |
| `swapvm/` | 5 | Packed parser reference, exact-fill registers, static authorization, receipt quantity and late-instruction rollback. |
| `invariant/` | 1 | Partial recovery preserves outstanding cost until the right closes. |
| `gas/` | 1 | Book, vault, executor, router and adapter remain within the EVM code-size limit. |
| `fork/` | 4 | Real issuer/token interactions at pinned blocks; requires RPC access. |

Start with [HarborSettlement.t.sol](core/HarborSettlement.t.sol). Core tests are
grouped into eight flat files by responsibility, rather than separate folders
for every contract or testing technique. Fuzz and unit cases stay next to their
flow; shared setup lives in `base/`.

The default command runs **all 46 local checks**, with 64 cases per fuzz test
and 32 sequences of 16 calls for the invariant. `forge test --list` shows them.
If a list-only compile leaves empty artifacts, rerun with `--force`; zero tests
is never a pass. `FOUNDRY_PROFILE=settlement forge test` remains an alias for the
same local suite, not the old 21-test subset.

Use `FOUNDRY_PROFILE=fork forge test` for the four network-dependent checks.
The compatibility profile selects the actual permit-to-Aqua trading flow;
invariant and gas profiles select their single retained check.

## Deliberate limits

This is hackathon coverage, not a production security claim. Removed test
matrices and longer portfolio handlers remain recoverable in Git, not hidden
or disabled in another active folder. The retained suite is not exhaustive over
configuration combinations, all malformed inputs, token behaviors, or long
portfolio histories. No full standards-conformance or decoder-proof claim is made.

Local marks, issuer finalization and report delivery are synthetic. Fork checks
need an archive-capable RPC; advancing time does not finalize Lido withdrawals.
Live CRE delivery, indexer reorg recovery, production valuation calibration and
an independent security review remain outside this suite.

See [core checks](core/README.md), [invariant assumptions](invariant/README.md),
[fork requirements](fork/README.md) and [size measurement](gas/README.md).
