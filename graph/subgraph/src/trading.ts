import { Bytes, crypto, dataSource, ethereum } from "@graphprotocol/graph-ts";
import { FillSettled } from "../generated/Book/Book";
import { Strategy, Trade } from "../generated/schema";
import { logId, pool, provenance, routeId, issue } from "./common";

export function topic(signature: string): Bytes { return Bytes.fromByteArray(crypto.keccak256(Bytes.fromUTF8(signature))); }
const FILL = topic("FillSettled(bytes32,uint256,bool,uint256,uint256,uint256)");
const EXECUTED = topic("TradeExecuted(address,bytes32,address,address,uint256,uint256,uint256,uint256,uint256)");

/** Book owns ordered position mutations. Receipt enrichment avoids cross-source handler order.
 * The shared Executor is manifest-pinned; only its next matching completion is accepted.
 * A second fill for the same pool before completion is an invalid join, not a duplicate intent.
 */
export function handleFillSettled(event: FillSettled): void {
  const p = pool(), s = Strategy.load(routeId(event.params.route));
  p.portfolioChangedSinceCheckpoint = true; p.save();
  if (s == null) { issue(event, p, "MISSING_TRADE_ROUTE"); return; }
  const receipt = event.receipt;
  if (receipt == null) { issue(event, p, "MISSING_TRANSACTION_RECEIPT"); return; }
  const executor = dataSource.context().getBytes("executor");
  let matched: ethereum.Log | null = null;
  for (let i = 0; i < receipt.logs.length; ++i) {
    const candidate = receipt.logs[i];
    if (candidate.logIndex.le(event.logIndex) || candidate.topics.length == 0) continue;
    if (candidate.address.equals(event.address) && candidate.topics[0].equals(FILL)) break;
    if (!candidate.address.equals(executor) || candidate.topics.length != 4 || !candidate.topics[0].equals(EXECUTED)) continue;
    if (!candidate.topics[1].equals(Bytes.fromHexString("0x" + "00".repeat(12)).concat(p.book))) continue;
    if (!candidate.topics[2].equals(event.params.digest)) break;
    matched = candidate; break;
  }
  if (matched == null) { issue(event, p, "MISSING_EXECUTION_JOIN"); return; }
  const decoded = ethereum.decode("(address,uint256,uint256,uint256,uint256,uint256)", matched.data);
  if (decoded == null) { issue(event, p, "INVALID_EXECUTION_DATA"); return; }
  const values = decoded.toTuple();
  if (!values[1].toBigInt().equals(event.params.route) || !values[2].toBigInt().equals(event.params.amountIn)
    || !values[3].toBigInt().equals(event.params.amountOut)) { issue(event, p, "EXECUTION_AMOUNT_MISMATCH"); return; }
  const id = logId(event.transaction.hash, matched.logIndex);
  if (Trade.load(id) != null) return;
  const buy = event.params.buyBase, fee = values[4].toBigInt();
  const customerCash = buy ? event.params.amountOut : event.params.amountIn;
  if (!buy && fee.gt(customerCash)) { issue(event, p, "FEE_EXCEEDS_CASH"); return; }
  const cash = buy ? customerCash.plus(fee) : customerCash.minus(fee);
  if (s.kind == "NATIVE") {
    if (buy) { s.inventoryUnits = s.inventoryUnits.plus(event.params.amountIn); s.inventoryBasis = s.inventoryBasis.plus(cash); }
    else {
      if (s.inventoryUnits.lt(event.params.amountOut)) { issue(event, p, "MISSING_INVENTORY"); return; }
      // PositionRealized owns sale basis/P&L and precedes this FillSettled event.
      s.inventoryUnits = s.inventoryUnits.minus(event.params.amountOut);
    }
  }
  const trade = new Trade(id); trade.pool = p.id; trade.strategy = s.id; trade.context = event.params.digest;
  trade.settlementPath = "AQUA_SWAP_VM";
  trade.trader = Bytes.fromUint8Array(matched.topics[3].subarray(12)); trade.receiver = values[0].toAddress();
  trade.buyBase = buy; trade.mode = "UNKNOWN"; // Multicalls do not expose reliable per-fill top-level calldata.
  trade.tokenIn = buy ? s.base : p.asset; trade.tokenOut = buy ? p.asset : s.base;
  trade.amountIn = event.params.amountIn; trade.amountOut = event.params.amountOut; trade.fee = fee;
  trade.customerCash = customerCash; trade.vaultCash = cash; trade.pricingVersion = values[5].toBigInt();
  trade.positionVersion = event.params.positionVersion; trade.settlementLogIndex = event.logIndex;
  provenance(trade, event); trade.logIndex = matched.logIndex; trade.save();
  s.customerCashVolume = s.customerCashVolume.plus(customerCash); s.protocolFees = s.protocolFees.plus(fee);
  if (buy) s.buyCashDebit = s.buyCashDebit.plus(cash); else s.sellCashCredit = s.sellCashCredit.plus(cash);
  s.save();
}
