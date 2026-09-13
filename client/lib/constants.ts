import { concatHex, stringToHex, toHex } from 'viem';
import { hoodi } from 'viem/chains';

/** Public Hoodi deployment; never reuse these addresses on another network. */
export const chain = hoodi;
export const sponsored = false;
/** One RPC for reads, receipts and the embedded wallet; blank uses the chain's public endpoint. */
export const RPC_URL = process.env.NEXT_PUBLIC_HOODI_RPC_URL || undefined;
/** How often a pending transaction is re-checked. A Hoodi block is ~12s, so 4s idled. */
export const RECEIPT_POLL_MS = 1_000;
/**
 * The priority fee floor, in wei. Hoodi tips run ~0.02-0.1 gwei, so 2 gwei is
 * 20x the going rate: first in the next block. It cannot beat the block itself.
 */
export const PRIORITY_FEE_FLOOR = 2_000_000_000n;
/** a suggested tip above the floor is multiplied by this */
export const PRIORITY_FEE_MULTIPLE = 3n;
export const deploymentEnabled = !process.env.NEXT_PUBLIC_CHAIN || process.env.NEXT_PUBLIC_CHAIN === 'hoodi';
export const TOKENS = {
  WETH: '0xe0decaa66aed871ac9eb924443d1bf333fdb062e',
  wstETH: '0x7e99ee3c66636de415d2d7c880938f2f40f94de4',
} as const;
// Harbor repository: script/records/harbor-nft-hoodi.deployment.json.
export const HARBOR = {
  book: '0x5fb29f20ed466840bd2416f15f7b5312089b8d6e',
  vault: '0x40a83d1fee0f7f293c658eb264a3681517a7d6c6',
  executor: '0x4b5e79ee4af0ea1b91bf5fdac9187ff7d63d6ebe',
  adapter: '0x3e6fa785b4c47e4faff6021d0d4acbef05913d8f',
  queue: '0xfe56573178f1bcdf53f01a6e9977670dcbbd9186',
  periphery: '0x7f66f42dff023f5bdb6f12e471f9ac90c0011fb8',
  inventoryRoute: 0n,
} as const;
export const GRAPH_ENDPOINT = 'https://api.studio.thegraph.com/query/75221/harbor/0.2.0-hoodi';
export const GRAPH_DEPLOYMENT = 'QmXa2RCMR7BR13SzYpc7poxqUvUVhbNBKiXUk6csRBfuqv';
export const POOL_ID = concatHex([stringToHex('harbor:pool:v1'), toHex(chain.id, { size: 32 }), HARBOR.book]);
export const ASSET_DECIMALS = 18;
export const SHARE_DECIMALS = 24;
export const WAD = 10n ** 18n;
export const SHARE_OFFSET = 10n ** 6n;
export const ASSETS = {
  ETH: { address: TOKENS.WETH, symbol: 'ETH', name: 'Ether', decimals: ASSET_DECIMALS },
  wstETH: { address: TOKENS.wstETH, symbol: 'wstETH', name: 'Wrapped staked Ether', decimals: ASSET_DECIMALS },
} as const;
export const AUTO_SLIPPAGE_BPS = 250n;
export const QUOTE_LIFETIME_SECONDS = 300n;
export const QUOTE_REFRESH_MS = 15_000;
export const PREVIEW_ACCOUNT = '0x0000000000000000000000000000000000000001';
export const WITHDRAWAL_BATCH_SIZE = 8n;
