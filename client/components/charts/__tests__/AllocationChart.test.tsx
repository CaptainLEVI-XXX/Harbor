import { render, screen } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { describe, it, expect, vi } from 'vitest';
import AllocationChart from '../AllocationChart';
import type { AllocationPoint } from '@/lib/earn/derive';
import type { Strategy } from '@/lib/earn/types';

const WEI = 10n ** 18n;
const DAY = 86_400_000;

const strategies = [
  { id: 'a', issuer: 'Lido', asset: 'wstETH', colour: '#4A2F6B' },
  { id: 'b', issuer: 'Cash', asset: 'unallocated WETH', colour: '#DFD3F2' },
] as Strategy[];

const points: AllocationPoint[] = Array.from({ length: 40 }, (_, i) => ({
  at: Date.UTC(2026, 7, 2) + i * DAY,
  totalWei: 100n * WEI,
  bands: [60n * WEI, 40n * WEI],
}));

describe('AllocationChart', () => {
  it('draws one band per strategy, in strategy order', () => {
    const { container } = render(
      <AllocationChart points={points} strategies={strategies} focus={null} onFocus={() => {}} />,
    );
    const bands = [...container.querySelectorAll('path[data-band]')];
    expect(bands.map(b => b.getAttribute('data-band'))).toEqual(['a', 'b']);
  });

  it('dims the bands that are not focused', () => {
    const { container } = render(
      <AllocationChart points={points} strategies={strategies} focus="b" onFocus={() => {}} />,
    );
    const [a, b] = [...container.querySelectorAll('path[data-band]')];
    expect(Number(b.getAttribute('opacity'))).toBeGreaterThan(Number(a.getAttribute('opacity')));
  });

  it('reports a focus change when a band is hovered', async () => {
    const onFocus = vi.fn();
    const { container } = render(
      <AllocationChart points={points} strategies={strategies} focus={null} onFocus={onFocus} />,
    );
    await userEvent.hover(container.querySelector('path[data-band]')!);
    expect(onFocus).toHaveBeenCalledWith('a');
  });

  it('collapses to a single area in total mode', async () => {
    const { container } = render(
      <AllocationChart points={points} strategies={strategies} focus={null} onFocus={() => {}} />,
    );
    await userEvent.click(screen.getByRole('button', { name: 'Total' }));
    expect(container.querySelectorAll('path[data-band]')).toHaveLength(0);
    expect(container.querySelector('path[data-total]')).toBeTruthy();
  });

  it('names the chart at rest rather than repeating the hero total', async () => {
    const { container } = render(
      <AllocationChart points={points} strategies={strategies} focus={null} onFocus={() => {}} />,
    );
    expect(container.querySelector('.when')!.textContent).toBe('Split across strategies');
    // 40 points in the fixture, but the default range shows the last 30
    expect(container.querySelector('.now')!.textContent).toContain('12 Aug – 10 Sep');
    // the hero already carries this figure as "Total value"
    expect(container.querySelector('.chead')!.textContent).not.toContain('100.000');

    await userEvent.click(screen.getByRole('button', { name: 'Total' }));
    expect(container.querySelector('.when')!.textContent).toBe('Total value');
  });
});
