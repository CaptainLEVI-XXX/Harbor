import { render, screen } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { describe, expect, it, vi } from 'vitest';
import TestnetPage from '../page';

const balances = vi.hoisted(() => ({ data: null as null | { ETH: bigint; WETH: bigint; wstETH: bigint } }));
vi.mock('@/lib/wallet', () => ({ privyConfigured: true, useConnect: () => ({ label: 'Connect wallet', onConnect: vi.fn(), address: '0x1234567890abcdef1234567890abcdef12345678' }) }));
vi.mock('@/lib/wallet/useSend', () => ({ useSend: () => vi.fn() }));
vi.mock('@/lib/harbor/useResource', () => ({ useResource: () => ({ loading: false, data: balances.data, refresh: vi.fn() }) }));
vi.mock('@/lib/harbor/DisplayPriceProvider', () => ({ useDisplayPrice: () => ({ prices: { WETH: 2500n * 10n ** 18n, wstETH: 3000n * 10n ** 18n, fetchedAt: Date.now() }, usd: (wei: bigint) => `$${wei.toString()}` }) }));

const WAD = 10n ** 18n;
const deposit = () => screen.getByRole('button', { name: 'Deposit' });
const receipts = () => screen.getByRole('button', { name: 'Get receipts' });

describe('the testnet ladder', () => {
  it('opens each rung only once the rung above it has paid out', () => {
    balances.data = { ETH: 0n, WETH: 0n, wstETH: 0n };
    const { rerender } = render(<TestnetPage />);
    expect(deposit()).toBeDisabled();
    expect(receipts()).toBeDisabled();

    balances.data = { ETH: WAD, WETH: 0n, wstETH: 0n };
    rerender(<TestnetPage />);
    expect(deposit()).toBeEnabled();
    expect(receipts()).toBeDisabled();

    balances.data = { ETH: WAD, WETH: 0n, wstETH: WAD / 100n };
    rerender(<TestnetPage />);
    expect(receipts()).toBeEnabled();
  });

  it('shuts a rung the typed amount outgrows, and never on the amount alone', async () => {
    balances.data = { ETH: WAD / 100n, WETH: 0n, wstETH: 0n };
    render(<TestnetPage />);
    // 0.01 ETH of balance cannot both stake 0.01 and pay gas
    expect(deposit()).toBeDisabled();
    const input = screen.getByLabelText('ETH amount');
    await userEvent.clear(input); await userEvent.type(input, '0.001');
    expect(deposit()).toBeEnabled();
    await userEvent.clear(input);
    expect(deposit()).toBeDisabled();
  });

  it('carries a one-liner per rung instead of prose, and no heading', () => {
    balances.data = { ETH: WAD, WETH: 0n, wstETH: WAD };
    const { container } = render(<TestnetPage />);
    expect(container.querySelector('h1')).toBeNull();
    expect(container.querySelectorAll('.steps li')).toHaveLength(3);
    // the one-liner is the dot's accessible name, so it needs no hover to read
    expect(screen.getByRole('button', { name: /public faucet/ })).toBeInTheDocument();
    expect(screen.getByRole('button', { name: /Stakes your ETH with Lido/ })).toBeInTheDocument();
    expect(screen.getByRole('button', { name: /instant liquidity/ })).toBeInTheDocument();
    expect(screen.getByRole('link', { name: /Faucet/ })).toHaveAttribute('href', 'https://hoodi-faucet.pk910.de/');
  });

  it('shows what each amount is worth', () => {
    balances.data = { ETH: WAD, WETH: 0n, wstETH: WAD };
    render(<TestnetPage />);
    expect(screen.getByLabelText('ETH amount')).toHaveValue('0.01');
    expect(screen.getByLabelText('wstETH amount')).toHaveValue('0.005');
    expect(screen.getByText(`$${WAD / 100n}`)).toBeInTheDocument();
  });

  it('opens a rung on the holding alone when the balance could not be read', () => {
    // a failed balance read must not lock a wallet out of a step it can do
    balances.data = null;
    render(<TestnetPage />);
    expect(deposit()).toBeEnabled();
    expect(receipts()).toBeEnabled();
  });

  it('switches an amount between its token and dollars', async () => {
    balances.data = { ETH: WAD, WETH: 0n, wstETH: WAD };
    render(<TestnetPage />);
    const input = screen.getByLabelText('ETH amount');
    await userEvent.clear(input); await userEvent.type(input, '0.02');
    await userEvent.click(screen.getAllByRole('button', { name: 'Enter amount in dollars' })[0]);
    expect(input).toHaveValue('50');                       // at $2500/ETH
    await userEvent.click(screen.getByRole('button', { name: 'Enter amount in ETH' }));
    expect(input).toHaveValue('0.02');
  });

  it('never shows more decimals than it will spend', async () => {
    balances.data = { ETH: WAD, WETH: 0n, wstETH: WAD };
    render(<TestnetPage />);
    const input = screen.getByLabelText('ETH amount');
    await userEvent.click(screen.getAllByRole('button', { name: 'Enter amount in dollars' })[0]);
    await userEvent.clear(input); await userEvent.type(input, '49.99');
    await userEvent.click(screen.getByRole('button', { name: 'Enter amount in ETH' }));
    // 49.99 / 2500 is 0.019996 exactly; a flip must not strand hidden wei
    expect(input).toHaveValue('0.019996');
    expect((input as HTMLInputElement).value.split('.')[1].length).toBeLessThanOrEqual(6);
  });

  it('names the unit beside the figure rather than only underneath it', () => {
    balances.data = { ETH: WAD, WETH: 0n, wstETH: WAD };
    const { container } = render(<TestnetPage />);
    expect([...container.querySelectorAll('.tamt .unit')].map(e => e.textContent)).toEqual(['ETH', 'wstETH']);
    expect(container.querySelector('.tamt .cur')).toBeNull();   // token unit shows no $
  });
});
