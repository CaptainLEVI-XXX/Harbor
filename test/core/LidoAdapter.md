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

The adapter owns issuer conversion/valuation, NFT custody and separate native/
tokenized claim domains. Native recovery pays only the fixed Vault. Generic receipt
recovery credits only its claim; holder redemption burns the unit and pays that
credit. The existing redemption-market tests cover two-claim cash isolation,
aggregate shortage, retirement, issuer outage after collection and payout rollback.
The batch check covers all 64 pending/finalized/credited observations in shuffled
caller order, nonadjacent duplicates and unknown IDs. The request regression
bounds split-conversion rounding dust without treating it as cash.

The current native path uses underlying-unit request bounds and fixed-vault recovery.
Lido's native path does not provide partial claims. Issuer checkpoint hints locate
a finalized request; they cannot make an unfinalized withdrawal payable.
