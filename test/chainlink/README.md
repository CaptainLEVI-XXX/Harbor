# Exact-fill permit tests

```sh
forge test --match-contract HarborPolicyReceiverTest
forge test --match-contract PermitTradingTest
```

`HarborPolicyReceiver` implements the pinned upstream Chainlink `IReceiver`.
The forwarder, encoded workflow identity, Book, vault, chain selector, public
model and policy are fixed at deployment. Governance/guardian may invalidate
existing permits by advancing the authorization epoch; they cannot move tokens
through this contract. Changing the workflow/model requires a new reviewed
deployment, not an unrestricted setter.

Metadata is exactly 64 bytes:

| Byte offsets | Type | Meaning |
| --- | --- | --- |
| 0–31 | bytes32 | Workflow ID |
| 32–41 | bytes10 | Upstream-encoded workflow name |
| 42–61 | address | Workflow owner |
| 62–63 | bytes2 | Report ID, emitted for traceability |

The report is the 15-word `HarborPolicyReceiver.Report` ABI tuple. Integer amounts
and times must not pass through JavaScript floating point. `finalFillDigest`
comes from `HarborExecutor.fillDigest`; the workflow must verify the complete
candidate against that digest and its public observation commitment. A permit
does not reserve capital, consume a trade nonce or establish LP NAV.

Repeated identical, still-valid reports make no additional write/event. Conflicting
nonce reuse and attempts to extend a digest's expiry with another nonce fail.
Distinct out-of-order reports remain independent. Cancelled digests cannot be
revived; clients must obtain a genuinely fresh quote and approval.

The tests use `MockCREForwarder`, which does **not** verify DON signatures. They
exercise actual receiver authentication checks and official Aqua settlement
through Harbor's SwapVM-derived router,
but are not CRE CLI simulation, testnet delivery or confidential execution evidence.
Do not deploy the mock forwarder as a real-funds authority. Missing secrets or
service access must not enable signature-only trading.

Before live use, verify the network's official forwarder, exact workflow metadata,
account capabilities, measured permit latency and expiry budget. CLI/workflow and
real confidential execution remain separate integration gates. Only disposable
fixtures may be used in non-confidential simulation.

References: [consumer contract guide](https://docs.chain.link/cre/guides/workflow/using-evm-client/onchain-write/building-consumer-contracts),
[pinned forwarder source](https://github.com/smartcontractkit/chainlink-evm/blob/b6427ea1f4847d640abdf24dbd6c6f01d7799d59/contracts/cre/src/v1/KeystoneForwarder.sol).
