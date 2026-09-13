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

/**
 * Same as formatWei but pads to a fixed number of fraction digits, so a column
 * of figures lines up on the decimal point. Tabular figures only pay off when
 * every row has the same shape - 4.12 above 1.8 defeats them.
 */
export function formatWeiFixed(value: bigint, decimals: number, fractionDigits: number): string {
  if (decimals === 0) return value.toString();

  const base = 10n ** BigInt(decimals);
  const negative = value < 0n;
  const abs = negative ? -value : value;

  const whole = abs / base;
  const fraction = (abs % base).toString().padStart(decimals, '0').slice(0, fractionDigits);

  const sign = negative ? '-' : '';
  return fractionDigits > 0 ? `${sign}${whole}.${fraction.padEnd(fractionDigits, '0')}` : `${sign}${whole}`;
}

/**
 * A signed result, for the one column that carries a gain/loss colour.
 *
 * The minus is U+2212 MINUS SIGN, not a hyphen: in tabular figures a hyphen
 * is narrower than a digit and pulls the column out of alignment. Zero is
 * unsigned - "+0.00" reads as a gain that is not there.
 */
export function formatSigned(value: bigint, decimals: number, fractionDigits: number): string {
  if (value === 0n) return formatWeiFixed(0n, decimals, fractionDigits);
  const body = formatWeiFixed(value < 0n ? -value : value, decimals, fractionDigits);
  return `${value < 0n ? '−' : '+'}${body}`;
}

/**
 * Thousands separators on the whole part, fraction untouched.
 *
 * Applied at the render edge like every other formatter here - a grouped
 * string is for reading, never for parsing back.
 */
export function group(value: string): string {
  const [whole, fraction] = value.split('.');
  const sign = whole.startsWith('−') || whole.startsWith('-') ? whole[0] : '';
  const digits = sign ? whole.slice(1) : whole;
  const separated = digits.replace(/\B(?=(\d{3})+(?!\d))/g, ',');
  return fraction ? `${sign}${separated}.${fraction}` : `${sign}${separated}`;
}

/** The state class a signed figure wears: `gain`, `loss`, or nothing at zero. */
export function tone(value: bigint | number): 'gain' | 'loss' | '' {
  return value > 0 ? 'gain' : value < 0 ? 'loss' : '';
}
