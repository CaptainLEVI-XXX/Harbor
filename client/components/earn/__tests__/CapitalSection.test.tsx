import { render, screen } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { describe, it, expect } from 'vitest';
import CapitalSection from '../CapitalSection';
import { CHECKPOINTS, STRATEGIES } from '@/lib/earn/fixtures';
import { allocationSeries } from '@/lib/earn/derive';

const points = allocationSeries(CHECKPOINTS, STRATEGIES);

describe('CapitalSection', () => {
  it('puts the chart and its legend in one card', () => {
    const { container } = render(<CapitalSection points={points} strategies={STRATEGIES} />);
    expect(container.querySelectorAll('.modal')).toHaveLength(1);
    expect(container.querySelector('svg')).toBeTruthy();
    expect(container.querySelectorAll('.srow')).toHaveLength(STRATEGIES.length);
  });

  it('lights the matching band when a row is hovered', async () => {
    const { container } = render(<CapitalSection points={points} strategies={STRATEGIES} />);
    const band = (id: string) => container.querySelector(`path[data-band="${id}"]`)!;
    const before = Number(band('ethena').getAttribute('opacity'));

    await userEvent.hover(container.querySelector('[data-row="ethena"]')!);
    expect(Number(band('ethena').getAttribute('opacity'))).toBeGreaterThan(before);
    expect(Number(band('lido').getAttribute('opacity'))).toBeLessThan(before);
  });

  it('says once that yield is not split per strategy', () => {
    render(<CapitalSection points={points} strategies={STRATEGIES} />);
    expect(screen.getByText(/not split per strategy/i)).toBeInTheDocument();
  });
});
