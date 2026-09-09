# Native issuer checks

`Issuer.t.sol` keeps two adapter failure checks and two Book/Vault recovery flows.
Malformed split results must roll back the request; short payment or an issuer
right that remains live must not be accepted as final closure. Keeper intents
remain bound to the deployment, current position, split amounts and nonce.
Measured recovery can fund pending LP exits.

Shared setup uses synthetic wstETH/WETH and a fault-injecting issuer queue.
These tests do not prove complete Lido conformance, live timing, every donation
case or every ownership transition. The separate fork tests cover a real request
and an independently mature historical recovery at pinned blocks.

The current adapter uses underlying-unit request bounds and fixed-vault recovery.
Lido's native path does not provide partial claims. Issuer checkpoint hints locate
a finalized request; they cannot make an unfinalized withdrawal payable.
