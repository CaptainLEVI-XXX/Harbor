# Harbor's Aqua / SwapVM strategy

Harbor deploys `HarborSwapVMRouter`, a subclass of the pinned official
`AquaSwapVMRouter`. The subclass adds one instruction; it does not replace
Aqua accounting, the VM loop, quote simulation, taker limits or transfer logic.
The unmodified official router does **not** support Harbor's program.

## Start here

| Component | Responsibility |
| --- | --- |
| `HarborProgram.sol` | Encode the vault's maker traits, hooks and strategy program. |
| `instructions/HarborExactFill.sol` | Decode maker arguments, obtain authorization, complete VM amounts. |
| `HarborSwapVMRouter.sol` | Dispatch the custom opcode; delegate other opcodes to upstream. |
| `../book/base/BookSettlement.sol` | Authenticate fills, consume nonces and verify transfer hooks. |
| `../book/base/BookState.sol` | Own the shared persistent ledger and transient operation context. |
| `../interfaces/IHarborFill.sol` | Narrow authorization interface, including its static-call view. |

The Book's other responsibilities live in `BookGovernance` and
`BookRedemptions`. These are abstract source modules, not deployed services.
They inherit one `BookState`; accounting libraries receive explicit storage
references. The concrete `HarborBook` binds deployment and exposes portfolio
views. Splitting source files is not itself a bytecode optimization.

Similarly, `HarborVault` exposes LP entrypoints, `VaultSettlement` owns Book
callbacks and Aqua publication, and `VaultState` owns accounting and cross-call
coordination. All three are one deployed vault; no intermediate custody is added.

## Program and instruction format

```text
Salt(version) -> HarborExactFill(book, route, version)

Instruction byte offsets (including header):
  [0, 1)   opcode 0x55
  [1, 2)   argument length 84
  [2, 22)  authorization Book, packed 20-byte address
  [22, 54) route, full-width uint256
  [54, 86) strategy version, full-width uint256

Remaining taker arguments:
  abi.encode(Trade, FillTerms, signature)
```

`0x55` is an unused swap-family slot in the pinned upstream opcode table.
It is a **local Harbor assignment**, not a registered 1inch instruction.
The collision test must be revisited whenever the dependency pin changes.
The router's capability getter catches accidental deployment against an old
router, but is not a substitute for verifying source, bytecode and dependencies.

The canonical order enables Aqua mode with the vault as maker and recipient.
The vault itself calls Aqua `ship` against the Harbor router. Refreshing docks
the old strategy and uses a fresh salt/hash. The router, not the Book, is the
registered Aqua application. LPs deposit into the vault; this is not a claim
that deposited LP assets remain in individual users' wallets.

## Register contract

| Field | Exact input | Exact output |
| --- | --- | --- |
| `amountIn` | Must equal authorized input; preserve it. | Set to authorized input. |
| `amountOut` | Set to authorized output. | Must equal authorized output; preserve it. |
| `balanceIn`, `balanceOut` | Preserve. | Preserve. |
| Query, fee metadata, next program counter | Preserve. | Preserve. |

Both amounts must be nonzero. The instruction applies no price rounding:
the Book verifies the signed pair through the existing fee/amount and public
price checks. In particular, exact-output gross input must still be minimal
under Harbor's fee rounding. A supplied pair alone is never authority to spend.

The Book cannot return arbitrary registers, a program counter, or a consumed
byte count. This intentionally narrows the earlier generic `Extruction`
integration. The custom instruction consumes all remaining taker arguments.
Instructions requiring their own taker arguments must precede it. Harbor's
canonical program has no subsequent fee/amount transformations; its hooks bind
the final pair. Upstream Salt/Deadline composition and late-failure rollback
are tested separately without changing that canonical program.

## Authority and lifecycle

```text
Executor opens Book and Vault locks
  -> OPENED
HarborExactFill calls Book.authorizeFill
  -> AUTHORIZED (quote + trader nonces consumed)
Router transfers input, Book checks exact maker credit
  -> INPUT_RECEIVED
Router requests permission for output
  -> OUTPUT_AUTHORIZED
Router transfers output, Book checks debit and records inventory basis
  -> OUTPUT_SENT
Executor verifies results, clears allowance, pays fee and user
Book/Vault reconcile cash and explicitly clear context
  -> IDLE
```

The Book checks the immutable router, vault maker, executor taker, shipped order,
route/version, token direction, signed payload, independent permit, live cash,
inventory, reserves and risk budgets. The instruction calls authorization via
`STATICCALL` in quote mode and `CALL` in swap mode. Quote mode cannot consume
nonces even if a faulty authority attempts a write.

Any subsequent instruction, transfer, hook or executor payout failure rolls
back the Book's nonce consumption and accounting along with token movements.
An idle quote is only a preflight, not a reservation or a guarantee of execution
after state changes. Issuer requests and funded LP claims are separate domains.

## Low-level code and evidence

Packed maker arguments are decoded by three bounded `calldataload` operations.
The exact 84-byte length check precedes assembly; the last read ends at byte 84.
The address is explicitly shifted to 160 bits. This block does not write memory,
persistent storage or transient storage. Ordinary typed transient fields own
the lifecycle; durable accounting has not been converted into manual slots.

`HarborExactFill.t.sol` compares parsing against readable slicing/ABI decoding
and tests arbitrary route/version/address values, malformed lengths, zero
authority, register preservation, static-write rejection and nonce rollback.
Its parser microbenchmark uses separate contracts with the same single external
selector: 383 versus 452 gas under the pinned compiler settings. This is a
69-gas parser-call improvement, not a whole-transaction savings claim.

```sh
forge test --match-path 'test/swapvm/*.t.sol' -vv
forge test --match-contract VaultAquaSwapVMTest -vvvv
forge test --match-contract FourModeTradingTest -vvvv
FOUNDRY_PROFILE=invariant forge test
FOUNDRY_PROFILE=gas forge test
```

Tests include rejection by the unmodified official router, unknown-opcode
fallback, truncated bytecode, all four trading modes, exact Aqua token movements,
publication ownership, input-first ordering and complete late-failure rollback.
Synthetic assets, marks and permits are not live capital or model-validation
evidence. See the root demo and integration test documentation for proof limits.

## Deployment compatibility

This changes the router deployment, maker program hash and Book authorization
callback ABI. It is not an in-place upgrade of an existing immutable deployment.
Old `Extruction` orders and signatures must not be reused. Deploy and verify the
Harbor router first, bind its address in the Book/Executor, then publish fresh
vault strategies and generate new quotes. The local deployment gate remains.
