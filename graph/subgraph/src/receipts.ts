import { Address, BigInt, Bytes, DataSourceContext, dataSource, ethereum } from "@graphprotocol/graph-ts";
import { ClaimWrapped } from "../generated/Factory/Factory";
import { ClaimCashCollected } from "../generated/Adapter/Adapter";
import { Transfer, Activated, Redeemed } from "../generated/templates/ReceiptToken/ReceiptToken";
import { ReceiptToken } from "../generated/templates";
import { Receipt, ReceiptActivity, ClaimBinding } from "../generated/schema";
import { chainId, uint256, eventId, logId, provenance } from "./common";
import { topic } from "./trading";

export function receiptId(address: Bytes): Bytes { return Bytes.fromUTF8("harbor:receipt:v1").concat(uint256(chainId())).concat(address); }
function bindingId(adapter: Bytes, id: Bytes): Bytes { return Bytes.fromUTF8("harbor:claim:v1").concat(uint256(chainId())).concat(adapter).concat(id); }
function problem(r: Receipt, code: string): void { r.complete = false; r.problem = code; r.save(); }

const TRANSFER = topic("Transfer(address,address,uint256)");
const ACTIVATED = topic("Activated(bytes32,address,address,uint256)");
const REDEEMED = topic("Redeemed(address,address,uint256)");

export function handleClaimWrapped(event: ClaimWrapped): void {
  const id = receiptId(event.params.receipt);
  if (Receipt.load(id) != null) return;
  const r = new Receipt(id); r.chainId = chainId(); r.address = event.params.receipt; r.factory = event.address;
  r.adapter = event.params.adapter; r.claimId = event.params.claimId; r.asset = dataSource.context().getBytes("asset");
  r.complete = true; r.owner = Address.zero(); r.activated = false; r.collectedCash = BigInt.zero();
  r.paidCash = BigInt.zero(); r.redeemed = false; r.createdAt = event.block.timestamp; r.creationTransaction = event.transaction.hash; r.save();
  const binding = bindingId(r.adapter, r.claimId);
  if (ClaimBinding.load(binding) != null) { problem(r, "DUPLICATE_CLAIM_BINDING"); return; }
  const link = new ClaimBinding(binding); link.receipt = id; link.save();
  const context = new DataSourceContext(); context.setBigInt("chainId", chainId());
  ReceiptToken.createWithContext(event.params.receipt, context);
  const receipt = event.receipt;
  if (receipt == null) { problem(r, "MISSING_CREATION_RECEIPT"); return; }
  // Factory emits after mint/activation. Replay this token's entire creation transaction;
  // event IDs make later template handling idempotent. Never seed from end-block balances.
  for (let i = 0; i < receipt.logs.length; ++i) {
    const entry = receipt.logs[i];
    if (entry.address.equals(r.address)) applyLog(event, entry, id);
  }
  const result = Receipt.load(id)!;
  if (!result.activated) problem(result, "MISSING_ACTIVATION");
}

/** One interpreter serves transaction bootstrap and normal template events. */
function applyLog(event: ethereum.Event, entry: ethereum.Log, id: Bytes): void {
  if (entry.topics.length == 0) return;
  const signature = entry.topics[0];
  if (!signature.equals(TRANSFER) && !signature.equals(ACTIVATED) && !signature.equals(REDEEMED)) return;
  const identity = logId(event.transaction.hash, entry.logIndex);
  if (ReceiptActivity.load(identity) != null) return;
  const r = Receipt.load(id);
  if (r == null) return; // Only canonical factory-created templates are installed.
  const decoded = ethereum.decode("uint256", entry.data);
  if (decoded == null) { problem(r, "INVALID_RECEIPT_DATA"); return; }
  const amount = decoded.toBigInt(), activity = new ReceiptActivity(identity);
  activity.receipt = id; activity.amount = amount; provenance(activity, event); activity.logIndex = entry.logIndex;
  if (signature.equals(TRANSFER)) {
    if (entry.topics.length != 3) { problem(r, "INVALID_TRANSFER_TOPICS"); return; }
    const sender = Bytes.fromUint8Array(entry.topics[1].subarray(12)), receiver = Bytes.fromUint8Array(entry.topics[2].subarray(12));
    activity.kind = "TRANSFER"; activity.sender = sender; activity.receiver = receiver;
    // ERC20 zero transfers are legal, including from non-holders. They move no entitlement.
    if (!amount.isZero()) {
      if (!amount.equals(BigInt.fromI32(1)) || !r.owner.equals(sender) || r.redeemed || r.burnedHolder !== null) {
        problem(r, "INVALID_RECEIPT_OWNERSHIP"); return;
      }
      r.owner = receiver;
      if (receiver.equals(Address.zero())) r.burnedHolder = sender;
    }
  } else if (signature.equals(ACTIVATED)) {
    if (entry.topics.length != 4 || r.activated || !entry.topics[1].equals(r.claimId)
      || !Bytes.fromUint8Array(entry.topics[2].subarray(12)).equals(r.adapter)
      || !Bytes.fromUint8Array(entry.topics[3].subarray(12)).equals(r.owner) || amount.isZero()) {
      problem(r, "INVALID_RECEIPT_ACTIVATION"); return;
    }
    activity.kind = "ACTIVATED"; r.activated = true; r.nominal = amount;
  } else {
    if (entry.topics.length != 3) { problem(r, "INVALID_REDEMPTION_TOPICS"); return; }
    const holder = Bytes.fromUint8Array(entry.topics[1].subarray(12)), recipient = Bytes.fromUint8Array(entry.topics[2].subarray(12));
    const burned = r.burnedHolder;
    if (burned === null || !burned.equals(holder) || r.redeemed) { problem(r, "MISSING_RECEIPT_BURN"); return; }
    activity.kind = "REDEEMED"; activity.sender = holder; activity.receiver = recipient;
    r.redeemed = true; r.paidCash = amount;
    // Holder payout is not automatically Vault cash. Book ReceiptDisposed owns that projection.
  }
  activity.save(); r.save();
}

function applyEvent(event: ethereum.Event, topics: Bytes[], amount: BigInt): void {
  const encoded = ethereum.encode(ethereum.Value.fromUnsignedBigInt(amount));
  if (encoded === null) return;
  const log = new ethereum.Log(event.address, topics, encoded, event.block.hash, uint256(event.block.number),
    event.transaction.hash, event.transaction.index, event.logIndex, event.transactionLogIndex, "mined", null);
  applyLog(event, log, receiptId(event.address));
}

function addressTopic(value: Address): Bytes { return Bytes.fromHexString("0x" + "00".repeat(12)).concat(value); }
export function handleReceiptTransfer(event: Transfer): void {
  applyEvent(event, [TRANSFER, addressTopic(event.params.from), addressTopic(event.params.to)], event.params.amount);
}
export function handleReceiptActivated(event: Activated): void {
  applyEvent(event, [ACTIVATED, event.params.claimId, addressTopic(event.params.adapter), addressTopic(event.params.owner)], event.params.nominal);
}
export function handleReceiptRedeemed(event: Redeemed): void {
  applyEvent(event, [REDEEMED, addressTopic(event.params.holder), addressTopic(event.params.receiver)], event.params.cash);
}

/** Collection is adapter credit, not pool liquidity and not another holder payment. */
export function handleClaimCashCollected(event: ClaimCashCollected): void {
  const link = ClaimBinding.load(bindingId(event.address, event.params.claimId));
  if (link == null) return;
  const r = Receipt.load(link.receipt)!, id = eventId(event);
  if (ReceiptActivity.load(id) != null) return;
  const activity = new ReceiptActivity(id); activity.receipt = r.id; activity.kind = "COLLECTED";
  activity.amount = event.params.cash; provenance(activity, event); activity.save();
  r.collectedCash = r.collectedCash.plus(event.params.cash); r.save();
}
