import { BigInt, Bytes, Entity, Value, crypto, dataSource, ethereum } from "@graphprotocol/graph-ts";
import { Pool, ControllerCredit, LPBalance, DataIssue } from "../generated/schema";

/** Fixed-width unsigned big-endian integers; domain/chain prevent cross-network collisions. */
export function uint256(value: BigInt): Bytes {
  assert(value.ge(BigInt.zero()), "unsigned identity");
  let hex = value.toHexString().slice(2);
  assert(hex.length <= 64, "identity overflow");
  while (hex.length < 64) hex = "0" + hex;
  return Bytes.fromHexString("0x" + hex);
}

export function chainId(): BigInt { return dataSource.context().getBigInt("chainId"); }

export function poolId(): Bytes {
  return Bytes.fromUTF8("harbor:pool:v1").concat(uint256(chainId())).concat(dataSource.context().getBytes("book"));
}

export function eventId(event: ethereum.Event): Bytes {
  return logId(event.transaction.hash, event.logIndex);
}

export function logId(transaction: Bytes, index: BigInt): Bytes {
  return Bytes.fromUTF8("harbor:event:v1").concat(uint256(chainId())).concat(transaction).concat(uint256(index));
}
export function routeId(route: BigInt): Bytes { return poolId().concat(uint256(route)); }
/** Book ClaimAccounting.key, deliberately NOT the adapter's issuer claim identity. */
export function nativeKey(adapter: Bytes, issuerId: BigInt): Bytes {
  return Bytes.fromByteArray(crypto.keccak256(Bytes.fromHexString("0x" + "00".repeat(12)).concat(adapter).concat(uint256(issuerId))));
}
export function nativeId(adapter: Bytes, issuerId: BigInt): Bytes { return poolId().concat(nativeKey(adapter, issuerId)); }

export function ticketId(ticket: BigInt): Bytes { return poolId().concat(uint256(ticket)); }

export function provenance(entity: Entity, event: ethereum.Event): void {
  entity.set("blockNumber", Value.fromBigInt(event.block.number));
  entity.set("blockHash", Value.fromBytes(event.block.hash));
  entity.set("transactionHash", Value.fromBytes(event.transaction.hash));
  entity.set("logIndex", Value.fromBigInt(event.logIndex));
  entity.set("timestamp", Value.fromBigInt(event.block.timestamp));
}

export function pool(): Pool {
  const id = poolId();
  let p = Pool.load(id);
  if (p == null) {
    const context = dataSource.context();
    p = new Pool(id);
    p.chainId = chainId(); p.book = context.getBytes("book"); p.vault = context.getBytes("vault");
    p.asset = context.getBytes("asset"); p.cashDecimals = context.getI32("cashDecimals");
    p.shareDecimals = p.cashDecimals + 6; p.environment = context.getString("environment");
    p.complete = true; p.shareSupply = BigInt.zero(); p.pendingShares = BigInt.zero();
    p.reservedAssets = BigInt.zero(); p.depositedAssets = BigInt.zero(); p.paidAssets = BigInt.zero();
    p.portfolioChangedSinceCheckpoint = true;
  }
  return p;
}

export function credit(controller: Bytes): ControllerCredit {
  const id = poolId().concat(controller);
  let c = ControllerCredit.load(id);
  if (c == null) {
    c = new ControllerCredit(id); c.pool = poolId(); c.controller = controller;
    c.pendingShares = BigInt.zero(); c.fundedUnits = BigInt.zero(); c.claimableAssets = BigInt.zero();
  }
  return c;
}

export function balance(account: Bytes): LPBalance {
  const id = poolId().concat(account);
  let b = LPBalance.load(id);
  if (b == null) { b = new LPBalance(id); b.pool = poolId(); b.account = account; b.shares = BigInt.zero(); }
  return b;
}

/** Mark an incomplete projection explicitly. Never repair it with a zero balance. */
export function issue(event: ethereum.Event, p: Pool, code: string): void {
  p.complete = false; p.save();
  const id = eventId(event);
  if (DataIssue.load(id) != null) return;
  const problem = new DataIssue(id); problem.pool = p.id; problem.code = code;
  provenance(problem, event); problem.save();
}
