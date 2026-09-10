import { render, screen } from '@testing-library/react';
import { describe, it, expect } from 'vitest';
import VaultHero from '../VaultHero';
import PositionCard from '../PositionCard';
import ExitAndAbout from '../ExitAndAbout';
import ActivityList from '../ActivityList';
import { EXIT_LIQUIDITY, FILLS, POSITION, CHECKPOINTS } from '@/lib/earn/fixtures';
import { yieldSeries } from '@/lib/earn/derive';

const points = yieldSeries(CHECKPOINTS);
const last = CHECKPOINTS[CHECKPOINTS.length - 1];

describe('VaultHero', () => {
  it('leads with the yield and names the vault', () => {
    render(
      <VaultHero
        apyPct={4.12}
        deltaPct={0.34}
        navWei={last.navWei}
        volume30dWei={85_890n * 10n ** 18n}
        priceWad={1_041_200_000_000_000_000n}
        points={points}
      />,
    );
    expect(screen.getByRole('heading', { name: 'Harbor WETH' })).toBeInTheDocument();
    expect(screen.getByText('4.12%')).toBeInTheDocument();
    expect(screen.getByText('30-day APY')).toBeInTheDocument();
    expect(screen.getByText('3,279.579')).toBeInTheDocument();
  });

  it('colours the month-on-month delta as a signed result', () => {
    const { container } = render(
      <VaultHero
        apyPct={4.12}
        deltaPct={-0.34}
        navWei={last.navWei}
        volume30dWei={0n}
        priceWad={10n ** 18n}
        points={points}
      />,
    );
    expect(container.querySelector('.delta')!.className).toContain('loss');
    expect(container.querySelector('.delta')!.textContent).toContain('−');
  });
});

describe('PositionCard', () => {
  it('shows value, balance and earnings, with earnings coloured', () => {
    const { container } = render(<PositionCard position={POSITION} />);
    // the value and its unit share one node
    expect(container.querySelector('.big')!.textContent).toContain('12.4903');
    expect(screen.getByText(/11\.9960 hWETH/)).toBeInTheDocument();
    expect(container.querySelector('.gain')!.textContent).toBe('+0.4903');
  });
});

describe('ExitAndAbout', () => {
  it('states the exit liquidity in plain figures', () => {
    render(<ExitAndAbout liquidity={EXIT_LIQUIDITY} />);
    expect(screen.getByText('Ready to pay now')).toBeInTheDocument();
    expect(screen.getByText('842.40 WETH')).toBeInTheDocument();
    expect(screen.getByText('~4h')).toBeInTheDocument();
  });

  it('explains the yield without naming a contract', () => {
    const { container } = render(<ExitAndAbout liquidity={EXIT_LIQUIDITY} />);
    expect(screen.getByText(/The gap is the yield/)).toBeInTheDocument();
    expect(container.textContent).not.toMatch(/NAV|adapter|route|checkpoint/i);
  });
});

describe('ActivityList', () => {
  it('names the issuer rather than a ticker', () => {
    render(<ActivityList fills={FILLS} />);
    expect(screen.getAllByText('Lido').length).toBeGreaterThan(0);
    expect(screen.getAllByText('Ethena').length).toBeGreaterThan(0);
    // a ticker would be wrong here - the row is evidence for a strategy above
    expect(screen.queryByText('wstETH')).toBeNull();
  });

  it('renders one row per fill', () => {
    const { container } = render(<ActivityList fills={FILLS} />);
    expect(container.querySelectorAll('.act-row')).toHaveLength(FILLS.length);
  });
});
