import { render, screen } from '@testing-library/react';
import { describe, it, expect } from 'vitest';
import EarnPage from '../page';

describe('/earn', () => {
  it('answers the four questions a depositor arrives with, in order', () => {
    const { container } = render(<EarnPage />);
    const headings = [...container.querySelectorAll('h1, h2')].map(h => h.textContent);
    expect(headings).toEqual([
      'Harbor WETH',
      'Where the capital works',
      'Getting out',
      'How Harbor earns',
      'Recent activity',
    ]);
  });

  it('puts every chart inside a well', () => {
    const { container } = render(<EarnPage />);
    const charts = [...container.querySelectorAll('svg[role="img"]')];
    expect(charts.length).toBe(2);
    for (const chart of charts) {
      expect(chart.parentElement!.className).toContain('well');
    }
  });

  it('uses Exit Violet only where value moves', () => {
    const { container } = render(<EarnPage />);
    // the headline APY and the panel's receive figure; the chart's accent is an
    // SVG stroke, not a class
    expect(container.querySelectorAll('.hero-apy b, .qrow .big')).toHaveLength(2);
  });

  it('shows no position card until a wallet is connected', () => {
    render(<EarnPage />);
    expect(screen.queryByText('Your position')).toBeNull();
  });

  it('never mentions the mechanism behind a closed door', () => {
    const { container } = render(<EarnPage />);
    expect(container.textContent).not.toMatch(/stale|valuation mark|deposit cap|insolvent/i);
  });
});
