/** Reference display price only. Never used as a Harbor quote or NAV oracle. */
export async function GET() {
  try {
    const response = await fetch('https://api.coinbase.com/v2/prices/ETH-USD/spot', {
      cache: 'no-store', signal: AbortSignal.timeout(8_000),
    });
    if (!response.ok) throw new Error('Price provider unavailable');
    const { data } = await response.json();
    if (data?.base !== 'ETH' || data?.currency !== 'USD' || typeof data?.amount !== 'string' || !/^\d{1,8}(\.\d{1,18})?$/.test(data.amount) || Number(data.amount) <= 0) throw new Error('Invalid reference price');
    return Response.json({ ethUsd: data.amount, fetchedAt: Date.now(), source: 'Coinbase ETH-USD spot' }, {
      headers: { 'Cache-Control': 'public, max-age=30, s-maxage=30' },
    });
  } catch {
    return Response.json({ error: 'ETH/USD reference temporarily unavailable' }, { status: 503 });
  }
}
