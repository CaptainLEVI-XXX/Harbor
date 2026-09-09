# Stateful accounting checks

```sh
FOUNDRY_PROFILE=invariant forge test --list
FOUNDRY_PROFILE=invariant forge test
```

The profile runs 256 sequences of 64 calls per campaign and fails on unexpected
handler reverts. Default `forge test` also runs shorter campaigns. Target selectors
are explicit; setup and test-only keeper relays cannot be selected by the fuzzer.

`PortfolioInvariantTest` uses three LPs, two synthetic routes, the actual Harbor
Book/Vault/Executor, official Aqua, Harbor's SwapVM-derived router, and LidoAdapter
with a synthetic queue.
It independently tracks accounted cash, quarantined donations, LP share balances
and supply, pending FIFO tickets, funded reserves/credits, warehouse basis,
issuer basis, rights and realized gains/losses. FIFO funding uses a binary-search
reference rather than the implementation's inverse formula. Small bounded
amounts permit simple checked multiplication in the reference ledger.

Operations include all four trade modes, deposits, share transfers, requests,
partial FIFO funding, LP claims, issuer requests/recoveries and strategy refresh.
A documented prelude guarantees each mode and issuer path is exercised; the
campaign additionally requires successful randomized actions beyond that prelude.
Expected unavailable quotes can be rejected by static preflight, but unexpected
execution or assertion failures cannot be swallowed as successful fuzzing.

`ClaimLifecycleInvariantTest` separately exercises two-route partial receipts,
remaining rights and loss closure through the accounting library. These are
synthetic issuer semantics. They do not assert that Lido supports partial claims,
nor prove another issuer adapter. The full portfolio campaign uses Lido's complete
closure path. Both campaigns complement, rather than replace, adversarial callback,
standards and pinned-fork tests.

`ReceiptPortfolioInvariantTest` adds canonical claim imports, both receipt trade
directions/modes, repeated acquisition, synthetic finalization, loss-bearing
recovery and replacement requests through the actual Book/Vault/Aqua path.
An independent ledger checks physical vault cash, carried cost, cumulative issuer
purchases/losses, receipt supply and economic position version. The prelude guarantees
three successful trades and a recovery; randomized actions skip unavailable
states, so handler call counts are not counts of completed fills. Shared-budget
and 64-position-cap boundaries also have deterministic regression tests.
