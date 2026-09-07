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
