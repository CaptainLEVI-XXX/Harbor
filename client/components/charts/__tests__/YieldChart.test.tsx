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
  it('names the chart and the window it covers, rather than repeating the headline', () => {
    const { container } = render(<YieldChart points={points} />);
    expect(container.querySelector('.when')!.textContent).toBe('Daily yield');
    expect(container.querySelector('.now')!.textContent).toContain('12 Aug – 10 Sep');
    // the trailing average is already the page's headline; a second copy of it
    // here read as a competing headline of the same number
    expect(container.querySelector('.chead')!.textContent).not.toContain('4.59');
  });

  it('draws one bar per day in the chosen range', () => {
    const { container } = render(<YieldChart points={points} />);
    expect(container.querySelectorAll('rect[data-bar]')).toHaveLength(30);
  });

  it('changes the range without losing the header', async () => {
    const { container } = render(<YieldChart points={points} />);
    await userEvent.click(screen.getByRole('button', { name: '1W' }));
    expect(container.querySelectorAll('rect[data-bar]')).toHaveLength(7);
    expect(container.querySelector('.now')!.textContent).toContain('04 Sep – 10 Sep');
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
