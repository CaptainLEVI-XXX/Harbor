import type { Unit } from '@/lib/price';

type Props = {
  unit: Unit;
  /** the same amount in the unit NOT being typed, already formatted */
  other: string;
  symbol: string;
  onFlip: () => void;
  available?: boolean;
};

/**
 * The line under an amount field: the figure in the other unit, and the way
 * to start typing in it. One control for both jobs - the counterpart IS the
 * thing you would switch to.
 */
export default function AmountFlip({ unit, other, symbol, onFlip, available = false }: Props) {
  return (
    <button
      type="button"
      className="flip"
      aria-label={unit === 'usd' ? `Enter amount in ${symbol}` : 'Enter amount in dollars'}
      onClick={onFlip}
      disabled={!available && unit !== 'usd'}
      title={!available ? 'USD conversion needs a fresh reference price' : 'Mainnet USD reference · Hoodi tokens have no monetary value'}
    >
      {other}
    </button>
  );
}
