import { Address, BigInt, ethereum } from "@graphprotocol/graph-ts";
import { LiquidityIssued, Transfer, WithdrawalQueued, WithdrawalFunded, Withdraw, ValuationCommitted } from "../generated/Vault/Vault";
import { LPDeposit, ExitRequest, ExitFunding, ExitPayout, ValuationCheckpoint, ShareTransfer } from "../generated/schema";
import { pool, poolId, eventId, ticketId, balance, credit, provenance, issue } from "./common";

/** LiquidityIssued owns deposit cash flow; Deposit is intentionally not mapped a second time. */
export function handleLiquidityIssued(event: LiquidityIssued): void {
  const id = eventId(event);
  if (LPDeposit.load(id) != null) return;
  const p = pool(), deposit = new LPDeposit(id);
  deposit.pool = p.id; deposit.payer = event.params.payer; deposit.controller = event.params.controller;
  deposit.receiver = event.params.receiver; deposit.assets = event.params.assets; deposit.shares = event.params.shares;
  provenance(deposit, event); deposit.save();
  p.depositedAssets = p.depositedAssets.plus(deposit.assets); p.save();
}

/** Transfer is the only share-supply mutation. Payout events consume funded units instead. */
export function handleTransfer(event: Transfer): void {
  const id = eventId(event);
  if (ShareTransfer.load(id) != null) return;
  const p = pool(), sender = event.params.from, receiver = event.params.to, amount = event.params.amount;
  const transfer = new ShareTransfer(id);
  transfer.pool = p.id; transfer.sender = sender; transfer.receiver = receiver; transfer.shares = amount;
  provenance(transfer, event); transfer.save();
  if (sender.equals(receiver)) { p.save(); return; }
  if (!sender.equals(Address.zero())) {
    const previous = balance(sender);
    if (previous.shares.lt(amount)) { issue(event, p, "MISSING_SHARE_HISTORY"); return; }
  }
  if (receiver.equals(Address.zero()) && p.shareSupply.lt(amount)) { issue(event, p, "MISSING_SUPPLY_HISTORY"); return; }
  if (sender.equals(Address.zero())) p.shareSupply = p.shareSupply.plus(amount);
  else { const previous = balance(sender); previous.shares = previous.shares.minus(amount); previous.save(); }
  if (receiver.equals(Address.zero())) p.shareSupply = p.shareSupply.minus(amount);
  else { const next = balance(receiver); next.shares = next.shares.plus(amount); next.save(); }
  p.save();
}

export function handleWithdrawalQueued(event: WithdrawalQueued): void {
  const id = ticketId(event.params.ticket);
  const existing = ExitRequest.load(id);
  if (existing != null) {
    if (!existing.requestTransaction.equals(event.transaction.hash) || !existing.requestLogIndex.equals(event.logIndex)) {
      issue(event, pool(), "DUPLICATE_TICKET");
    }
    return;
  }
  const p = pool(), c = credit(event.params.controller), request = new ExitRequest(id);
  request.pool = p.id; request.ticket = event.params.ticket; request.controller = event.params.controller;
  request.owner = event.params.owner; request.caller = event.params.caller; request.requestedShares = event.params.shares;
  request.pendingShares = event.params.shares; request.fundedShares = BigInt.zero(); request.fundedAssets = BigInt.zero();
  request.requestedAt = event.block.timestamp; request.requestTransaction = event.transaction.hash;
  request.requestLogIndex = event.logIndex; request.save();
  c.pendingShares = c.pendingShares.plus(event.params.shares); c.save();
  p.pendingShares = p.pendingShares.plus(event.params.shares); p.save();
}

export function handleWithdrawalFunded(event: WithdrawalFunded): void {
  const id = eventId(event);
  if (ExitFunding.load(id) != null) return;
  const p = pool(), request = ExitRequest.load(ticketId(event.params.ticket));
  if (request == null) { issue(event, p, "MISSING_EXIT_REQUEST"); return; }
  const c = credit(event.params.controller), shares = event.params.shares, assets = event.params.assets;
  if (!request.controller.equals(event.params.controller) || shares.le(BigInt.zero()) || request.pendingShares.lt(shares)
    || !request.pendingShares.minus(shares).equals(event.params.remaining) || c.pendingShares.lt(shares) || p.pendingShares.lt(shares)) {
    issue(event, p, "INVALID_EXIT_FUNDING"); return;
  }
  const funding = new ExitFunding(id);
  funding.pool = p.id; funding.request = request.id; funding.controller = event.params.controller;
  funding.shares = shares; funding.assets = assets; funding.remainingShares = event.params.remaining;
  provenance(funding, event); funding.save();
  request.pendingShares = event.params.remaining; request.fundedShares = request.fundedShares.plus(shares);
  request.fundedAssets = request.fundedAssets.plus(assets);
  if (request.pendingShares.isZero()) request.fundingCompletedAt = event.block.timestamp;
  request.save();
  c.pendingShares = c.pendingShares.minus(shares); c.fundedUnits = c.fundedUnits.plus(shares);
  c.claimableAssets = c.claimableAssets.plus(assets); c.save();
  p.pendingShares = p.pendingShares.minus(shares); p.reservedAssets = p.reservedAssets.plus(assets); p.save();
}

/** The owner field is the controller. No ticket attribution is emitted or invented. */
export function handleWithdraw(event: Withdraw): void {
  const id = eventId(event);
  if (ExitPayout.load(id) != null) return;
  const p = pool(), c = credit(event.params.owner), assets = event.params.assets, units = event.params.shares;
  if (c.claimableAssets.lt(assets) || c.fundedUnits.lt(units) || p.reservedAssets.lt(assets)) {
    issue(event, p, "MISSING_CONTROLLER_CREDIT"); return;
  }
  const payout = new ExitPayout(id);
  payout.pool = p.id; payout.controller = event.params.owner; payout.receiver = event.params.to;
  payout.caller = event.params.by; payout.assets = assets; payout.fundedUnits = units;
  provenance(payout, event); payout.save();
  c.claimableAssets = c.claimableAssets.minus(assets); c.fundedUnits = c.fundedUnits.minus(units); c.save();
  p.reservedAssets = p.reservedAssets.minus(assets); p.paidAssets = p.paidAssets.plus(assets); p.save();
}

/** Immutable event-position observation, not an end-of-transaction or executable NAV. */
export function handleValuationCommitted(event: ValuationCommitted): void {
  const id = eventId(event);
  if (ValuationCheckpoint.load(id) != null) return;
  const p = pool(), mark = new ValuationCheckpoint(id);
  mark.pool = p.id; mark.nav = event.params.nav; mark.supply = event.params.supply;
  mark.cash = event.params.cash; mark.reserved = event.params.reserved;
  mark.inventoryMark = event.params.inventoryMark; mark.claimMark = event.params.claimMark;
  mark.observedAt = event.params.observedAt; provenance(mark, event); mark.save();
  p.lastCheckpoint = id; p.portfolioChangedSinceCheckpoint = false; p.save();
  const backing = mark.cash.plus(mark.inventoryMark).plus(mark.claimMark);
  const expected = backing.ge(mark.reserved) ? backing.minus(mark.reserved) : BigInt.zero();
  if (!expected.equals(mark.nav) || !mark.supply.equals(p.shareSupply) || !mark.reserved.equals(p.reservedAssets)) {
    issue(event, p, "CHECKPOINT_RECONCILIATION");
  }
}

/** Only an invalidation hint. Even false still requires current contract/RPC checks. */
export function handlePortfolioMutation(event: ethereum.Event): void {
  const p = pool(); p.portfolioChangedSinceCheckpoint = true; p.save();
}
