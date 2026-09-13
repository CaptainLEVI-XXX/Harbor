import { render, screen } from '@testing-library/react';
import { describe, expect, it, vi } from 'vitest';
import EarnPage from '../page';
vi.mock('@/lib/wallet', () => ({ useSigner: () => null, truncateAddress: (a: string) => a, useConnect: () => ({ connected: false, label: 'Connect wallet', onConnect: vi.fn() }) }));
vi.mock('@/lib/wallet/useSend', () => ({ useSend: () => vi.fn() }));
vi.mock('@/lib/harbor/useResource', () => ({ useResource: () => ({ loading: false, error: 'Provider unavailable', refresh: vi.fn() }) }));
describe('earn availability', () => {
  it('keeps unavailable analytics distinct from zero yield or a fixture portfolio', () => {
    const { container } = render(<EarnPage />);
    expect(screen.getByText('harbor WETH')).toBeInTheDocument();
    expect(screen.getByText('Insufficient history')).toBeInTheDocument();
    expect(container.querySelector('.hero-apy b')).toHaveTextContent('—');
    // no history, so no charts and no fixtures standing in for them
    expect(container.querySelectorAll('svg[role="img"]')).toHaveLength(0);
    expect(screen.queryByText(/SAMPLE DATA/)).toBeNull();
    expect(screen.queryByText('Your position')).toBeNull();
    expect(screen.getByRole('button', { name: 'Connect wallet' })).toBeEnabled();
  });
});
