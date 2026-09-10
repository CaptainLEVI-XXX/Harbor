import { render, screen } from '@testing-library/react';
import { describe, it, expect } from 'vitest';
import QuotePanel from '../QuotePanel';
import type { Quote } from '@/lib/swap/types';

const firm: Quote = {
  state: 'firm',
  payWei: 10n ** 18n,
  receiveWei: 1182876000000000000n,
  feeWei: 1184060000000000n,
  rate: '1 wstETH = 1.18406 WETH',
  expiresAt: 1_030_000,
};
const rows = [{ label: 'Rate', value: '1 wstETH = 1.18406 WETH' }];

describe('QuotePanel', () => {
  it('renders nothing when idle', () => {
    const { container } = render(<QuotePanel quote={{ ...firm, state: 'idle' }} rows={rows} now={1_000_000} />);
    expect(container.firstChild).toBeNull();
  });

  it('shows a countdown that a caller can move', () => {
    const { rerender } = render(<QuotePanel quote={firm} rows={rows} now={1_000_000} />);
    expect(screen.getByText('expires in 0:30')).toBeInTheDocument();
    rerender(<QuotePanel quote={firm} rows={rows} now={1_018_000} />);
    expect(screen.getByText('expires in 0:12')).toBeInTheDocument();
  });

  it('says expired rather than showing a countdown', () => {
    render(<QuotePanel quote={{ ...firm, state: 'expired' }} rows={rows} now={1_099_000} />);
    expect(screen.getByText('expired')).toBeInTheDocument();
  });

  it('states the reason when unavailable and shows no figures', () => {
    render(
      <QuotePanel
        quote={{ ...firm, state: 'unavailable', reason: 'That does not affect recovery.' }}
        rows={rows}
        now={1_000_000}
      />,
    );
    expect(screen.getByText(/does not affect recovery/)).toBeInTheDocument();
    expect(screen.queryByText('Rate')).toBeNull();
  });

  it('names the book limit when the trade will not fill', () => {
    render(
      <QuotePanel
        quote={{ ...firm, state: 'wontfill', limitWei: 8400000000000000000n }}
        rows={rows}
        now={1_000_000}
      />,
    );
    expect(screen.getByText(/8\.4 wstETH/)).toBeInTheDocument();
  });

  it('withholds figures while the quote is still being requested', () => {
    render(<QuotePanel quote={{ ...firm, state: 'requesting' }} rows={rows} now={1_000_000} />);
    expect(screen.getByText('Requesting quote')).toBeInTheDocument();
    expect(screen.queryByText('1 wstETH = 1.18406 WETH')).toBeNull();
  });

  it('accents one row, so the single accent lands on the value that moves', () => {
    const { container } = render(
      <QuotePanel quote={firm} rows={[{ label: 'You receive', value: '3.9375 WETH', accent: true }]} now={1_000_000} />,
    );
    expect(container.querySelector('.big')).toHaveTextContent('3.9375 WETH');
  });
});
