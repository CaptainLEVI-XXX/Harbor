# Historical issuer subgraph

This package indexes withdrawal requests, inclusive finalization ranges, and actual claims. It does not run the Harbor pricing model or store simulated trades. The research runner remains outside the repository; `backtesting/` is not needed.

## Current scope

The implemented issuer adapter is `lido-inclusive-v1`, with Ethereum history frozen at block 22,000,000. The second configuration (`fixture-arbitrum`) tests another chain ID and six-decimal metadata. It is not a deployed Arbitrum issuer or an additional historical dataset.

The data contract is reusable across chains. A new EVM deployment needs a reviewed chain/network binding, actual issuer address and ABI, start/cutoff blocks and canonical hash, chain-scoped assets, finality support, and reference evidence. A different issuer needs a semantic adapter. Non-EVM chains need a different ingestion implementation. One Graph deployment indexes one chain.

## Build and test

From the repository root, with Node 22+ and `graph/` dependencies installed:

```sh
npm --prefix graph run history:verify
```

This runs existing analytics checks, focused exporter/normalizer tests, identical-source Ethereum/Arbitrum builds, and native Matchstick fixtures on both builds. Matchstick 0.6.0 is required; Graph CLI uses its cached binary or downloads it on supported platforms. Build artifacts are isolated under `history/.build/<series>/`.

For the full archived event replay:

```sh
npm --prefix graph run history:replay -- --reference "$RESEARCH_ROOT"
```

Run `history:build` first. The replay covers every archived event in bounded chronological windows using the production stub runtime. Each window starts from independently reconciled prior counters and the request prefixes needed by that window, then executes the compiled handlers and compares every stored field and closing counter. This avoids retaining an entire multi-year replay in one WASM allocation. It is a handler fixture replay, not continuous Graph Node indexing or rollback verification.

## Export a dataset

The reference archive contains `work/raw/{requested_complete,finalized_complete,claimed_complete}.json.gz`, `checkpoint_rates.json`, `study_snapshot.json`, frozen deployed-source evidence, `work/decoded/{requests,finalizations,claims}.csv`, and `outputs/boundary_audit.json`. Exact file hashes are pinned in `evidence/<series>.json`; the original source files are not copied here.

```sh
npm --prefix graph run history:cache -- --reference "$RESEARCH_ROOT" --out "$DATASET_DIR"
```

Use a new external output directory or `graph/.local/history/<dataset>/`. This command always produces `CACHED_RESEARCH`, checks every historical record and exact cutoff totals, and refuses output overwrites. Amounts, shares, rates and IDs remain integer strings. Raw facts and future outcome labels are separate files.

After deploying the generated finite subgraph and checking the provider's retained history, set `HISTORY_GRAPH_URL`, `HISTORY_RPC_URL`, and the reviewed deployment CID in your environment. Do not put credentials in source files or command-line URLs.

```sh
npm --prefix graph run history:export -- --reference "$RESEARCH_ROOT" --out "$DATASET_DIR" --series ethereum-lido-2025-03 --deployment "$REVIEWED_DEPLOYMENT_CID" --mode STUDIO
```

Modes: `STUDIO` permits `https://api.studio.thegraph.com/query/...`; `GATEWAY` permits `https://gateway.thegraph.com/api/subgraphs/id/...` with `GRAPH_API_KEY` in the authorization header; `LOCAL` permits local Graph Node `/subgraphs/name/...` URLs. RPC header verification uses the existing HTTPS-only reader and requires `eth_chainId`, a numeric cutoff header, and `finalized`.

Every page is pinned to the same canonical block hash and deployment. Partial GraphQL errors, indexing errors, incomplete series, count/cursor mismatches, foreign series, and canonical changes abort the export. Resume files beside the output are bound to the query/configuration/deployment/cutoff identity and integrity-checked. Only successful Graph/reference comparison yields `GRAPH_VERIFIED`.

Datasets contain `manifest.json`, `facts.json`, `outcomes.json`, `checkpoints.json`, and `reconciliation.json`. Manifest content hashes use SHA-256 of JSON with lexically sorted object keys; source hashes are SHA-256 of exact bytes. Checkpoint evidence remains explicitly identified as cached cutoff storage, reconciled to observed claims. These labels must never be presented as historical Harbor executions.

## Adapter invariants

- Request IDs must start at 1 and be contiguous. Starting mid-queue without a separate verified bootstrap fails closed.
- Prefix sums let a finalization handler read at most two requests, regardless of batch size. The mapping stores a single inclusive range; expansion occurs offchain.
- Claims preserve both owner and receiver. A claim must follow finalization; exact checkpoint payout validation occurs in the normalizer.
- Recovery follows the deployed integer branch: use face unless `floor(face * 10^27 / shares) > checkpointRate`; otherwise use `floor(shares * checkpointRate / 10^27)`. A `min` simplification differs at rounding boundaries.
- Event replay is idempotent. Conflicting logical IDs or missing history leave a persistent incomplete flag and issue record.
- Network, series and entity domains are encoded into IDs. Monetary values are raw units; changing display decimals never rescales stored values.

## Adding a chain or issuer

1. Add and review the EVM chain ID/network binding in `chains.json`. This does not by itself admit provider finality or source coverage.
2. Add a separate series in `networks.json`, with actual onchain identities, complete coverage, immutable cutoff and reviewed finality. Use a new dataset version when extending a cutoff.
3. Reuse the Lido adapter only if the issuer's semantics and event signatures match. Otherwise implement and test a new adapter, including its prefix/range/recovery semantics and conversion rules.
4. Add a separately frozen reference evidence file and normalizer support. The current cache importer is for the Lido archive format; it is not a generic arbitrary-CSV upload API.
5. Compile and run fixtures, then index on Graph Node, test controlled canonical rollback, query the pinned cutoff, and reconcile real data. Promote source status only after those checks.

No contract, live Harbor subgraph, or deployed endpoint is changed by these commands. Live indexing, Graph Node rollback, and hosted Graph export were not verified during the offline implementation. Model replay and the four benchmark charts remain the next milestones.

## Website pricing analytics

The client `/analytics` page reads a small checked artifact produced by `history:publish-analytics`. The graph indexes issuer facts; the external research study supplies the frozen pricing simulation. No research runner or raw simulation ledger is added to the contract repository.

The four display names are **Harbor**, **Fixed-delay pricing**, **Age-based pricing**, and **Queue-aware valuation**. Harbor is the main FACE research replay. Queue-aware valuation is the no-capacity comparison. They share a valuation forecast. Exact-contract parity and protocol-venue comparisons are out of scope by user request.

```sh
npm --prefix graph run history:publish-analytics -- "$DATASET_DIR" "$BENCHMARK_PREVIEW_DIR" "$CLIENT_DIR/data/analytics/benchmark.json"
```

This verifies the history manifest and every content hash, normalizes issuer outcomes, checks the original research input hashes, and reconciles the exact face, recovery and settlement time of all simulated fills against issuer history. All four ledger aggregates and histogram counts must match. It writes an atomic compact artifact with no credentials or local research paths. The command supports this frozen Ethereum Lido study only; another chain needs its own matching research dataset, not a metadata rename.

A cache export stays `CACHED_RESEARCH` in the page. Only a successful `history:export` followed by the publisher produces `GRAPH_VERIFIED`; this label describes issuer-history evidence, never live Harbor executions. The website can also read an atomically replaced artifact through its server-only `HARBOR_ANALYTICS_FILE` variable. With the bundled file, rebuild/redeploy the client after publication.

### Completing the live hosting step

Use a separate historical subgraph slug, preserving the existing Hoodi trading subgraph:

```sh
# Configure GRAPH_DEPLOY_KEY and HISTORY_GRAPH_SLUG in the process environment.
npm --prefix graph run history:deploy -- ethereum-lido-2025-03 0.1.0
# Once indexing reaches the cutoff, configure HISTORY_GRAPH_URL and HISTORY_RPC_URL.
npm --prefix graph run history:export -- --reference "$RESEARCH_ROOT" --out "$GRAPH_DATASET_DIR" --series ethereum-lido-2025-03 --deployment "$REVIEWED_DEPLOYMENT_CID" --mode STUDIO
npm --prefix graph run history:publish-analytics -- "$GRAPH_DATASET_DIR" "$BENCHMARK_PREVIEW_DIR" "$CLIENT_DIR/data/analytics/benchmark.json"
```

`history:deploy` rejects the current `harbor` live slug, unknown series and build fixtures. It keeps the deploy key out of OS arguments and redacts credentials from CLI output. Deploying to Studio is distinct from publishing to the decentralized network; this command does not submit an onchain publication transaction.

At website implementation time no historical Graph endpoint, deployment CID or deployment credentials were configured. Live indexing/export and a controlled Graph Node rollback test therefore remain unexecuted. Offline checks must not be reported as those live tests.
