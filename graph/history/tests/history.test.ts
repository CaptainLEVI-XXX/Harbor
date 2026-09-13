import { Address, BigInt, Bytes, DataSourceContext, ethereum } from '@graphprotocol/graph-ts';
import { assert,beforeEach,clearStore,dataSourceMock,newMockEvent,test } from 'matchstick-as';
import { WithdrawalRequested,WithdrawalsFinalized,WithdrawalClaimed } from '../generated/Queue/LidoWithdrawalQueue';
import { handleRequest,handleFinalization,handleClaim } from '../src/lido';
import { seriesId,requestId,claimId,word } from '../src/identity';
const issuer=Address.fromString('0x0000000000000000000000000000000000000101');
const alice=Address.fromString('0x00000000000000000000000000000000000000a1');
const bob=Address.fromString('0x00000000000000000000000000000000000000b1');
let index:i32=0;
function configure(chain:i32=1,decimals:i32=18,source:Address=issuer):void {
 const c=new DataSourceContext();c.setBigInt('chainId',BigInt.fromI32(chain));c.setBytes('issuer',source);c.setString('adapterVersion','lido-inclusive-v1');c.setString('environment','BUILD_FIXTURE');c.setString('sourceAsset','eip155:'+chain.toString()+'/slip44:60');c.setString('settlementAsset','eip155:'+chain.toString()+'/slip44:60');c.setI32('decimals',decimals);dataSourceMock.setReturnValues(source.toHexString(),'mainnet',c);
}
beforeEach(()=>{clearStore();index=0;configure();});
function n(v:i32):ethereum.Value{return ethereum.Value.fromUnsignedBigInt(BigInt.fromI32(v));}
function a(v:Address):ethereum.Value{return ethereum.Value.fromAddress(v);}
function ev(values:ethereum.Value[]):ethereum.Event {
 const e=newMockEvent();e.address=issuer;e.block.number=BigInt.fromI32(10);e.block.timestamp=BigInt.fromI32(100);e.block.hash=Bytes.fromHexString('0x'+'22'.repeat(32));e.transaction.hash=Bytes.fromHexString('0x'+'11'.repeat(32));e.transaction.index=BigInt.zero();e.logIndex=BigInt.fromI32(index++);e.parameters=[];
 for(let i=0;i<values.length;i++)e.parameters.push(new ethereum.EventParam('arg',values[i]));return e;
}
function request(id:i32,face:i32=100,shares:i32=90):WithdrawalRequested{return changetype<WithdrawalRequested>(ev([n(id),a(alice),a(bob),n(face),n(shares)]));}
function batch(first:i32,last:i32,locked:i32,shares:i32):WithdrawalsFinalized{return changetype<WithdrawalsFinalized>(ev([n(first),n(last),n(locked),n(shares),n(100)]));}
function claim(id:i32,amount:i32):WithdrawalClaimed{return changetype<WithdrawalClaimed>(ev([n(id),a(bob),a(alice),n(amount)]));}
test('request replay is idempotent and stores exact prefix',()=>{const e=request(1);handleRequest(e);handleRequest(e);assert.entityCount('WithdrawalRequest',1);assert.fieldEquals('HistorySeries',seriesId().toHexString(),'requestCount','1');assert.fieldEquals('WithdrawalRequest',requestId(BigInt.fromI32(1)).toHexString(),'prefixFace','100');});
test('inclusive single and multi request finalizations use cumulative prefixes',()=>{handleRequest(request(1));handleRequest(request(2));handleRequest(request(3));const b=batch(1,2,195,180);handleFinalization(b);handleFinalization(b);handleFinalization(batch(3,3,100,90));assert.entityCount('FinalizationBatch',2);assert.fieldEquals('HistorySeries',seriesId().toHexString(),'lastFinalized','3');assert.fieldEquals('HistorySeries',seriesId().toHexString(),'locked','295');});
test('claims retain independent owner and receiver and replay once',()=>{handleRequest(request(1));handleFinalization(batch(1,1,100,90));const c=claim(1,100);handleClaim(c);handleClaim(c);assert.entityCount('WithdrawalClaim',1);assert.fieldEquals('WithdrawalClaim',claimId(BigInt.fromI32(1)).toHexString(),'ownerAtClaim',bob.toHexString());assert.fieldEquals('WithdrawalClaim',claimId(BigInt.fromI32(1)).toHexString(),'receiver',alice.toHexString());assert.fieldEquals('HistorySeries',seriesId().toHexString(),'paid','100');});
test('missing first request permanently marks incomplete',()=>{handleRequest(request(2));handleRequest(request(1));assert.fieldEquals('HistorySeries',seriesId().toHexString(),'complete','false');assert.entityCount('HistoryIssue',1);});
test('conflicting request fails closed',()=>{handleRequest(request(1));handleRequest(request(1));assert.fieldEquals('HistorySeries',seriesId().toHexString(),'complete','false');assert.entityCount('WithdrawalRequest',1);});
test('overlapping range rejected',()=>{handleRequest(request(1));handleRequest(request(2));handleFinalization(batch(1,1,100,90));handleFinalization(batch(1,2,200,180));assert.entityCount('FinalizationBatch',1);assert.fieldEquals('HistorySeries',seriesId().toHexString(),'complete','false');});
test('range share mismatch rejected',()=>{handleRequest(request(1));handleFinalization(batch(1,1,100,89));assert.entityCount('FinalizationBatch',0);assert.fieldEquals('HistorySeries',seriesId().toHexString(),'complete','false');});
test('claim before finalization rejected',()=>{handleRequest(request(1));handleClaim(claim(1,100));assert.entityCount('WithdrawalClaim',0);assert.fieldEquals('HistorySeries',seriesId().toHexString(),'complete','false');});
test('wrong emitter is recorded once as issue',()=>{const e=request(1);e.address=alice;handleRequest(e);handleRequest(e);assert.entityCount('HistoryIssue',1);assert.entityCount('WithdrawalRequest',0);});
test('same logical request is isolated across chains and uses raw units at six decimals',()=>{handleRequest(request(1));const first=seriesId();configure(42161,6);handleRequest(request(1));assert.assertTrue(!first.equals(seriesId()));assert.entityCount('WithdrawalRequest',2);assert.fieldEquals('HistorySeries',seriesId().toHexString(),'decimals','6');assert.fieldEquals('HistorySeries',seriesId().toHexString(),'cumulativeFace','100');});
test('issuer and entity domains cannot collide',()=>{const one=seriesId();const req=requestId(BigInt.fromI32(1));assert.assertTrue(!req.equals(claimId(BigInt.fromI32(1))));configure(1,18,alice);assert.assertTrue(!one.equals(seriesId()));});
test('uint256 identifiers retain leading padding and high bits',()=>{assert.stringEquals(word(BigInt.fromI32(1)).toHexString(),'0x'+'00'.repeat(31)+'01');assert.stringEquals(word(BigInt.fromString('340282366920938463463374607431768211456')).toHexString(),'0x'+'00'.repeat(15)+'01'+'00'.repeat(16));});
test('large finalization stays a single range entity',()=>{for(let id=1;id<=1000;id++)handleRequest(request(id));handleFinalization(batch(1,1000,100000,90000));assert.entityCount('FinalizationBatch',1);assert.fieldEquals('HistorySeries',seriesId().toHexString(),'lastFinalized','1000');});
