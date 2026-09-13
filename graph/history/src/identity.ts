import { BigInt, Bytes, Entity, Value, dataSource, ethereum } from '@graphprotocol/graph-ts';
export function word(n: BigInt): Bytes {
  assert(n.ge(BigInt.zero()), 'negative identity');
  let h = n.toHexString().slice(2); assert(h.length <= 64, 'identity overflow');
  while (h.length < 64) h = '0' + h;
  return Bytes.fromHexString('0x' + h);
}
export function seriesId(): Bytes {
  return Bytes.fromUTF8('harbor:history:v1').concat(word(dataSource.context().getBigInt('chainId'))).concat(dataSource.context().getBytes('issuer'));
}
export function requestId(n: BigInt): Bytes { return seriesId().concat(Bytes.fromUTF8(':request:')).concat(word(n)); }
export function claimId(n: BigInt): Bytes { return seriesId().concat(Bytes.fromUTF8(':claim:')).concat(word(n)); }
export function eventId(e: ethereum.Event, domain: string): Bytes { return seriesId().concat(Bytes.fromUTF8(':' + domain + ':')).concat(e.transaction.hash).concat(word(e.logIndex)); }
export function provenance(row: Entity, e: ethereum.Event): void {
  row.set('blockNumber', Value.fromBigInt(e.block.number)); row.set('blockHash', Value.fromBytes(e.block.hash));
  row.set('transactionHash', Value.fromBytes(e.transaction.hash)); row.set('transactionIndex', Value.fromBigInt(e.transaction.index));
  row.set('logIndex', Value.fromBigInt(e.logIndex)); row.set('timestamp', Value.fromBigInt(e.block.timestamp));
}
