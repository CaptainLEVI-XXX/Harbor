# One stateful claim check

```sh
FOUNDRY_PROFILE=invariant forge test
```

`ClaimLifecycleInvariantTest` runs 32 sequences of 16 calls. An independent
two-route ledger tracks requests, partial receipts and final closure. Cost
remains pending while a right remains live; only final closure realizes its
cash result. Purchase/loss counters and permanent closed-ID flags must survive.

The handler selects only request, partial receipt and close operations. Setup
ensures useful partial and closed states exist; unexpected reverts fail the run.
A handler call can be a no-op when its route has no suitable outstanding right,
so 512 calls does not mean 512 completed recoveries.

This is a library-level invariant with synthetic partial-right semantics.
Lido's supported native path closes whole requests; this does not claim that
Lido supports partial claims or that another adapter has been verified.

The larger pooled-vault and receipt-portfolio campaigns have been removed from
the active suite. Complete user flows remain in `test/core/`; long randomized
portfolio histories are a deliberate coverage gap for this hackathon scope.
