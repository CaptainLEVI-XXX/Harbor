import { requireValue } from "./types.js";
import type { Fraction, ReturnObservation } from "./types.js";

export function fraction(numerator: bigint, denominator: bigint): Fraction {
  requireValue(denominator > 0n, "INVALID_DENOMINATOR");
  let a = numerator < 0n ? -numerator : numerator;
  let b = denominator;
  while (b !== 0n) { const rest = a % b; a = b; b = rest; }
  return { numerator: numerator / a, denominator: denominator / a };
}

/** Parse bounded Graph decimal strings, including scientific notation, without Number. */
export function decimal(text: string): Fraction {
  requireValue(text.length <= 200, "DECIMAL_TOO_LARGE");
  const match = /^(-?)([0-9]+)(?:\.([0-9]+))?(?:[eE]([+-]?[0-9]{1,3}))?$/.exec(text);
  requireValue(match, "INVALID_DECIMAL");
  const exponent = Number(match[4] ?? "0") - (match[3]?.length ?? 0);
  requireValue(Math.abs(exponent) <= 200, "DECIMAL_TOO_LARGE");
  const digits = BigInt(match[2]! + (match[3] ?? "")) * (match[1] === "-" ? -1n : 1n);
  return exponent >= 0 ? fraction(digits * 10n ** BigInt(exponent), 1n) : fraction(digits, 10n ** BigInt(-exponent));
}

/** Human cash-token units per full LP share, matching Harbor's virtual-unit convention. */
export function harborShareValue(nav: bigint, supply: bigint, cashDecimals: number, shareDecimals: number): Fraction {
  requireValue(nav >= 0n && supply >= 0n, "NEGATIVE_AMOUNT");
  requireValue(Number.isInteger(cashDecimals) && cashDecimals >= 6 && cashDecimals <= 18 && shareDecimals === cashDecimals + 6, "INVALID_DECIMALS");
  return fraction((nav + 1n) * 10n ** BigInt(shareDecimals), (supply + 1_000_000n) * 10n ** BigInt(cashDecimals));
}

export function assetKey(chainId: number, address: string): string {
  requireValue(Number.isSafeInteger(chainId) && chainId > 0 && /^0x[0-9a-fA-F]{40}$/.test(address), "INVALID_ASSET");
  return `${chainId}:${address.toLowerCase()}`;
}

/** Returns a fraction, not APY. Source approval/freshness is an upstream responsibility. */
export function periodReturn(start: ReturnObservation, end: ReturnObservation): Fraction {
  requireValue(start.environment === "PUBLIC_CHAIN" && end.environment === "PUBLIC_CHAIN", "NON_LIVE_SERIES");
  requireValue(start.fresh && end.fresh, "STALE_OBSERVATION");
  requireValue(start.measurement === "HISTORICAL_SHARE_RETURN" && end.measurement === start.measurement, "MEASUREMENT_MISMATCH");
  requireValue(start.sourceId === end.sourceId && start.vaultId === end.vaultId && start.deployment === end.deployment, "SERIES_MISMATCH");
  requireValue(assetKey(start.chainId, start.assetAddress) === assetKey(end.chainId, end.assetAddress), "ASSET_MISMATCH");
  requireValue(start.methodologyVersion === end.methodologyVersion && start.treatment === end.treatment, "METHODOLOGY_CHANGED");
  requireValue(Number.isSafeInteger(start.timestamp) && start.timestamp >= 0 && Number.isSafeInteger(end.timestamp) && end.timestamp > start.timestamp, "INVALID_WINDOW");
  requireValue(Number.isSafeInteger(start.blockNumber) && start.blockNumber >= 0 && Number.isSafeInteger(end.blockNumber) && end.blockNumber > start.blockNumber, "INVALID_BLOCK");
  requireValue(/^0x[0-9a-fA-F]{64}$/.test(start.blockHash) && /^0x[0-9a-fA-F]{64}$/.test(end.blockHash) && start.blockHash.toLowerCase() !== end.blockHash.toLowerCase(), "INVALID_BLOCK_HASH");
  const a = start.shareValue, b = end.shareValue;
  requireValue(a.numerator > 0n && a.denominator > 0n && b.numerator >= 0n && b.denominator > 0n, "INVALID_SHARE_VALUE");
  return fraction(b.numerator * a.denominator - a.numerator * b.denominator, a.numerator * b.denominator);
}

/** Configuration-only equivalence: symbols and equal addresses across chains are insufficient. */
export function comparableAssets(a: ReturnObservation, b: ReturnObservation, groups: ReadonlyMap<string, string>): boolean {
  const left = assetKey(a.chainId, a.assetAddress), right = assetKey(b.chainId, b.assetAddress);
  return left === right || (groups.has(left) && groups.get(left) === groups.get(right));
}

export function alignedWindows(a: [ReturnObservation, ReturnObservation], b: [ReturnObservation, ReturnObservation], toleranceSeconds: number): boolean {
  requireValue(Number.isSafeInteger(toleranceSeconds) && toleranceSeconds >= 0 && toleranceSeconds <= 3600, "INVALID_TOLERANCE");
  periodReturn(...a); periodReturn(...b);
  if (a[0].chainId === b[0].chainId) {
    return a.every((point, i) => point.blockHash.toLowerCase() === b[i]!.blockHash.toLowerCase() && point.blockNumber === b[i]!.blockNumber);
  }
  return a.every((point, i) => Math.abs(point.timestamp - b[i]!.timestamp) <= toleranceSeconds);
}

/** Display-only truncation toward zero; negative returns retain their sign. */
export function formatFraction(value: Fraction, decimals = 8): string {
  requireValue(value.denominator > 0n && Number.isInteger(decimals) && decimals >= 0 && decimals <= 36, "INVALID_FORMAT");
  const magnitude = value.numerator < 0n ? -value.numerator : value.numerator;
  const scale = 10n ** BigInt(decimals), scaled = magnitude * scale / value.denominator;
  const sign = value.numerator < 0n ? "-" : "";
  return `${sign}${scaled / scale}${decimals === 0 ? "" : "." + (scaled % scale).toString().padStart(decimals, "0")}`;
}
