# Pinned issuer fork checks

```sh
FOUNDRY_PROFILE=fork forge test --match-contract LidoAdapterForkTest -vv
```

Set `HARBOR_MAINNET_RPC_URL` locally for an archive-capable endpoint; never commit
its credentials. A public RPC is the fallback, but its historical access may
expire or require a token. An RPC failure is a failed check, not a skipped pass.

Ethereum block: **25,924,311**

Block hash: `0xfb055f2fab35bcaa52709f6013b6cb5766fefeb4537d61e033a30167f196ebba`.

Queue proxy: `0x889edC2eDab5f40e902b864aD4d7AdE8E412F9B1`.
Implementation: `0xE42C659Dc09109566720EA8b2De186c2Be7D94D9`.
The test asserts the implementation identity at this block; this is not a promise
that the upgradeable issuer will retain that implementation on later blocks.

Two distinct proofs:

1. Production `LidoAdapter` consumes real wstETH, requests through the real queue,
   and owns the new unfinalized NFT. Test ETH funds the submitter; issuer/token
   storage is not rewritten. The request cannot immediately be claimed.
2. `HistoricalLidoHarness` exercises inherited production claim code with mature
   request **134,829**. Its actual owner is impersonated only on the local fork to
   transfer the NFT; a test-only method seeds the adapter's tracking ledger. The
   actual issuer pays ETH, which the adapter wraps and transfers to its fixed
   beneficiary. No issuer finalizer/oracle is impersonated and no issuer cash is
   injected. This harness is not a production import capability.

The second proof does **not** show the newly created request maturing, a Book
purchase becoming that historical NFT, or a complete multi-day Harbor lifecycle.
Local synthetic lifecycle tests provide complementary accounting evidence, not a
substitute for eventual end-to-end issuer observation.

## Receipt trading and recovery

```sh
FOUNDRY_PROFILE=fork forge test --match-contract RedemptionMarketForkTest -vv
```

This separate fixture pins Ethereum block **25,930,239**, asserts the same queue
implementation and uses real mainnet wstETH, unstETH and WETH. Both tests passed
against the public fallback during development. Historical RPC availability is
not guaranteed; use an archive-capable endpoint to reproduce them later. The
older adapter fixture remains pinned to its original block.

The first test submits ETH through real wstETH, requests withdrawal, wraps the
new NFT in a production factory receipt, then sells one receipt for **0.99 WETH**.
Official Aqua and the Harbor SwapVM router are deployed locally on the fork.
Maker/authorization hooks are compatibility fixtures, not the full pooled Book.
Assertions cover real token movements and unchanged issuer cash during trading.

The second test transfers historical finalized request **134,829** from its
impersonated owner into `HistoricalReceiptHarness`. Only the harness can seed
this already-mature state; canonical factory receipts cannot import finalized
requests. Inherited production recovery/redeem logic collects real issuer ETH,
wraps WETH, pays the receipt holder and burns the unit. There is no mocked
finalization, queue-storage rewrite or injected issuer recovery cash.

The new request and historical recovery are deliberately separate evidence.
Complete Book/vault ownership, LP reserves, permit checks and rollback are
covered by the complementary local `RedemptionMarketTest` suite.
