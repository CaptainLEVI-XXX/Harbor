import { beforeEach, describe, expect, it, vi } from 'vitest';
import { AUTO_SLIPPAGE_BPS, readQuote, slippageLimit } from '@/lib/harbor/quote';
import { ASSETS } from '@/lib/harbor/config';
import { TOKENS } from '@/lib/chain';
import { formatWei } from '@/lib/format';
import { weiToTyped } from '@/lib/price';
import { USER } from '@/lib/harbor/__tests__/fixtures';

const rpc = vi.hoisted(() => ({ getChainId: vi.fn(), getBlock: vi.fn(), readContract: vi.fn() }));
vi.mock('@/lib/chain', async actual => ({ ...await actual<typeof import('@/lib/chain')>(), publicClient: rpc }));
beforeEach(() => {
  vi.clearAllMocks();
  rpc.getChainId.mockResolvedValue(560048);
  rpc.getBlock.mockResolvedValue({ number: 42n, timestamp: 1000n, hash: '0x11' });
  rpc.readContract.mockImplementation(async ({ functionName }) => {
    if (functionName === 'pricingParameters') return { version: 1n, configVersion: 2n, validUntil: 9999n };
    if (functionName === 'configVersion') return 2n;
    if (functionName === 'strategyVersion') return 3n;
    if (functionName === 'stopped') return false;
    if (functionName === 'quoteSwap') return [1000n, 2000n, '0x22'];
    if (functionName === 'quote') return { traderIn: 1000n, traderOut: 2000n, fee: 7n };
    throw new Error(functionName);
  });
});
describe('canonical VM quoting', () => {
  it.each(['sell', 'buy'] as const)('encodes both exactness modes for trader %s', async direction => {
    for (const mode of ['exactInput', 'exactOutput'] as const) {
      const q = await readQuote({ amountWei: mode === 'exactInput' ? 1000n : 2000n, direction, mode, user: USER });
      expect(q.trade.side).toBe(direction === 'sell' ? 0 : 1);
      expect(q.trade.mode).toBe(mode === 'exactInput' ? 0 : 1);
      expect(q.trade.tokenIn).toBe(direction === 'sell' ? TOKENS.wstETH : TOKENS.WETH);
      // the one tolerance every quote carries: 2.50%
      expect(q.trade.limitAmount).toBe(mode === 'exactInput' ? 1950n : 1025n);
      expect(q.feeWei).toBe(7n); // fee is already included; do not subtract twice
      expect(rpc.readContract.mock.calls.every(([p]) => p.blockNumber === 42n)).toBe(true);
    }
  });
  it('sends the contract WETH on the cash leg however the interface labels it', async () => {
    // The interface says ETH and wraps/unwraps around the trade; the book only
    // ever sees WETH, so a relabel must never reach the trade struct.
    expect(ASSETS.ETH.address).toBe(TOKENS.WETH);
    const sell = await readQuote({ amountWei: 1000n, mode: 'exactInput', direction: 'sell', user: USER });
    expect(sell.trade.tokenOut).toBe(TOKENS.WETH);
    const buy = await readQuote({ amountWei: 1000n, mode: 'exactInput', direction: 'buy', user: USER });
    expect(buy.trade.tokenIn).toBe(TOKENS.WETH);
    expect(buy.trade.tokenOut).toBe(TOKENS.wstETH);
  });
  it('rejects provider chain mismatch before reading pricing', async () => {
    rpc.getChainId.mockResolvedValue(1);
    await expect(readQuote({ amountWei: 1n, mode: 'exactInput', direction: 'sell' })).rejects.toThrow('Hoodi');
    expect(rpc.readContract).not.toHaveBeenCalled();
  });
  it('does not substitute a fixture when the VM rejects a quote', async () => {
    rpc.readContract.mockRejectedValue(new Error('No liquidity'));
    await expect(readQuote({ amountWei: 1n, mode: 'exactInput', direction: 'sell' })).rejects.toThrow('No liquidity');
  });
  it('rounds maximum input up and minimum output down', () => {
    expect(slippageLimit('exactOutput', 1n, 1n, 1n)).toBe(2n);
    expect(slippageLimit('exactInput', 1n, 1n, 1n)).toBe(0n);
    expect(() => slippageLimit('exactInput', 1n, 1n, 501n)).toThrow();
    expect(() => slippageLimit('exactInput', 1n, 1n, AUTO_SLIPPAGE_BPS)).not.toThrow();
  });
  it('never turns one receipt into a zero minimum or two-unit allowance', async () => {
    const receipt = '0x1111111111111111111111111111111111111111';
    for (const direction of ['buy', 'sell'] as const) {
      const base = rpc.readContract.getMockImplementation()!;
      const pay = direction === 'sell' ? 1n : 1000n;
      const receive = direction === 'sell' ? 1000n : 1n;
      rpc.readContract.mockImplementation(async args => {
        if (args.functionName === 'quoteSwap') return [pay, receive, '0x22'];
        if (args.functionName === 'quote') return { traderIn: pay, traderOut: receive, fee: 0n };
        return base(args);
      });
      const mode = direction === 'sell' ? 'exactOutput' : 'exactInput';
      const q = await readQuote({ receipt, route: 1n, amountWei: 1000n, direction, mode, user: USER });
      expect(q.trade.limitAmount).toBe(1n);
    }
  });
});

describe('reading precision', () => {
  it('shows a quoted leg at six places while the typed leg keeps every digit', () => {
    // the quoted side is read, not edited: 0.001015641240842677 is unreadable
    expect(formatWei(1015641240842677n, 18)).toBe('0.001015');
    // what the user typed round-trips exactly, so a flip never loses their wei
    expect(weiToTyped(1000000000000000001n, 'token', 'wstETH', 18)).toBe('1.000000000000000001');
  });
});
