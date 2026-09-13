export type ActivityEvent = { id: string; timestamp: string; transactionHash: string; logIndex: string; blockNumber: string };
/** Graph values remain decimal strings until the presentation boundary. */
type StrategyHistory = {
  id: string; route: string; kind: string; label: string; settlementPath: string; base: string;
  inventoryUnits: string; inventoryBasis: string; pendingBasis: string;
  customerCashVolume: string; protocolFees: string; recoveredCash: string; realizedResult: string;
};
type ReceiptHistory = {
  id: string; address: string; owner: string; complete: boolean; redeemed: boolean;
  nominal: string | null; collectedCash: string; paidCash: string; createdAt: string;
};
export type History = {
  _meta: { deployment: string; hasIndexingErrors: boolean; block: { number: number; hash: string } };
  pool: { book: string; chainId: string; complete: boolean; portfolioChangedSinceCheckpoint: boolean;
    lastCheckpoint: null | { nav: string; supply: string; cash: string; reserved: string; inventoryMark: string; claimMark: string; timestamp: string; observedAt: string } };
  strategies: StrategyHistory[];
  trades: { id: string; timestamp: string; buyBase: boolean; amountIn: string; amountOut: string; customerCash: string; fee: string; transactionHash: string; logIndex: string; blockNumber: string; tokenId: string | null; strategy: { kind: string; route: string; label: string } }[];
  exitRequests: { id: string; requestedShares: string; pendingShares: string; fundedAssets: string; requestedAt: string; fundingCompletedAt: string | null; requestTransaction: string; requestLogIndex: string }[];
  lpDeposits: (ActivityEvent & { receiver: string; assets: string; shares: string })[];
  claimRecoveries: (ActivityEvent & { cash: string })[];
  exitPayouts: (ActivityEvent & { assets: string })[];
  valuationCheckpoints: { id: string; nav: string; supply: string; cash: string; reserved: string; inventoryMark: string; claimMark: string; timestamp: string; blockNumber: string; logIndex: string }[];
  /** the latest 1000 of each, for the strategy chart's cumulative lines */
  tradeSeries: { timestamp: string; customerCash: string; strategy: { id: string } }[];
  realizations: { timestamp: string; result: string; strategy: { id: string } }[];
  /** the connected wallet's own deposits; empty for the public read */
  userDeposits: { assets: string; shares: string }[];
  receipts: ReceiptHistory[];
};

export async function getHistory(owner?: string): Promise<History> {
  const response = await fetch(`/api/harbor${owner ? `?owner=${encodeURIComponent(owner)}` : ''}`, { signal: AbortSignal.timeout(20_000) });
  if (!response.ok) throw new Error('Historical data is unavailable. Live contract actions remain separate.');
  return response.json();
}
