import { render, screen } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { describe, it, expect } from 'vitest';
import YieldChart from '../YieldChart';
import type { YieldPoint } from '@/lib/earn/derive';

const DAY = 86_400_000;
const points: YieldPoint[] = Array.from({ length: 60 }, (_, i) => ({
  at: Date.UTC(2026, 6, 13) + i * DAY,
  dailyPct: 3 + (i % 5),
  trailingPct: 4 + i / 100,
}));

describe('YieldChart', () => {
  it('heads the card with the latest trailing figure, not a blank', () => {
    const { container } = render(<YieldChart points={points} />);
    // the figure and its qualifier share one node, so match on the node
    expect(container.querySelector('.now')!.textContent).toContain('4.59%');
    expect(screen.getByText('10 Sep 2026')).toBeInTheDocument();
  });

  it('draws one bar per day in the chosen range', () => {
    const { container } = render(<YieldChart points={points} />);
    expect(container.querySelectorAll('rect[data-bar]')).toHaveLength(30);
  });

  it('changes the range without losing the header', async () => {
    const { container } = render(<YieldChart points={points} />);
    await userEvent.click(screen.getByRole('button', { name: '1W' }));
    expect(container.querySelectorAll('rect[data-bar]')).toHaveLength(7);
    expect(container.querySelector('.now')!.textContent).toContain('4.59%');
  });

  it('marks the chosen range as pressed, and only that one', () => {
    render(<YieldChart points={points} />);
    const pressed = screen.getAllByRole('button').filter(b => b.getAttribute('aria-pressed') === 'true');
    expect(pressed.map(b => b.textContent)).toEqual(['1M']);
  });

  it('rounds bar corners at the lattice ratio', () => {
    const { container } = render(<YieldChart points={points} />);
    const bar = container.querySelector('rect[data-bar]')!;
    const width = Number(bar.getAttribute('width'));
    expect(Number(bar.getAttribute('rx'))).toBeCloseTo((width * 25) / 84, 5);
  });
});
