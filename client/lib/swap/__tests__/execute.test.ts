import { beforeEach, describe, expect, it, vi } from 'vitest';
import { decodeFunctionData, encodeAbiParameters, encodeEventTopics, erc20Abi, parseAbiParameters } from 'viem';
import { TOKENS } from '@/lib/chain';
import { buildSteps, executeQuote } from '../execute';
import { executorAbi, peripheryAbi } from '@/lib/harbor/abis';
import { HARBOR } from '@/lib/harbor/config';
import { quoteFixture, USER } from '@/lib/harbor/__tests__/fixtures';

const rpc = vi.hoisted(() => ({ getChainId: vi.fn(), getBalance: vi.fn(), getBlock: vi.fn(), readContract: vi.fn(), call: vi.fn(), simulateContract: vi.fn(), waitForTransactionReceipt: vi.fn() }));
vi.mock('@/lib/chain', async actual => ({ ...await actual<typeof import('@/lib/chain')>(), publicClient: rpc }));

/** A settlement log for the fixture's trade: periphery traded, customer received. */
const settlementLog = (q: ReturnType<typeof quoteFixture>, amountIn: bigint, amountOut: bigint) => ({
  address: HARBOR.executor,
  topics: encodeEventTopics({ abi: executorAbi, eventName: 'TradeExecuted', args: { book: HARBOR.book, context: q.orderHash, trader: q.trade.trader } }),
  data: encodeAbiParameters(parseAbiParameters('address,uint256,uint256,uint256,uint256,uint256'), [q.trade.tokenOut === TOKENS.WETH ? HARBOR.periphery : q.trade.receiver, 0n, amountIn, amountOut, 0n, 1n]),
});

const nativeLog = (q: ReturnType<typeof quoteFixture>, caller = q.trade.receiver) => ({
  address: HARBOR.periphery,
  topics: encodeEventTopics({ abi: peripheryAbi, eventName: 'NativeTrade', args: { caller, book: HARBOR.book } }),
  data: encodeAbiParameters(parseAbiParameters('uint256,uint256,uint256'), [1000n, 1000n, 0n]),
});

/** An ETH-funded buy: the customer pays native ETH, so nothing is approved. */
function buyFixture() {
  const q = quoteFixture();
  q.trade.tokenIn = TOKENS.WETH; q.trade.tokenOut = TOKENS.wstETH; q.trade.side = 1;
  return q;
}

beforeEach(() => {
  vi.clearAllMocks();
  rpc.getChainId.mockResolvedValue(560048);
  rpc.getBalance.mockResolvedValue(10n ** 18n);
  rpc.getBlock.mockResolvedValue({ timestamp: 1000n });
  rpc.readContract.mockImplementation(async ({ functionName }) => functionName === 'allowance' ? 0n : [1000n, 1000n, '0x22']);
  rpc.call.mockResolvedValue({});
  rpc.simulateContract.mockResolvedValue({});
  rpc.waitForTransactionReceipt.mockResolvedValue({ status: 'success', logs: [] });
});

describe('ETH-funded trades through the periphery', () => {
  it('requires the final caller payout when token sales first pay WETH to Periphery', async () => {
    const q = quoteFixture();
    rpc.readContract.mockImplementation(async ({ functionName }) => functionName === 'allowance' ? 1000n : [1000n, 1000n, '0x22']);
    const send = vi.fn().mockResolvedValue('0x01');
    rpc.waitForTransactionReceipt.mockResolvedValue({ status: 'success', logs: [settlementLog(q, 1000n, 1000n)] });
    await expect(executeQuote(q, send, vi.fn())).rejects.toThrow('expected native payout');
    rpc.waitForTransactionReceipt.mockResolvedValue({ status: 'success', logs: [settlementLog(q, 1000n, 1000n), nativeLog(q, HARBOR.adapter)] });
    await expect(executeQuote(q, send, vi.fn())).rejects.toThrow('expected native payout');
    rpc.waitForTransactionReceipt.mockResolvedValue({ status: 'success', logs: [settlementLog(q, 1000n, 1000n), nativeLog(q)] });
    await expect(executeQuote(q, send, vi.fn())).resolves.toBe('0x01');
  });
  it('pays a buy in native ETH with no approval at all', async () => {
    const q = buyFixture();
    const steps = buildSteps({ allowance: 0n, quote: q });
    expect(steps).toHaveLength(1);
    expect(steps[0].kind).toBe('swap');
    expect(steps[0].call.to).toBe(HARBOR.periphery);
    expect(steps[0].call.value).toBe(q.trade.amountSpecified);
    const decoded = decodeFunctionData({ abi: peripheryAbi, data: steps[0].call.data });
    expect(decoded.functionName).toBe('execute');
    expect(decoded.args?.[0]?.toString().toLowerCase()).toBe(HARBOR.book);
  });

  it('sends an exact-output buy the ceiling it is allowed to spend, not the target', () => {
    const q = buyFixture();
    q.trade.mode = 1; q.trade.amountSpecified = 1000n; q.trade.limitAmount = 1200n;
    expect(buildSteps({ allowance: 0n, quote: q })[0].call.value).toBe(1200n);
  });

  it('approves the periphery, not the Executor, when the customer pays in a token', () => {
    const q = quoteFixture();          // wstETH in, native ETH out
    const [approve, swap] = buildSteps({ allowance: 0n, quote: q });
    const approved = decodeFunctionData({ abi: erc20Abi, data: approve.call.data });
    expect(approve.call.to).toBe(TOKENS.wstETH);
    expect(approved.args?.[0]?.toString().toLowerCase()).toBe(HARBOR.periphery);
    expect(approved.args?.[1]).toBe(1000n);
    // native output must carry no value, or the periphery rejects it
    expect(swap.call.value).toBe(0n);
    expect(buildSteps({ allowance: 1000n, quote: q })).toHaveLength(1);
  });

  it('completes a one-call buy and verifies the customer was the receiver', async () => {
    const q = buyFixture();
    rpc.waitForTransactionReceipt.mockResolvedValue({ status: 'success', logs: [settlementLog(q, 1000n, 1000n), nativeLog(q)] });
    const send = vi.fn().mockResolvedValue('0x01');
    await expect(executeQuote(q, send, vi.fn())).resolves.toBe('0x01');
    expect(send).toHaveBeenCalledTimes(1);
    expect(send.mock.calls[0][0]).toMatchObject({ to: HARBOR.periphery, value: 1000n, account: USER });
  });

  it('refuses a buy the wallet cannot also pay gas for', async () => {
    rpc.getBalance.mockResolvedValue(1000n);
    const send = vi.fn();
    await expect(executeQuote(buyFixture(), send, vi.fn())).rejects.toThrow('Keep some ETH for gas');
    expect(send).not.toHaveBeenCalled();
  });

  it('never sends execution when the new quote violates displayed limits', async () => {
    rpc.readContract.mockImplementation(async ({ functionName }) => functionName === 'allowance' ? 1000n : [1000n, 980n, '0x22']);
    const send = vi.fn();
    await expect(executeQuote(buyFixture(), send, vi.fn())).rejects.toThrow('limits');
    expect(send).not.toHaveBeenCalled();
  });

  it('stops after a reverted approval', async () => {
    rpc.waitForTransactionReceipt.mockResolvedValue({ status: 'reverted', logs: [] });
    const send = vi.fn().mockResolvedValue('0x01');
    await expect(executeQuote(quoteFixture(), send, vi.fn())).rejects.toThrow('approve reverted');
    expect(send).toHaveBeenCalledTimes(1);
  });

  it('rechecks the chain deadline after approval', async () => {
    // the batch probe reads the block first, then each sequential step does
    rpc.getBlock
      .mockResolvedValueOnce({ timestamp: 1000n })
      .mockResolvedValueOnce({ timestamp: 1000n })
      .mockResolvedValueOnce({ timestamp: 2001n });
    const send = vi.fn().mockResolvedValue('0x01');
    await expect(executeQuote(quoteFixture(), send, vi.fn())).rejects.toThrow('deadline');
    expect(send).toHaveBeenCalledTimes(1);
  });

  it('requires an actual Harbor settlement, not merely a successful transaction', async () => {
    const send = vi.fn().mockResolvedValue('0x01');
    await expect(executeQuote(buyFixture(), send, vi.fn())).rejects.toThrow('expected harbor settlement');
    expect(rpc.simulateContract).toHaveBeenCalled();
  });

  it('runs an approval and its swap atomically when the wallet can', async () => {
    const q = quoteFixture();
    const send = Object.assign(vi.fn(), { batch: vi.fn().mockResolvedValue('0xba7c4') });
    rpc.waitForTransactionReceipt.mockResolvedValue({ status: 'success', logs: [settlementLog(q, 1000n, 1000n), nativeLog(q)] });
    await expect(executeQuote(q, send, vi.fn())).resolves.toBe('0xba7c4');
    expect(send.batch).toHaveBeenCalledTimes(1);
    expect(send.batch.mock.calls[0][0]).toHaveLength(2);
    expect(send).not.toHaveBeenCalled();
  });

  it('falls back to sequential sends when the wallet cannot batch', async () => {
    const q = quoteFixture();
    const send = Object.assign(vi.fn().mockResolvedValue('0x01'), { batch: vi.fn().mockResolvedValue(null) });
    rpc.waitForTransactionReceipt.mockResolvedValue({ status: 'success', logs: [settlementLog(q, 1000n, 1000n), nativeLog(q)] });
    await expect(executeQuote(q, send, vi.fn())).resolves.toBe('0x01');
    expect(send).toHaveBeenCalledTimes(2);
  });
});
