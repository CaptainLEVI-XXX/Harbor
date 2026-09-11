import { Address, BigInt, Bytes, DataSourceContext, ethereum } from "@graphprotocol/graph-ts";
import { assert, beforeEach, clearStore, dataSourceMock, newMockEvent, test } from "matchstick-as";
import { LiquidityIssued, Transfer, WithdrawalQueued, WithdrawalFunded, Withdraw, ValuationCommitted } from "../generated/Vault/Vault";
import { Pool, Trade } from "../generated/schema";
import { FillSettled, IssuerRouteConfigured, PositionRealized, RedemptionRequested, RedemptionRecovered,
  ClaimIntegrationScheduled, IntegrationActivated, ClaimMarketRegistered, ReceiptAcquired, ReceiptDisposed, NativeClaimExported } from "../generated/Book/Book";
import { ClaimWrapped } from "../generated/Factory/Factory";
import { ClaimCashCollected } from "../generated/Adapter/Adapter";
import { Transfer as ReceiptTransfer, Redeemed } from "../generated/templates/ReceiptToken/ReceiptToken";
import { eventId, logId, poolId, ticketId, routeId, nativeId, nativeKey, uint256 } from "../src/common";
import { handleFillSettled, topic } from "../src/trading";
import { handleIssuerRouteConfigured, handleIntegrationScheduled, handleIntegrationActivated, handleClaimMarketRegistered } from "../src/configuration";
import { handleRedemptionRequested, handleRedemptionRecovered, handlePositionRealized, handleReceiptAcquired, handleReceiptDisposed, handleNativeClaimExported } from "../src/claims";
import { handleClaimWrapped, handleReceiptTransfer, handleReceiptRedeemed, handleClaimCashCollected, receiptId } from "../src/receipts";
import { handleLiquidityIssued, handleTransfer, handleWithdrawalQueued, handleWithdrawalFunded, handleWithdraw, handleValuationCommitted, handlePortfolioMutation } from "../src/vault";

const alice = Address.fromString("0x00000000000000000000000000000000000000a1");
const vault = Address.fromString("0x0000000000000000000000000000000000000102");
const book = Address.fromString("0x0000000000000000000000000000000000000101");
const executor = Address.fromString("0x0000000000000000000000000000000000000104");
const factory = Address.fromString("0x0000000000000000000000000000000000000105");
const adapter = Address.fromString("0x0000000000000000000000000000000000000106");
const token = Address.fromString("0x0000000000000000000000000000000000000107");
const bob = Address.fromString("0x00000000000000000000000000000000000000b1");
const digest = Bytes.fromHexString("0x" + "33".repeat(32));
let logIndex: i32 = 0;

function configure(chain: i32, selectedBook: Address = book, decimals: i32 = 6, selectedVault: Address = vault): void {
  const c = new DataSourceContext();
  c.setBigInt("chainId", BigInt.fromI32(chain)); c.setBytes("book", selectedBook); c.setBytes("vault", selectedVault); c.setBytes("executor", executor);
  c.setBytes("asset", Address.fromString("0x0000000000000000000000000000000000000103"));
  c.setI32("cashDecimals", decimals); c.setString("environment", "BUILD_FIXTURE");
  dataSourceMock.setReturnValues(vault.toHexString(), chain === 1 ? "mainnet" : "arbitrum-one", c);
}

beforeEach(() => { clearStore(); logIndex = 0; configure(1); });

function ev(values: ethereum.Value[]): ethereum.Event {
  const event = newMockEvent(); event.address = vault;
  event.transaction.hash = Bytes.fromHexString("0x" + "11".repeat(32));
  event.block.hash = Bytes.fromHexString("0x" + "22".repeat(32));
  event.block.number = BigInt.fromI32(100); event.logIndex = BigInt.fromI32(logIndex++);
  event.block.timestamp = BigInt.fromI32(1000 + logIndex); event.parameters = [];
  for (let i = 0; i < values.length; ++i) event.parameters.push(new ethereum.EventParam("arg", values[i]));
  return event;
}

function n(value: i32): ethereum.Value { return ethereum.Value.fromUnsignedBigInt(BigInt.fromI32(value)); }
function a(value: Address): ethereum.Value { return ethereum.Value.fromAddress(value); }
function b(value: Bytes): ethereum.Value { return ethereum.Value.fromFixedBytes(value); }
function flag(value: boolean): ethereum.Value { return ethereum.Value.fromBoolean(value); }
function bn(value: BigInt): ethereum.Value { return ethereum.Value.fromUnsignedBigInt(value); }
function addressWord(value: Address): Bytes { return Bytes.fromHexString("0x" + "00".repeat(12)).concat(value); }
function encoded(values: ethereum.Value[]): Bytes { return ethereum.encode(ethereum.Value.fromTuple(changetype<ethereum.Tuple>(values)))!; }
function log(event: ethereum.Event, emitter: Address, topics: Bytes[], data: Bytes): ethereum.Log {
  return new ethereum.Log(emitter, topics, data, event.block.hash, uint256(event.block.number), event.transaction.hash,
    event.transaction.index, event.logIndex, event.transactionLogIndex, "mined", null);
}
function attach(event: ethereum.Event, logs: ethereum.Log[]): void {
  event.receipt = new ethereum.TransactionReceipt(event.transaction.hash, BigInt.zero(), event.block.hash, event.block.number,
    BigInt.zero(), BigInt.zero(), Address.zero(), logs, BigInt.fromI32(1), Bytes.empty(), Bytes.empty());
}
function route(): void {
  handleIssuerRouteConfigured(changetype<IssuerRouteConfigured>(ev([n(0), a(Address.fromString("0x0000000000000000000000000000000000000108")), a(adapter), n(1), n(1), n(0), n(0), n(1000), n(1000), n(1000), n(1000)])));
}
function makeFill(buy: boolean, input: BigInt, output: BigInt, fee: BigInt, version: i32, selectedBook: Address = book, routeNumber: i32 = 0): FillSettled {
  const fill = changetype<FillSettled>(ev([b(digest), n(routeNumber), flag(buy), bn(input), bn(output), n(version)])); fill.address = selectedBook;
  const completion = ev([]);
  attach(fill, [log(fill, selectedBook, [topic("FillSettled(bytes32,uint256,bool,uint256,uint256,uint256)"), digest, uint256(BigInt.fromI32(routeNumber))], encoded([flag(buy), bn(input), bn(output), n(version)])),
    log(completion, executor, [topic("TradeExecuted(address,bytes32,address,address,uint256,uint256,uint256,uint256,uint256)"), addressWord(selectedBook), digest, addressWord(alice)],
      encoded([a(alice), n(routeNumber), bn(input), bn(output), bn(fee), n(7)]))]);
  return fill;
}
function fill(buy: boolean, input: i32, output: i32, fee: i32, version: i32, routeNumber: i32 = 0): void {
  const event = makeFill(buy, BigInt.fromI32(input), BigInt.fromI32(output), BigInt.fromI32(fee), version, book, routeNumber);
  handleFillSettled(event); handleFillSettled(event);
}
function realize(kind: i32, basis: i32, proceeds: i32, version: i32, key: Bytes = Bytes.fromHexString("0x" + "00".repeat(32))): void {
  handlePositionRealized(changetype<PositionRealized>(ev([n(0), b(key), n(kind), n(basis), n(proceeds), n(version)])));
}
function request(): void { handleRedemptionRequested(changetype<RedemptionRequested>(ev([b(digest), n(0), n(42), n(10), n(100), n(110)]))); }

function wrap(owner: Address, includeLaterTransfer: boolean = false): void {
  const mint = ev([]), activation = ev([]);
  const wrapped = changetype<ClaimWrapped>(ev([a(adapter), b(digest), a(token), a(owner), a(owner)])); wrapped.address = factory;
  attach(wrapped, [log(mint, token, [topic("Transfer(address,address,uint256)"), addressWord(Address.zero()), addressWord(owner)], encoded([n(1)])),
    log(activation, token, [topic("Activated(bytes32,address,address,uint256)"), digest, addressWord(adapter), addressWord(owner)], encoded([n(110)]))]);
  if (includeLaterTransfer) wrapped.receipt!.logs.push(log(ev([]), token, [topic("Transfer(address,address,uint256)"), addressWord(owner), addressWord(bob)], encoded([n(1)])));
  handleClaimWrapped(wrapped);
}
function market(): void {
  handleIntegrationScheduled(changetype<ClaimIntegrationScheduled>(ev([a(factory), n(0), a(adapter), a(Address.fromString("0x0000000000000000000000000000000000000103")), n(1), n(1), n(100)])));
  handleIntegrationActivated(changetype<IntegrationActivated>(ev([a(factory), a(adapter)])));
  handleClaimMarketRegistered(changetype<ClaimMarketRegistered>(ev([n(1), a(token), a(factory), b(digest)])));
}
function transfer(from: Address, to: Address, shares: i32): void {
  handleTransfer(changetype<Transfer>(ev([a(from), a(to), n(shares)])));
}
function deposit(): void {
  transfer(Address.zero(), alice, 100000000);
  const event = changetype<LiquidityIssued>(ev([a(alice), a(alice), a(alice), n(100), n(100000000)]));
  handleLiquidityIssued(event); handleLiquidityIssued(event);
}
function checkpoint(nav: i32, supply: i32, cash: i32, reserved: i32): void {
  handleValuationCommitted(changetype<ValuationCommitted>(ev([n(nav), n(supply), n(cash), n(reserved), n(0), n(0), n(1000)])));
}

test("LP deposit, partial funding and aggregate credit payout reconcile without duplicate burns", () => {
  deposit(); checkpoint(100, 100000000, 100, 0);
  transfer(alice, vault, 60000000);
  handleWithdrawalQueued(changetype<WithdrawalQueued>(ev([n(0), a(alice), a(alice), a(alice), n(60000000)])));
  transfer(vault, Address.zero(), 20000000);
  const funded = changetype<WithdrawalFunded>(ev([n(0), a(alice), n(20000000), n(20), n(40000000)]));
  handleWithdrawalFunded(funded); handleWithdrawalFunded(funded);
  handleWithdraw(changetype<Withdraw>(ev([a(alice), a(alice), a(alice), n(10), n(10000000)])));
  assert.fieldEquals("Pool", poolId().toHexString(), "shareSupply", "80000000");
  assert.fieldEquals("Pool", poolId().toHexString(), "reservedAssets", "10");
  assert.fieldEquals("Pool", poolId().toHexString(), "pendingShares", "40000000");
  transfer(vault, Address.zero(), 40000000);
  handleWithdrawalFunded(changetype<WithdrawalFunded>(ev([n(0), a(alice), n(40000000), n(40), n(0)])));
  handleWithdraw(changetype<Withdraw>(ev([a(alice), a(alice), a(alice), n(50), n(50000000)])));
  assert.fieldEquals("Pool", poolId().toHexString(), "depositedAssets", "100");
  assert.fieldEquals("Pool", poolId().toHexString(), "paidAssets", "60");
  assert.fieldEquals("Pool", poolId().toHexString(), "shareSupply", "40000000");
  assert.fieldEquals("Pool", poolId().toHexString(), "reservedAssets", "0");
  assert.fieldEquals("Pool", poolId().toHexString(), "pendingShares", "0");
  assert.fieldEquals("Pool", poolId().toHexString(), "complete", "true");
  assert.fieldEquals("ControllerCredit", poolId().concat(alice).toHexString(), "fundedUnits", "0");
  assert.fieldEquals("ExitRequest", ticketId(BigInt.zero()).toHexString(), "fundedAssets", "60");
  assert.entityCount("LPDeposit", 1); assert.entityCount("ExitFunding", 2); assert.entityCount("ExitPayout", 2);
  assert.entityCount("DataIssue", 0);
});

test("identical addresses, transactions and tickets remain isolated across chains", () => {
  deposit(); const first = poolId(); const event = ev([]); const firstEvent = eventId(event);
  configure(42161); logIndex = 0; deposit(); const second = poolId();
  assert.assertTrue(!first.equals(second)); assert.assertTrue(!firstEvent.equals(eventId(event)));
  assert.entityCount("Pool", 2); assert.entityCount("LPDeposit", 2);
  assert.fieldEquals("Pool", first.toHexString(), "shareSupply", "100000000");
  assert.fieldEquals("Pool", second.toHexString(), "shareSupply", "100000000");
  configure(1); route();
  const firstFill = makeFill(true, BigInt.fromI32(10), BigInt.fromI32(99), BigInt.fromI32(1), 1);
  const repeat = makeFill(true, BigInt.fromI32(10), BigInt.fromI32(99), BigInt.fromI32(1), 2);
  const secondBook = Address.fromString("0x0000000000000000000000000000000000000201");
  const other = makeFill(true, BigInt.fromI32(10), BigInt.fromI32(99), BigInt.fromI32(1), 1, secondBook);
  const all = firstFill.receipt!.logs.concat(repeat.receipt!.logs).concat(other.receipt!.logs);
  attach(firstFill, all); attach(repeat, all); attach(other, all);
  handleFillSettled(firstFill); handleFillSettled(repeat);
  assert.fieldEquals("Strategy", routeId(BigInt.zero()).toHexString(), "inventoryBasis", "200");
  configure(1, secondBook, 6, Address.fromString("0x0000000000000000000000000000000000000202")); route(); handleFillSettled(other);
  assert.fieldEquals("Strategy", routeId(BigInt.zero()).toHexString(), "inventoryBasis", "100");
  assert.entityCount("Trade", 3); assert.entityCount("DataIssue", 0);
});

test("four execution-result vectors preserve cash direction and fees in six and eighteen decimals", () => {
  for (let decimals: i32 = 6; decimals <= 18; decimals += 12) {
    configure(decimals === 6 ? 1 : 42161, book, decimals); route();
    const scale = BigInt.fromI32(10).pow(decimals as u8);
    // Buy exact-input/output, then sell exact-input/output result pairs. Mode is intentionally UNKNOWN.
    const inputs = [2, 3, 5, 7], outputs = [4, 6, 2, 3], fees = [1, 1, 1, 2];
    for (let mode = 0; mode < 4; ++mode) {
      if (mode >= 2) {
        const basis = scale.times(BigInt.fromI32(mode == 2 ? 24 : 36)).div(BigInt.fromI32(5));
        handlePositionRealized(changetype<PositionRealized>(ev([n(0), b(Bytes.fromHexString("0x" + "00".repeat(32))), n(0), bn(basis), bn(scale.times(BigInt.fromI32(mode == 2 ? 4 : 5))), n(mode + 1)])));
      }
      const e = makeFill(mode < 2, scale.times(BigInt.fromI32(inputs[mode])), scale.times(BigInt.fromI32(outputs[mode])), scale.times(BigInt.fromI32(fees[mode])), mode + 1);
      handleFillSettled(e);
      const id = e.receipt!.logs[1].logIndex;
      const record = Trade.load(logId(e.transaction.hash, id))!;
      assert.assertTrue(record.vaultCash.equals(scale.times(BigInt.fromI32([5, 7, 4, 5][mode]))));
      assert.stringEquals(record.mode, "UNKNOWN");
    }
    assert.fieldEquals("Strategy", routeId(BigInt.zero()).toHexString(), "protocolFees", scale.times(BigInt.fromI32(5)).toString());
    assert.fieldEquals("Strategy", routeId(BigInt.zero()).toHexString(), "buyCashDebit", scale.times(BigInt.fromI32(12)).toString());
    assert.fieldEquals("Strategy", routeId(BigInt.zero()).toHexString(), "sellCashCredit", scale.times(BigInt.fromI32(9)).toString());
    assert.fieldEquals("Strategy", routeId(BigInt.zero()).toHexString(), "inventoryUnits", "0");
    assert.fieldEquals("Strategy", routeId(BigInt.zero()).toHexString(), "inventoryBasis", "0");
    assert.fieldEquals("Strategy", routeId(BigInt.zero()).toHexString(), "realizedResult", scale.times(BigInt.fromI32(-3)).toString());
  }
  assert.entityCount("Trade", 8); assert.entityCount("DataIssue", 0);
  const invalid = makeFill(true, BigInt.fromI32(1), BigInt.fromI32(1), BigInt.zero(), 5);
  invalid.receipt = null; handleFillSettled(invalid);
  assert.entityCount("Trade", 8); assert.entityCount("DataIssue", 1);
});

test("native request and partial recovery realize a final loss without counting cumulative cash twice", () => {
  route(); fill(true, 10, 99, 1, 1); request();
  const strategy = routeId(BigInt.zero()).toHexString(), claim = nativeId(adapter, BigInt.fromI32(42)).toHexString();
  assert.fieldEquals("Strategy", strategy, "inventoryBasis", "0"); assert.fieldEquals("Strategy", strategy, "pendingBasis", "100");
  assert.fieldEquals("Strategy", strategy, "recoveredCash", "0");
  handleRedemptionRecovered(changetype<RedemptionRecovered>(ev([n(0), n(42), n(30), n(70)])));
  assert.fieldEquals("Strategy", strategy, "realizedResult", "0"); assert.fieldEquals("Strategy", strategy, "pendingBasis", "100");
  realize(1, 100, 90, 4, nativeKey(adapter, BigInt.fromI32(42)));
  const final = changetype<RedemptionRecovered>(ev([n(0), n(42), n(60), n(0)])); handleRedemptionRecovered(final); handleRedemptionRecovered(final);
  assert.fieldEquals("NativeClaim", claim, "state", "CLOSED"); assert.fieldEquals("NativeClaim", claim, "recoveredCash", "90");
  assert.fieldEquals("Strategy", strategy, "pendingBasis", "0"); assert.fieldEquals("Strategy", strategy, "recoveredCash", "90");
  assert.fieldEquals("Strategy", strategy, "realizedResult", "-10"); assert.entityCount("ClaimRecovery", 2); assert.entityCount("Realization", 1);
  handleRedemptionRecovered(changetype<RedemptionRecovered>(ev([n(0), n(42), n(60), n(0)])));
  assert.entityCount("ClaimRecovery", 2); assert.entityCount("DataIssue", 1);
});

test("native export preserves basis and receipt reacquisition creates a separate realized episode", () => {
  route(); fill(true, 10, 99, 1, 1); request(); wrap(vault); market();
  handleReceiptAcquired(changetype<ReceiptAcquired>(ev([n(1), n(1), n(100), flag(true)])));
  handleNativeClaimExported(changetype<NativeClaimExported>(ev([n(0), n(42), n(1), a(token), n(100)])));
  assert.fieldEquals("Strategy", routeId(BigInt.zero()).toHexString(), "pendingBasis", "0");
  assert.fieldEquals("Strategy", routeId(BigInt.fromI32(1)).toHexString(), "inventoryBasis", "100");
  assert.entityCount("Realization", 0);
  handleReceiptDisposed(changetype<ReceiptDisposed>(ev([n(1), n(2), n(100), n(105), flag(false)])));
  fill(false, 106, 1, 1, 2, 1);
  handleReceiptAcquired(changetype<ReceiptAcquired>(ev([n(1), n(3), n(96), flag(false)])));
  fill(true, 1, 95, 1, 3, 1);
  const recovery = changetype<ReceiptDisposed>(ev([n(1), n(4), n(96), n(110), flag(true)])); handleReceiptDisposed(recovery); handleReceiptDisposed(recovery);
  const id = routeId(BigInt.fromI32(1)).toHexString();
  assert.fieldEquals("Strategy", id, "inventoryBasis", "0"); assert.fieldEquals("Strategy", id, "realizedResult", "19");
  assert.fieldEquals("Strategy", id, "recoveredCash", "110"); assert.fieldEquals("Strategy", id, "sellCashCredit", "105");
  assert.entityCount("HoldingEpisode", 2); assert.entityCount("NativeExport", 1); assert.entityCount("Realization", 2); assert.entityCount("DataIssue", 0);
});

test("receipt creation bootstrap and template replay preserve Bob's payout without crediting the Vault", () => {
  route(); wrap(alice, true);
  const moved = changetype<ReceiptTransfer>(ev([a(alice), a(bob), n(1)])); moved.address = token; moved.logIndex = BigInt.fromI32(4); handleReceiptTransfer(moved); handleReceiptTransfer(moved);
  const collected = changetype<ClaimCashCollected>(ev([b(digest), n(90)])); collected.address = adapter; handleClaimCashCollected(collected);
  const burn = changetype<ReceiptTransfer>(ev([a(bob), a(Address.zero()), n(1)])); burn.address = token; handleReceiptTransfer(burn);
  const paid = changetype<Redeemed>(ev([a(bob), a(bob), n(90)])); paid.address = token; handleReceiptRedeemed(paid); handleReceiptRedeemed(paid);
  // Replay the mint that the dynamically-created template may deliver after factory bootstrap.
  const mint = changetype<ReceiptTransfer>(ev([a(Address.zero()), a(alice), n(1)])); mint.address = token; mint.logIndex = BigInt.fromI32(1); handleReceiptTransfer(mint);
  const id = receiptId(token).toHexString();
  assert.fieldEquals("Receipt", id, "owner", Address.zero().toHexString()); assert.fieldEquals("Receipt", id, "redeemed", "true");
  assert.fieldEquals("Receipt", id, "complete", "true"); assert.fieldEquals("Receipt", id, "collectedCash", "90"); assert.fieldEquals("Receipt", id, "paidCash", "90");
  assert.fieldEquals("Strategy", routeId(BigInt.zero()).toHexString(), "recoveredCash", "0");
  assert.entityCount("ReceiptActivity", 6); assert.entityCount("DataIssue", 0);
});

test("checkpoints remain dated, zero-value funding closes and missing credit is flagged", () => {
  deposit(); checkpoint(100, 100000000, 100, 0);
  handlePortfolioMutation(ev([]));
  assert.fieldEquals("Pool", poolId().toHexString(), "portfolioChangedSinceCheckpoint", "true");
  // Synthetic total loss: recovery remains zero; no healthy-NAV claim is made.
  checkpoint(0, 100000000, 0, 0);
  transfer(alice, vault, 100000000);
  handleWithdrawalQueued(changetype<WithdrawalQueued>(ev([n(0), a(alice), a(alice), a(alice), n(100000000)])));
  transfer(vault, Address.zero(), 100000000);
  handleWithdrawalFunded(changetype<WithdrawalFunded>(ev([n(0), a(alice), n(100000000), n(0), n(0)])));
  assert.fieldEquals("ExitRequest", ticketId(BigInt.zero()).toHexString(), "pendingShares", "0");
  assert.fieldEquals("ExitRequest", ticketId(BigInt.zero()).toHexString(), "fundedAssets", "0");
  assert.fieldEquals("Pool", poolId().toHexString(), "shareSupply", "0");
  handleWithdraw(changetype<Withdraw>(ev([a(alice), a(alice), a(alice), n(1), n(1)])));
  assert.entityCount("ExitPayout", 0); assert.entityCount("DataIssue", 1);
  assert.fieldEquals("Pool", poolId().toHexString(), "complete", "false");
});
