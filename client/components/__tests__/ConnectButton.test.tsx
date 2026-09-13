import { render, screen } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { describe, it, expect, vi, beforeEach } from 'vitest';

const ADDRESS = '0x1234567890abcdef1234567890abcdef12345678';
const login = vi.fn();
const logout = vi.fn();
const fundWallet = vi.fn(() => Promise.resolve());
let mockState = { ready: true, authenticated: false, user: null as { wallet?: { address: string } } | null };
let walletType = 'privy';

vi.mock('@privy-io/react-auth', () => ({
  usePrivy: () => ({ ...mockState, login, logout }),
  useWallets: () => ({ wallets: mockState.user?.wallet ? [{ address: ADDRESS, walletClientType: walletType, meta: { name: 'MetaMask' } }] : [] }),
  useFundWallet: () => ({ fundWallet }),
  useSendTransaction: () => ({ sendTransaction: vi.fn() }),
  // PrivyProvider is imported by the module under test, so the mock must supply it too
  PrivyProvider: ({ children }: { children: React.ReactNode }) => <>{children}</>,
}));
vi.mock('@/lib/harbor/useResource', () => ({ useResource: () => ({ data: 465_246_000_000_000_000n, loading: false, refresh: vi.fn() }) }));

// force the configured code path regardless of the local .env
vi.stubEnv('NEXT_PUBLIC_PRIVY_APP_ID', 'test-app-id');

// imported after the stub: Nav reaches the wallet config through the button it renders
const { useConnect, truncateAddress } = await import('@/lib/wallet/PrivyProvider');
const { default: Nav } = await import('../Nav');

function Harness() {
  const { label, onConnect } = useConnect();
  return <Nav onConnect={onConnect} connectLabel={label} />;
}

const signIn = (type = 'privy') => {
  walletType = type;
  mockState = { ready: true, authenticated: true, user: { wallet: { address: ADDRESS } } };
};

describe('truncateAddress', () => {
  it('keeps the first six and last four characters', () => {
    expect(truncateAddress(ADDRESS)).toBe('0x1234…5678');
  });
});

describe('connect button', () => {
  beforeEach(() => {
    login.mockClear(); logout.mockClear(); fundWallet.mockClear();
    mockState = { ready: true, authenticated: false, user: null };
  });

  it('reads "Connect wallet" when signed out and calls login', async () => {
    render(<Harness />);
    await userEvent.click(screen.getByRole('button', { name: 'Connect wallet' }));
    expect(login).toHaveBeenCalledOnce();
  });

  it('shows only the truncated address once connected, and the balance inside the menu', async () => {
    signIn();
    render(<Harness />);
    const button = screen.getByRole('button', { name: '0x1234…5678, wallet menu' });
    expect(button).toHaveTextContent(/^0x1234…5678$/);
    await userEvent.click(button);
    expect(screen.getByRole('dialog', { name: 'Wallet' })).toHaveTextContent('0.465246');
  });

  it('opens the wallet menu instead of signing out, and signs out only from Disconnect', async () => {
    signIn();
    render(<Harness />);
    await userEvent.click(screen.getByRole('button', { name: /0x1234…5678/ }));
    expect(logout).not.toHaveBeenCalled();
    expect(screen.getByRole('dialog', { name: 'Wallet' })).toHaveTextContent('Privy embedded wallet');
    await userEvent.click(screen.getByRole('button', { name: 'Disconnect' }));
    expect(logout).toHaveBeenCalledOnce();
  });

  it('copies the full address', async () => {
    signIn();
    const user = userEvent.setup();
    render(<Harness />);
    await user.click(screen.getByRole('button', { name: /0x1234…5678/ }));
    await user.click(screen.getByRole('button', { name: 'Copy address' }));
    expect(await navigator.clipboard.readText()).toBe(ADDRESS);
    expect(screen.getByRole('button', { name: 'Address copied' })).toBeInTheDocument();
  });

  it('offers deposit and withdraw for the embedded wallet only', async () => {
    signIn('metamask');
    const { unmount } = render(<Harness />);
    await userEvent.click(screen.getByRole('button', { name: /0x1234…5678/ }));
    expect(screen.getByRole('dialog')).toHaveTextContent('MetaMask');
    expect(screen.queryByRole('button', { name: 'Deposit' })).toBeNull();
    unmount();

    signIn('privy');
    render(<Harness />);
    await userEvent.click(screen.getByRole('button', { name: /0x1234…5678/ }));
    await userEvent.click(screen.getByRole('button', { name: 'Deposit' }));
    expect(screen.getByRole('img', { name: 'QR code of your wallet address' })).toBeInTheDocument();
    await userEvent.click(screen.getByRole('button', { name: 'Transfer from another wallet' }));
    expect(fundWallet).toHaveBeenCalledWith(expect.objectContaining({ address: ADDRESS, options: expect.objectContaining({ defaultFundingMethod: 'wallet' }) }));
  });

  it('will not send to itself or to a malformed address', async () => {
    signIn();
    render(<Harness />);
    await userEvent.click(screen.getByRole('button', { name: /0x1234…5678/ }));
    await userEvent.click(screen.getByRole('button', { name: 'Withdraw' }));
    const [to] = screen.getAllByRole('textbox');
    await userEvent.type(to, '0x12');
    expect(screen.getByRole('alert')).toHaveTextContent('Not a valid address');
    await userEvent.clear(to);
    await userEvent.type(to, ADDRESS);
    expect(screen.getByRole('alert')).toHaveTextContent('That is this wallet');
    expect(document.querySelector('button.wsend')).toBeDisabled();
  });
});
