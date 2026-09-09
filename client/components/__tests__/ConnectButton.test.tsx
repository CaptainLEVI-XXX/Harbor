import { render, screen } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { describe, it, expect, vi, beforeEach } from 'vitest';
import Nav from '../Nav';

const login = vi.fn();
const logout = vi.fn();
let mockState = { ready: true, authenticated: false, user: null as { wallet?: { address: string } } | null };

vi.mock('@privy-io/react-auth', () => ({
  usePrivy: () => ({ ...mockState, login, logout }),
  // PrivyProvider is imported by the module under test, so the mock must supply it too
  PrivyProvider: ({ children }: { children: React.ReactNode }) => <>{children}</>,
}));

// force the configured code path regardless of the local .env
vi.stubEnv('NEXT_PUBLIC_PRIVY_APP_ID', 'test-app-id');

const { useConnect, truncateAddress } = await import('../PrivyProvider');

function Harness() {
  const { label, onConnect } = useConnect();
  return <Nav onConnect={onConnect} connectLabel={label} />;
}

describe('truncateAddress', () => {
  it('keeps the first six and last four characters', () => {
    expect(truncateAddress('0x1234567890abcdef1234567890abcdef12345678')).toBe('0x1234…5678');
  });
});

describe('connect button', () => {
  beforeEach(() => {
    login.mockClear();
    mockState = { ready: true, authenticated: false, user: null };
  });

  it('reads "Connect wallet" when signed out and calls login', async () => {
    render(<Harness />);
    const btn = screen.getByRole('button', { name: 'Connect wallet' });
    await userEvent.click(btn);
    expect(login).toHaveBeenCalledOnce();
  });

  it('shows a truncated address once connected', () => {
    mockState = {
      ready: true,
      authenticated: true,
      user: { wallet: { address: '0x1234567890abcdef1234567890abcdef12345678' } },
    };
    render(<Harness />);
    expect(screen.getByRole('button', { name: '0x1234…5678' })).toBeInTheDocument();
  });
});
