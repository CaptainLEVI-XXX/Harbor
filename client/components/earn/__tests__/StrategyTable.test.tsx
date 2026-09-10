import { render, screen } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { describe, it, expect, vi } from 'vitest';
import StrategyTable from '../StrategyTable';
import type { Strategy } from '@/lib/earn/types';

const WEI = 10n ** 18n;

const strategies: Strategy[] = [
  { id: 'lido', issuer: 'Lido', asset: 'wstETH', colour: '#4A2F6B', holding: '1,168.92 wstETH',
    volume30dWei: 59_350n * WEI, earnedWei: 18_400_000_000_000_000_000n, inQueueWei: 124n * WEI },
  { id: 'cbeth', issuer: 'Coinbase', asset: 'cbETH', colour: '#C9B6E6', holding: '84.59 cbETH',
    volume30dWei: 840n * WEI, earnedWei: -300_000_000_000_000_000n, inQueueWei: 0n },
  { id: 'cash', issuer: 'Cash', asset: 'unallocated WETH', colour: '#DFD3F2', holding: '842.40 WETH',
    volume30dWei: null, earnedWei: null, inQueueWei: 0n },
];

const rows = [
  { id: 'lido', valueWei: 1384n * WEI, pct: 42.2 },
  { id: 'cbeth', valueWei: 92n * WEI, pct: 2.8 },
  { id: 'cash', valueWei: 842n * WEI, pct: 25.7 },
];

function table(focus: string | null = null, onFocus = () => {}) {
  return render(<StrategyTable strategies={strategies} rows={rows} focus={focus} onFocus={onFocus} />);
}

describe('StrategyTable', () => {
  it('names the issuer, because the adapter is the strategy', () => {
    table();
    expect(screen.getByText(/Lido/)).toBeInTheDocument();
    expect(screen.queryByText(/Rocket Pool/)).toBeNull();
    expect(screen.getByText(/· wstETH/)).toBeInTheDocument();
  });

  it('colours a gain and a loss differently, and nothing else', () => {
    const { container } = table();
    expect(container.querySelectorAll('.gain').length).toBeGreaterThan(0);
    expect(container.querySelectorAll('.loss')).toHaveLength(1);
    expect(container.querySelector('.loss')!.textContent).toBe('−0.3');
  });

  it('uses a real minus sign, not a hyphen', () => {
    const { container } = table();
    expect(container.textContent).not.toMatch(/-\d/);
  });

  it('leaves a row with no result uncoloured', () => {
    const { container } = table();
    const cash = container.querySelector('[data-row="cash"]')!;
    expect(cash.querySelector('.gain')).toBeNull();
    expect(cash.querySelector('.loss')).toBeNull();
  });

  it('reports a focus change when a row is hovered', async () => {
    const onFocus = vi.fn();
    const { container } = table(null, onFocus);
    await userEvent.hover(container.querySelector('[data-row="cbeth"]')!);
    expect(onFocus).toHaveBeenCalledWith('cbeth');
  });

  it('totals the columns that can be totalled', () => {
    table();
    expect(screen.getByText('Across all strategies')).toBeInTheDocument();
    expect(screen.getByText('+18.1')).toBeInTheDocument();
  });

  it('has no APY column, because yield is not attributable per strategy', () => {
    const { container } = table();
    expect(container.textContent).not.toMatch(/apy/i);
  });
});
