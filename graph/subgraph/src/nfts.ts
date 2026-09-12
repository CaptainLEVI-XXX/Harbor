import { Address, BigInt, Bytes, dataSource, ethereum } from "@graphprotocol/graph-ts";
import { NftPolicyConfigured, NftPricingPublished, NftTraded } from "../generated/Book/Book";
import { Adapter } from "../generated/Book/Adapter";
import { Strategy, NativeClaim, Trade, NftPricingUpdate, Realization } from "../generated/schema";
import { initializeStrategy } from "./configuration";
import { eventId, nativeId, nativeKey, pool, poolId, provenance, routeId } from "./common";
import { issue } from "./common";
import { topic } from "./trading";

export function nftStrategyId(route: BigInt): Bytes { return routeId(route).concat(Bytes.fromUTF8(":NFT")); }
const NFT_TRADE = topic("NftTraded(uint256,uint256,address,address,bool,uint256,uint256,uint256,uint256,uint256)");
const NATIVE_TRADE = topic("NativeNftTrade(address,address,uint256,uint256,bool,uint256,uint256,uint256,uint256)");

/** Only the issuer-wide policy event creates a supported NFT strategy. Never invent one from a label. */
export function handleNftPolicyConfigured(event: NftPolicyConfigured): void {
  const source = Strategy.load(routeId(event.params.route));
  if (source == null) { issue(event, pool(), "MISSING_NFT_SOURCE"); return; }
  if (Strategy.load(nftStrategyId(event.params.route)) != null) return;
  const issuer = Adapter.bind(Address.fromBytes(source.adapter)).try_ISSUER();
  if (issuer.reverted) { issue(event, pool(), "MISSING_NFT_ISSUER"); return; }
  const s = initializeStrategy(event.params.route, issuer.value, source.adapter, "NFT");
  s.id = nftStrategyId(event.params.route); s.source = source.id; s.issuer = issuer.value;
  s.issuerName = source.issuerName; s.tokenSymbol = null;
  const name = source.issuerName;
  s.label = name === null ? "Withdrawal NFTs" : name + " · Withdrawal NFTs";
  s.settlementPath = "DIRECT_NFT"; s.save();
}

export function handleNftPricingPublished(event: NftPricingPublished): void {
  const s = Strategy.load(nftStrategyId(event.params.route)), id = eventId(event);
  if (NftPricingUpdate.load(id) != null) return;
  if (s == null) { issue(event, pool(), "MISSING_NFT_POLICY"); return; }
  const p = event.params.parameters;
  s.pricingVersion = p.version; s.pricingDiscount = p.discount;
  s.pricingValidUntil = p.validUntil; s.pricingConfigVersion = p.configVersion; s.save();
  const h = new NftPricingUpdate(id); h.pool = poolId(); h.strategy = s.id;
  h.version = p.version; h.discount = p.discount; h.observedAt = p.observedAt;
  h.validUntil = p.validUntil; h.configVersion = p.configVersion; provenance(h, event); h.save();
}

/** Book cash/basis events own economic totals. Adapter custody is not another trade or another asset. */
export function handleNftTraded(event: NftTraded): void {
  const id = eventId(event), p = pool(), s = Strategy.load(nftStrategyId(event.params.route));
  if (Trade.load(id) != null) return;
  p.portfolioChangedSinceCheckpoint = true; p.save();
  if (s == null) { issue(event, p, "MISSING_NFT_STRATEGY"); return; }
  const buy = event.params.acquired, cash = event.params.cash, fee = event.params.fee;
  if (!buy && fee.gt(cash)) { issue(event, p, "FEE_EXCEEDS_CASH"); return; }
  const vaultCash = buy ? cash.plus(fee) : cash.minus(fee);
  const key = nativeId(s.adapter, event.params.tokenId);
  let c = NativeClaim.load(key);
  const previousGeneration = c == null ? BigInt.zero() : c.generation;
  if (previousGeneration !== null && !event.params.generation.equals(previousGeneration.plus(BigInt.fromI32(1)))) {
    issue(event, p, "NFT_GENERATION_GAP"); return;
  }
  if (buy) {
    if (c != null && (c.state != "SOLD" || c.representation != "RAW_NFT")) {
      issue(event, p, "DUPLICATE_NFT_ACQUISITION"); return;
    }
    if (!event.params.basis.equals(vaultCash)) { issue(event, p, "NFT_BUY_BASIS_MISMATCH"); return; }
    c = new NativeClaim(key); c.pool = p.id; c.strategy = s.id; c.issuerId = event.params.tokenId;
    c.bookKey = nativeKey(s.adapter, event.params.tokenId); c.basis = event.params.basis;
    c.initialEntitlement = event.params.nominal; c.remainingEntitlement = event.params.nominal;
    c.recoveredCash = BigInt.zero(); c.state = "PENDING"; c.representation = "RAW_NFT";
    c.generation = event.params.generation; c.requestedAt = event.block.timestamp;
    c.requestTransaction = event.transaction.hash; c.requestLogIndex = event.logIndex;
    c.lastRecipient = null; c.closedAt = null; c.finalRealization = null; c.save();
    s.pendingBasis = s.pendingBasis.plus(event.params.basis);
    s.inventoryUnits = s.inventoryUnits.plus(BigInt.fromI32(1)); s.heldNominal = s.heldNominal.plus(event.params.nominal);
    s.buyCashDebit = s.buyCashDebit.plus(vaultCash);
  } else {
    if (c == null || c.state != "PENDING" || c.representation != "RAW_NFT" || !c.basis.equals(event.params.basis)
      || !c.remainingEntitlement.equals(event.params.nominal) || s.pendingBasis.lt(event.params.basis)) {
      issue(event, p, "MISSING_NFT_SALE_BASIS"); return;
    }
    c.state = "SOLD"; c.closedAt = event.block.timestamp; c.generation = event.params.generation;
    c.lastRecipient = event.params.receiver; c.remainingEntitlement = BigInt.zero(); c.save();
    s.pendingBasis = s.pendingBasis.minus(event.params.basis);
    s.inventoryUnits = s.inventoryUnits.minus(BigInt.fromI32(1)); s.heldNominal = s.heldNominal.minus(event.params.nominal);
    s.sellCashCredit = s.sellCashCredit.plus(vaultCash);
    const r = new Realization(id); r.pool = p.id; r.strategy = s.id; r.kind = "NFT_SALE";
    r.basis = event.params.basis; r.proceeds = vaultCash; r.result = vaultCash.minus(r.basis);
    // NFT generation is distinct from the parent position version; no invented version.
    r.positionVersion = null; provenance(r, event); r.save(); s.realizedResult = s.realizedResult.plus(r.result);
  }
  s.customerCashVolume = s.customerCashVolume.plus(cash); s.protocolFees = s.protocolFees.plus(fee); s.save();
  const t = new Trade(id); t.pool = p.id; t.strategy = s.id; t.trader = event.params.trader;
  t.receiver = event.params.receiver; t.settlementTrader = event.params.trader;
  t.buyBase = buy; t.mode = "UNKNOWN"; t.settlementPath = "DIRECT_NFT";
  t.tokenIn = buy ? s.base : p.asset; t.tokenOut = buy ? p.asset : s.base;
  t.amountIn = buy ? BigInt.fromI32(1) : cash; t.amountOut = buy ? cash : BigInt.fromI32(1);
  t.fee = fee; t.customerCash = cash; t.vaultCash = vaultCash;
  t.tokenId = event.params.tokenId; t.generation = event.params.generation;
  t.pricingVersion = s.pricingVersion; t.positionVersion = null; t.context = null;
  t.settlementLogIndex = event.logIndex; provenance(t, event);
  attributePeriphery(t, event);
  t.save();
}

/** Join only a reviewed Periphery's following completion, bounded by the next Book NFT fill. */
function attributePeriphery(t: Trade, event: NftTraded): void {
  const configured = dataSource.context().get("periphery"), receipt = event.receipt;
  if (configured == null || !event.params.trader.equals(configured.toBytes())) return;
  if (receipt == null) { issue(event, pool(), "MISSING_NATIVE_NFT_COMPLETION"); return; }
  for (let i = 0; i < receipt.logs.length; ++i) {
    const log = receipt.logs[i];
    if (log.logIndex.le(event.logIndex) || log.topics.length == 0) continue;
    if (log.address.equals(event.address) && log.topics[0].equals(NFT_TRADE)) break;
    if (!log.address.equals(configured.toBytes()) || log.topics.length != 4 || !log.topics[0].equals(NATIVE_TRADE)) continue;
    const tokenId = ethereum.decode("uint256", log.topics[3]);
    if (tokenId == null || !Bytes.fromUint8Array(log.topics[2].subarray(12)).equals(event.address)
      || !tokenId.toBigInt().equals(event.params.tokenId)) continue;
    const decoded = ethereum.decode("(uint256,bool,uint256,uint256,uint256,uint256)", log.data);
    if (decoded == null) break;
    const d = decoded.toTuple();
    if (!d[0].toBigInt().equals(event.params.route) || d[1].toBoolean() != t.buyBase
      || !d[2].toBigInt().equals(t.amountIn) || !d[3].toBigInt().equals(t.amountOut)
      || !d[4].toBigInt().equals(t.fee)) break;
    t.trader = Bytes.fromUint8Array(log.topics[1].subarray(12)); t.receiver = t.trader; return;
  }
  issue(event, pool(), "MISSING_NATIVE_NFT_COMPLETION");
}
