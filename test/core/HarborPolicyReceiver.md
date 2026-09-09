# Exact-fill permit checks

`HarborPolicyReceiver.t.sol` retains three checks: forwarder/workflow identity,
idempotent duplicate delivery without extending expiry, and cancellation without
reviving a previously authorized digest. `Trading.t.sol` additionally executes
all four native trade modes through the real receiver and official Aqua, and
rejects a substituted receiver lacking its own exact-fill permit.

Metadata is 64 bytes: workflow ID (32), name (10), owner (20), report ID (2).
The report is the 15-word `HarborPolicyReceiver.Report` tuple.
`finalFillDigest` comes from `HarborExecutor.fillDigest`; the workflow must
validate the complete candidate and public observation commitment.

A permit does not reserve capital, establish NAV, replace the quote signer or
consume a trade nonce. Book independently checks economic bounds and replay.
Receiver identity/model fields are fixed at deployment; cancellation advances
its authorization epoch without gaining treasury authority.

`MockCREForwarder` does not verify DON signatures. These are simulated deliveries,
not live CRE, confidential execution or full metadata/domain fuzz coverage.
Do not deploy the mock as an authority for real funds.
