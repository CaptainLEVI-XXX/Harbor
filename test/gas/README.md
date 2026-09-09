# Deployment-size gate

```sh
FOUNDRY_PROFILE=gas forge test
```

One test checks Book, Vault, Executor, Harbor router and Lido adapter against
the 24,576-byte runtime limit and compares their sizes with the committed
`HarborRuntimeBytes` snapshot. It uses Solidity 0.8.30, Cancun, via-IR and 700
optimizer runs, with the existing linked libraries.

Current recorded runtime sizes are Book 24,165, Vault 18,096, Executor 12,121,
router 23,017 and adapter 6,421 bytes. Book has only 411 bytes of headroom.
This check covers those five contracts, not aggregate deployment cost or every
linked-library/receipt implementation.

The broader transaction-gas matrix and parser microbenchmark were removed from
the active suite. Other existing snapshot JSON files are historical measurements,
not assertions executed by this test. Do not present them as current mainnet
transaction fees or as fresh benchmark results.

An intentional size-baseline update uses snapshot emit/check flags and a reviewed
diff. The absolute runtime limit must still hold; never increase the code-size
allowance to make a test pass.
