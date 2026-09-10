/**
 * Wei formatting, done with strings and bigint only.
 *
 * Never route these through Number: WETH is 1e18 and a double carries 53 bits
 * of mantissa, so float arithmetic produces wrong values that look plausible.
 */
export function formatWei(value: bigint, decimals: number, maxFractionDigits = 6): string {
  if (decimals === 0) return value.toString();

  const base = 10n ** BigInt(decimals);
  const negative = value < 0n;
  const abs = negative ? -value : value;

  const whole = abs / base;
  const fraction = (abs % base).toString().padStart(decimals, '0');
  const trimmed = fraction.slice(0, maxFractionDigits).replace(/0+$/, '');

  const sign = negative ? '-' : '';
  return trimmed ? `${sign}${whole}.${trimmed}` : `${sign}${whole}`;
}

/** Returns null for anything that is not a plain decimal figure. */
export function parseWei(input: string, decimals: number): bigint | null {
  const text = input.trim();
  if (text === '' || text === '.' || !/^\d*\.?\d*$/.test(text)) return null;

  const [whole = '0', fraction = ''] = text.split('.');
  // truncate rather than round: never quote more than the user asked for
  const padded = (fraction + '0'.repeat(decimals)).slice(0, decimals);

  return BigInt(whole || '0') * 10n ** BigInt(decimals) + BigInt(padded || '0');
}
