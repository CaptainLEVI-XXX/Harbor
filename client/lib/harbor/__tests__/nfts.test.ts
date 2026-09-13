import { afterEach, describe, expect, it, vi } from 'vitest';
import { decodeFunctionData, erc721Abi, getAddress } from 'viem';
import { publicClient, TOKENS } from '@/lib/chain';
import { HARBOR } from '../config';
import { nftPeripheryAbi } from '../abis';
import { readNftQuote, nftApproved } from '../nfts';
import { buildSteps } from '@/lib/swap/execute';
import { USER } from './fixtures';
afterEach(()=>vi.restoreAllMocks());
function setup() {
  vi.spyOn(publicClient,'getChainId').mockResolvedValue(560048);
  vi.spyOn(publicClient,'getBlock').mockResolvedValue({number:42n,timestamp:1000n,hash:'0x'+'11'.repeat(32)} as never);
  return vi.spyOn(publicClient,'readContract').mockImplementation(async (r)=>{
    if(r.functionName==='nftParameters')return {version:1n,validUntil:2000n};
    if(r.functionName==='configVersion')return 2n;
    if(r.functionName==='nftGeneration')return 3n;
    if(r.functionName==='quoteNft') {
      const t=r.args![0] as {side:number};
      return t.side===0?{traderIn:1n,traderOut:1000n,fee:0n}:{traderIn:1000n,traderOut:1n,fee:0n};
    }
    throw Error('Unexpected call');
  });
}
describe('direct NFT wiring',()=>{
  it('quotes all four modes with wallet ownership, whole units and cash-only slippage',async()=>{
    const read=setup();
    for(const direction of ['sell','buy'] as const)for(const mode of ['exactInput','exactOutput'] as const){
      const whole=(direction==='sell')===(mode==='exactInput');
      const q=await readNftQuote({user:USER,tokenId:5042n,amountWei:whole?1n:1000n,direction,mode});
      expect(q.nft?.trader).toBe(USER);expect(q.nft?.receiver).toBe(USER);expect(q.nft?.generation).toBe(3n);
      expect(q.nft?.limitAmount).toBe(whole?(direction==='sell'?975n:1025n):1n);
      expect(direction==='sell'?q.payWei:q.receiveWei).toBe(1n);
    }
    const calls=read.mock.calls.filter(([r])=>r.functionName==='quoteNft');
    expect(calls).toHaveLength(4);expect(calls.every(([r])=>r.blockNumber===42n)).toBe(true);
    expect((calls[1][0].args![0] as {amountSpecified:bigint}).amountSpecified).toBe(1000n);
  });
  it('approves precisely the sold NFT and funds only the ETH buy budget',async()=>{
    setup();
    const sell=await readNftQuote({user:USER,tokenId:5042n,amountWei:1n,direction:'sell',mode:'exactInput'});
    const steps=buildSteps({allowance:0n,quote:sell});
    expect(steps).toHaveLength(2);expect(steps[0].call.to).toBe(HARBOR.queue);
    expect(decodeFunctionData({abi:erc721Abi,data:steps[0].call.data}).args).toEqual([getAddress(HARBOR.periphery),5042n]);
    expect(steps[1].call.value).toBe(0n);
    expect(decodeFunctionData({abi:nftPeripheryAbi,data:steps[1].call.data}).functionName).toBe('executeNft');
    const buy=await readNftQuote({user:USER,tokenId:5042n,amountWei:1n,direction:'buy',mode:'exactOutput'});
    expect(buy.trade.tokenIn).toBe(TOKENS.WETH);
    const purchase=buildSteps({allowance:0n,quote:buy});expect(purchase).toHaveLength(1);expect(purchase[0].call.value).toBe(1025n);
  });
  it('rejects stale parameters and changed ownership before requesting wallet execution',async()=>{
    const read=setup();read.mockImplementation(async r=>r.functionName==='nftParameters'?{version:1n,validUntil:999n}:1n);
    await expect(readNftQuote({user:USER,tokenId:5042n,amountWei:1n,direction:'sell',mode:'exactInput'})).rejects.toThrow('fresh publication');
    read.mockImplementation(async r=>r.functionName==='isApprovedForAll'?true:HARBOR.adapter);
    await expect(nftApproved(5042n,USER)).rejects.toThrow('no longer');
  });
});
