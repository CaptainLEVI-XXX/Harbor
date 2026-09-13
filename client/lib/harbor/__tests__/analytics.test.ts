import { describe, expect, it } from 'vitest';
import { entryPrice, estimatedApy, recentActivity, shareObservations, trailingApy } from '../analytics';
import type { History } from '../history';
const base={lpDeposits:[],trades:[],claimRecoveries:[],exitPayouts:[],valuationCheckpoints:[]} as unknown as History;
describe('indexed analytics',()=>{
  it('orders real events by block and log, retaining explorer provenance',()=>{
    const e={id:'a',timestamp:'10',transactionHash:'0xabc',logIndex:'1',blockNumber:'10'};
    const h={...base,lpDeposits:[{...e,receiver:'x',assets:'100',shares:'100'}],claimRecoveries:[{...e,id:'b',logIndex:'2',cash:'5'}]};
    expect(recentActivity(h).map(x=>[x.id,x.cash,x.transactionHash])).toEqual([['b','5','0xabc'],['a','100','0xabc']]);
  });
  it('does not turn deposits into share-price profit, includes losses and skips empty supply',()=>{
    const e={id:'a',timestamp:'1',blockNumber:'1',logIndex:'0',nav:'1000000000000000000',supply:'1000000000000000000000000',cash:'0',reserved:'0',inventoryMark:'0',claimMark:'0'};
    const h={...base,valuationCheckpoints:[{...e,id:'empty',supply:'0'},e,{...e,id:'deposit',blockNumber:'2',nav:'2000000000000000000',supply:'2000000000000000000000000'},{...e,id:'loss',blockNumber:'3',nav:'900000000000000000'}]};
    expect(shareObservations(h).map(x=>x.price)).toEqual([10n**18n,10n**18n,9n*10n**17n]);
  });
  it('gives no rate from a day of history, only an estimate',()=>{
    const cp=(id:string,hours:number,nav:string)=>({id,timestamp:String(hours*3600),blockNumber:String(hours+1),logIndex:'0',nav,supply:'1000000000000000000000000',cash:'0',reserved:'0',inventoryMark:'0',claimMark:'0'});
    const h={...base,valuationCheckpoints:[cp('a',1,'1000000000000000000'),cp('b',3,'1004000000000000000'),cp('c',25,'1006008000000000000')]};
    // a day of history is no rate, but it is an estimate, annualised to now
    expect(trailingApy(h)).toBeNull();
    expect(estimatedApy(h, 101*3600_000)).toEqual({pct:0.6008*8760/100,hours:100});
  });
  it('prices an entry from the wallet\'s own deposits only',()=>{
    expect(entryPrice({...base,userDeposits:[]})).toBeNull();
    expect(entryPrice({...base,userDeposits:[{assets:'1000000000000000000',shares:'1000000000000000000000000'},{assets:'3000000000000000000',shares:'1000000000000000000000000'}]})).toBe(2n*10n**18n);
  });
});
