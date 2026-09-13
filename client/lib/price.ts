import { formatWei, formatWeiFixed, group, parseWei } from '@/lib/format';

export type DisplayPrices = { WETH: bigint; wstETH: bigint; fetchedAt: number };

/** Dollars per whole token, scaled 1e18. wstETH is priced through the pair rate. */
function usdPerToken(symbol: string, prices?: DisplayPrices | null): bigint {
  // ETH and WETH are the same asset to a price feed; only the wrapper differs.
  const key = symbol === 'ETH' ? 'WETH' : symbol;
  const price = key === 'WETH' || key === 'wstETH' ? prices?.[key] : undefined;
  if (!price || price <= 0n) throw new Error(`A fresh ${symbol}/USD display-price source is required for conversion.`);
  return price;
}

/**
 * Token wei -> dollars, scaled 1e18. Bigint throughout, like format.ts: a
 * double would lose the wei and quote a plausible wrong figure.
 */
export function toUsdWad(wei: bigint, symbol = 'WETH', decimals = 18, prices?: DisplayPrices | null): bigint {
  return (wei * usdPerToken(symbol, prices)) / 10n ** BigInt(decimals);
}

/** Dollars (scaled 1e18) -> token wei. Rounds down: never more than was asked for. */
export function fromUsdWad(usdWad: bigint, symbol = 'WETH', decimals = 18, prices?: DisplayPrices | null): bigint {
  return (usdWad * 10n ** BigInt(decimals)) / usdPerToken(symbol, prices);
}

/** "$4,120.00" - for reading, never for parsing back. */
function formatUsd(usdWad: bigint): string {
  const negative = usdWad < 0n;
  const body = group(formatWeiFixed(negative ? -usdWad : usdWad, 18, 2));
  return `${negative ? '−' : ''}$${body}`;
}

/** The dollar value of a token amount, formatted. */
export function usd(wei: bigint, symbol = 'WETH', decimals = 18, prices?: DisplayPrices | null): string {
  if (!prices) return 'USD unavailable';
  return formatUsd(toUsdWad(wei, symbol, decimals, prices));
}

/** Which unit an amount field is being typed in. */
export type Unit = 'token' | 'usd';

/** What the user typed, as token wei, whichever unit they typed it in. */
export function typedToWei(typed: string, unit: Unit, symbol: string, decimals = 18, prices?: DisplayPrices | null): bigint {
  if (unit === 'token') return parseWei(typed, decimals) ?? 0n;
  if (!prices) return 0n;
  return fromUsdWad(parseWei(typed, 18) ?? 0n, symbol, decimals, prices);
}

/**
 * Token wei as the text an input shows in `unit`. Ungrouped, because the
 * user edits it: a comma in an input is something to delete, not to read.
 */
export function weiToTyped(wei: bigint, unit: Unit, symbol: string, decimals = 18, prices?: DisplayPrices | null): string {
  return unit === 'token' ? formatWei(wei, decimals, decimals) : formatWei(toUsdWad(wei, symbol, decimals, prices), 18, 2);
}
