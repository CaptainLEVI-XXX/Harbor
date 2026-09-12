# Hoodi inventory seeding

This script populates the existing, funded Harbor Vault. It does not deploy contracts,
repeat LP deposits, create a buyer, buy back inventory, or fabricate activity.
LP_A and LP_B retain their shares. Trader A supplies token inventory; Trader B supplies
pending withdrawal NFTs. Sale proceeds remain with their respective traders.

## Inputs before broadcast

Use ignored `.env` for existing `HOODI_PRIVATE_KEY`, `HOODI_RPC_URL`, `LP_A`, `LP_B`
and two distinct signing keys, `TRADER_A` and `TRADER_B`. See
`script/config/inventory-hoodi.env.example` for public pool overrides. Do not put keys in
commands or committed files. This workflow does not generate or print private keys.

Agree the two new trader funding budgets, gas allowance, token inventory lot, NFT
count/sizes and minimum remaining Vault cash before broadcasting. Amount arguments
are integer wei, **not dollars**. For USD budgets, freeze a named ETH/USD observation
and its timestamp in the operator run record before converting to wei.
There is no default percentage allocation and no automatic sweep of wallet balances.

## Sequence

Every command below simulates only. Add `--broadcast` after reviewing the amounts
and explicit authorization. Replace uppercase placeholders; quote arrays without spaces.

1. **Fund traders, not LPs.** New principal plus a separate native gas top-up:

   `node --env-file=.env script/seed/seed-inventory-hoodi.mjs fund A_PRINCIPAL B_PRINCIPAL GAS_FLOOR`

2. **Acquire wstETH through Lido**, using explicit native amounts:

   `node --env-file=.env script/seed/seed-inventory-hoodi.mjs stake-a A_ETH MIN_A_WSTETH`

   `node --env-file=.env script/seed/seed-inventory-hoodi.mjs stake-b B_ETH MIN_B_WSTETH`

   The script checks the wstETH balance increase. This minimum is a simulation/
   receipt-review condition, not an onchain min-mint argument to Lido's receive function.
   Other wallet assets remain untouched. Leave native ETH for gas.

3. **Create 1–8 differently sized pending NFTs** from Trader B's wstETH:

   `node --env-file=.env script/seed/seed-inventory-hoodi.mjs request '[AMOUNT_1,AMOUNT_2,AMOUNT_3]'`

   Amounts are wstETH raw units. The script checks their stETH conversions against
   Lido's request bounds. The wrapper prints **confirmed IDs from mined
   WithdrawalRequested events** after broadcast. Never use IDs from Forge's simulation
   output for the next step: another user may mint before this transaction.

4. **Sell Trader A's chosen wstETH lot into Harbor**:

   `node --env-file=.env script/seed/seed-inventory-hoodi.mjs token WSTETH_AMOUNT MIN_ETH_OUT CASH_FLOOR`

   Exact token approval → Periphery → Aqua/SwapVM → Vault inventory.
   The Vault pays WETH; Periphery returns native ETH to Trader A.

5. **Sell the confirmed pending NFTs into Harbor**:

   `node --env-file=.env script/seed/seed-inventory-hoodi.mjs nfts '[ID_1,ID_2,ID_3]' '[MIN_ETH_1,MIN_ETH_2,MIN_ETH_3]' CASH_FLOOR`

   Per-ID NFT spending approvals are user permissions to Periphery, **not governor
   admission**. Book's issuer-wide policy prices the IDs. The adapter holds the NFTs
   and Book records their backing. There are no receipt clones or direct donations.

6. **Checkpoint NAV and refresh the Aqua allocation**:

   `node --env-file=.env script/seed/seed-inventory-hoodi.mjs publish`

   Token inventory is now allocated alongside remaining WETH. Raw NFTs use the
   same Book's direct settlement and do not need individual Aqua strategies.
   No buyer is used: inventory stays available for incoming users.

## Safety and operating limits

- The script targets Hoodi, the reviewed WETH/wstETH bindings, and zero protocol fees.
- Positive minimum sale proceeds are encoded in every actual Harbor trade.
- The remaining-cash floor is checked during simulation, using trading cash after
  funded-exit reserves. It is **not an atomic cash reservation across broadcasts**.
  Other trades can change balances between transactions. Re-simulate each stage;
  Harbor still enforces its onchain cash/risk gates. Do not run stages concurrently.
- Fresh pricing versions/generation and deadlines can invalidate prepared trades.
  Newly minted claims must still be pending at execution; finalization cannot be postponed.
- Stages contain multiple transactions. A later failure does not undo earlier mined
  funding, staking or approvals. The wrapper writes an exclusive per-stage journal
  before broadcast and blocks duplicate attempts. Preserve it, reconcile mined
  receipts and resume only known unmined transactions; never blindly clear the journal.
- Publish again only as a separately reviewed operation after reconciling the journal.
- Graph is already indexing this pool from deployment. Confirm its two strategy rows,
  trades and held NFT IDs catch up; do not present testnet activity as organic volume.

## Focused test

The existing fork deployment lifecycle is extended, not duplicated: two LPs, two
traders, real Lido staking/request creation, token/NFT sales, retained inventory,
cash/payout reconciliation, unchanged LP shares, executable asks and rejection of
duplicate NFT sales or a breached cash floor. All funds and identities are test-only.

`FOUNDRY_PROFILE=fork forge test --match-contract DirectNftForkTest --match-test test_ForkDeploymentScriptTwoLPsPoliciesAllocationAndFreshNftQuote -vv`

The fixture pins Hoodi block 3,611,419 and needs an RPC serving that historical state.
No live transaction is sent by this test.
