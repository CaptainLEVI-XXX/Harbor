import { erc721Abi, maxUint256, zeroHash, type Address } from 'viem';
import { publicClient, TOKENS } from '@/lib/chain';
import { HARBOR, requireNetwork } from './config';
import { QUOTE_LIFETIME_SECONDS, QUOTE_REFRESH_MS } from '@/lib/constants';
import { bookAbi } from './abis';
import { nftBookAbi } from './abis';
import { explainCapacity } from './withdrawals';
import { slippageLimit, AUTO_SLIPPAGE_BPS, type QuoteInput, type ExecutableQuote } from './quote';
export type NftTrade = { trader: Address; receiver: Address; route: bigint; tokenId: bigint; side: 0|1; mode: 0|1; amountSpecified: bigint; limitAmount: bigint; deadline: bigint; pricingVersion: bigint; configVersion: bigint; generation: bigint };
import { queueAbi as queueReadAbi } from './abis';
/** Ownership discovery is not authorization. Book re-observes the issuer at quote and settlement. */
export async function listNfts(user: Address | undefined, buying: boolean) {
  await requireNetwork();
  const blockNumber=await publicClient.getBlockNumber();
  let ids: bigint[]=[];
  if (buying) {
    let cursor=0n;
    for(let page=0;page<3;page++) {
      const [claims,next]=await publicClient.readContract({address:HARBOR.book,abi:nftBookAbi,functionName:'nftInventory',args:[cursor,32n],blockNumber});
      ids.push(...claims.filter(c=>c.route===HARBOR.inventoryRoute).map(c=>c.issuerId));
      if(next===cursor || next===0n)break;
      cursor=next;
    }
  } else if(user) ids=[...await publicClient.readContract({address:HARBOR.queue,abi:queueReadAbi,functionName:'getWithdrawalRequests',args:[user],blockNumber})];
  const truncated=ids.length>100;ids=ids.slice(0,100);
  if(!ids.length)return {rows:[],truncated};
  const states=await publicClient.readContract({address:HARBOR.queue,abi:queueReadAbi,functionName:'getWithdrawalStatus',args:[ids],blockNumber});
  const expected=buying?HARBOR.adapter:user?.toLowerCase();
  const rows=states.flatMap((s,i)=>!s.isFinalized&&!s.isClaimed&&s.owner.toLowerCase()===expected ? [{tokenId:ids[i],entitlement:s.amountOfStETH,requestedAt:s.timestamp,route:HARBOR.inventoryRoute,address:HARBOR.queue}] : []);
  return {rows,truncated};
}
export async function readNftQuote(input: QuoteInput): Promise<ExecutableQuote> {
  if(input.tokenId===undefined || input.tokenId<=0n || !input.user)throw Error('Connect and select a pending withdrawal NFT.');
  await requireNetwork();
  const block=await publicClient.getBlock(),route=input.route??HARBOR.inventoryRoute;
  const [p,configVersion,generation]=await Promise.all([
    publicClient.readContract({address:HARBOR.book,abi:nftBookAbi,functionName:'nftParameters',args:[route],blockNumber:block.number}),
    publicClient.readContract({address:HARBOR.book,abi:bookAbi,functionName:'configVersion',blockNumber:block.number}),
    publicClient.readContract({address:HARBOR.book,abi:nftBookAbi,functionName:'nftGeneration',args:[route,input.tokenId],blockNumber:block.number}),
  ]);
  if(p.version===0n||p.validUntil<=block.timestamp)throw Error('NFT pricing needs a fresh publication.');
  const sell=input.direction==='sell',exactIn=input.mode==='exactInput';
  const deadline = block.timestamp + QUOTE_LIFETIME_SECONDS;
  const nft: NftTrade={trader:input.user,receiver:input.user,route,tokenId:input.tokenId,side:sell?0:1,mode:exactIn?0:1,amountSpecified:input.amountWei,limitAmount:exactIn?0n:maxUint256,deadline:deadline<p.validUntil?deadline:p.validUntil,pricingVersion:p.version,configVersion,generation};
  const a=await publicClient.readContract({address:HARBOR.book,abi:nftBookAbi,functionName:'quoteNft',args:[nft],blockNumber:block.number}).catch(error=>explainCapacity(error,sell));
  if((sell?a.traderIn:a.traderOut)!==1n)throw Error('Exactly one whole NFT must settle.');
  nft.limitAmount=(sell&&!exactIn)||(!sell&&exactIn)?1n:slippageLimit(input.mode,a.traderIn,a.traderOut,input.slippageBps??AUTO_SLIPPAGE_BPS);
  const fetchedAt=Date.now();
  return {nft,trade:{...nft,tokenIn:sell?HARBOR.queue:TOKENS.WETH,tokenOut:sell?TOKENS.WETH:HARBOR.queue,strategyVersion:0n},payWei:a.traderIn,receiveWei:a.traderOut,feeWei:a.fee,blockNumber:block.number,blockHash:block.hash,orderHash:zeroHash,fetchedAt,refreshAt:Math.min(fetchedAt+QUOTE_REFRESH_MS,Number(nft.deadline)*1000),input,rate:'One whole pending withdrawal NFT #'+input.tokenId};
}
export async function nftApproved(id:bigint,user:Address) {
  const [owner,approved,operator]=await Promise.all([
    publicClient.readContract({address:HARBOR.queue,abi:erc721Abi,functionName:'ownerOf',args:[id]}),
    publicClient.readContract({address:HARBOR.queue,abi:erc721Abi,functionName:'getApproved',args:[id]}),
    publicClient.readContract({address:HARBOR.queue,abi:erc721Abi,functionName:'isApprovedForAll',args:[user,HARBOR.periphery]}),
  ]);
  if(owner.toLowerCase()!==user.toLowerCase())throw Error('This NFT is no longer in your wallet.');
  return operator||approved.toLowerCase()===HARBOR.periphery;
}
