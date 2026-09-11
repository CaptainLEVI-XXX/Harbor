// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {FixedPointMathLib as Math} from "solady/utils/FixedPointMathLib.sol";
import {LibSort} from "solady/utils/LibSort.sol";
import {IHarborValuation} from "src/interfaces/IHarborValuation.sol";
import {SafeTransferLib as SafeTransfer} from "solady/utils/SafeTransferLib.sol";
import {AdapterBase} from "src/adapters/base/AdapterBase.sol";
import {IHarborBook} from "src/interfaces/IHarborBook.sol";
import {SwapVM} from "@1inch/swap-vm/src/SwapVM.sol";
import {LidoClaims} from "src/adapters/lido/LidoClaims.sol";
import {IssuerClaimLedger} from "src/libraries/IssuerClaimLedger.sol";
import {IHarborClaim} from "src/interfaces/IHarborClaim.sol";
import {ClaimObservation, InventoryObservation, ClaimStage} from "src/types/ClaimTypes.sol";
import {
  ILidoWithdrawalQueue as Queue,
  ILidoShareTotals,
  ILidoWrappedShares
} from "src/interfaces/ILidoWithdrawalQueue.sol";

/// @title LidoViews
/// @notice Protocol-native entitlement with a separate, explicit public haircut policy.
/// @dev Pending marks remain authorized estimates, not executable cash or pricing
/// parameters. Finalized rights use issuer claimable amounts; custody and receipt
/// ownership remain enforced by Book/adapters. No external oracle service is used.
abstract contract LidoViews is AdapterBase, IHarborValuation {
  struct Config {
    address factory;
    address governor;
    address publisher;
    uint256 maxAge;
    uint256 governanceDelay;
  }

  address public immutable STETH;
  address public immutable GOVERNOR;
  uint256 public immutable MAX_AGE;
  uint256 public immutable GOVERNANCE_DELAY;
  uint256 public constant POLICY_VERSION = 1;
  address public publisher;
  address public pendingPublisher;
  uint256 public publisherReadyAt;
  uint256 public inventoryFactor;
  uint256 public claimFactor;
  uint256 public observedAt;
  uint256 public validUntil;
  uint256 public version;

  error InvalidObservation();

  event MarksPublished(
    uint256 indexed version, uint256 inventoryFactor, uint256 claimFactor, uint256 observedAt, uint256 validUntil
  );
  event PublisherScheduled(address indexed publisher, uint256 readyAt);
  event PublisherChanged(address indexed publisher);

  constructor(address book, address vault, address base, address weth, address issuer, Config memory c)
    AdapterBase(book, vault, base, weth, issuer, c.factory)
  {
    if (
      c.governor == address(0) || c.publisher == address(0) || c.maxAge == 0
        || c.maxAge > (block.chainid == 560048 ? 100 days : 1 days) || c.governanceDelay < 1 days
        || c.governanceDelay > 30 days || Queue(issuer).WSTETH() != base
        || address(SwapVM(payable(IHarborBook(book).ROUTER())).WETH()) != weth
    ) revert InvalidConfiguration();
    STETH = ILidoWrappedShares(base).stETH();
    if (STETH.code.length == 0) revert InvalidConfiguration();
    GOVERNOR = c.governor;
    publisher = c.publisher;
    MAX_AGE = c.maxAge;
    GOVERNANCE_DELAY = c.governanceDelay;
  }

  /// @notice Publish public NAV haircuts, independently of Harbor trading parameters.
  /// @dev Zero haircuts allow explicit impairment. The publisher cannot change
  /// conversion totals, issuer claimable cash, owned quantities or the fee policy.
  /// @param inventoryFactor_ Inventory multiplier, 0..1e18; 1e18 means no impairment.
  /// @param claimFactor_ Pending-right multiplier, 0..1e18; never applied to finalized cash.
  /// @param time Nonfuture, nondecreasing observation time, Unix seconds.
  /// @param expiry Inclusive expiry, no later than time + MAX_AGE.
  /// @param nextVersion Current version plus one; prevents stale queued publication.
  function publish(uint256 inventoryFactor_, uint256 claimFactor_, uint256 time, uint256 expiry, uint256 nextVersion)
    external
  {
    if (msg.sender != publisher) revert Unauthorized();
    _idle();
    if (
      inventoryFactor_ > 1e18 || claimFactor_ > 1e18 || time == 0 || time > block.timestamp || time < observedAt
        || expiry < block.timestamp || expiry - time > MAX_AGE || nextVersion != version + 1
    ) revert InvalidObservation();
    inventoryFactor = inventoryFactor_;
    claimFactor = claimFactor_;
    observedAt = time;
    validUntil = expiry;
    version = nextVersion;
    emit MarksPublished(nextVersion, inventoryFactor_, claimFactor_, time, expiry);
  }

  function schedulePublisher(address next) external {
    if (msg.sender != GOVERNOR || next == address(0)) revert Unauthorized();
    _idle();
    pendingPublisher = next;
    publisherReadyAt = block.timestamp + GOVERNANCE_DELAY;
    emit PublisherScheduled(next, publisherReadyAt);
  }

  function applyPublisher() external {
    _idle();
    if (publisherReadyAt == 0 || block.timestamp < publisherReadyAt) revert Unauthorized();
    publisher = pendingPublisher;
    pendingPublisher = address(0);
    publisherReadyAt = 0;
    validUntil = 0;
    emit PublisherChanged(publisher);
  }

  /// @notice Revoke estimated marks immediately; finalized issuer evidence is unaffected.
  function revokePublisher() external {
    if (msg.sender != GOVERNOR) revert Unauthorized();
    _idle();
    publisher = address(0);
    pendingPublisher = address(0);
    publisherReadyAt = 0;
    validUntil = 0;
    emit PublisherChanged(address(0));
  }

  /// @inheritdoc IHarborValuation
  function conversion(address base) public view returns (uint256 numerator, uint256 denominator) {
    if (base != BASE) revert InvalidConfiguration();
    numerator = ILidoShareTotals(STETH).getTotalPooledEther();
    denominator = ILidoShareTotals(STETH).getTotalShares();
    if (numerator == 0 || denominator == 0) revert InvalidObservation();
  }

  /// @inheritdoc IHarborValuation
  function inventory(address base, uint256 quantity)
    public
    view
    returns (uint256 nominal, uint256 mark, uint256 time, uint256 policy, bytes32 hash, bool valid)
  {
    (uint256 n, uint256 d) = conversion(base);
    nominal = Math.fullMulDiv(quantity, n, d);
    mark = Math.fullMulDiv(nominal, inventoryFactor, 1e18);
    time = quantity == 0 ? block.timestamp : observedAt;
    policy = POLICY_VERSION;
    hash = keccak256(abi.encode(base, n, d, version, inventoryFactor));
    valid = quantity == 0 || _fresh();
  }

  /// @notice All owned rights for one source route, capped at 64, in caller order.
  function observePortfolio(address base, uint256 quantity, bytes32[] calldata ids)
    external
    view
    returns (InventoryObservation memory inv, ClaimObservation[] memory observations)
  {
    (inv.entitlement, inv.mark, inv.observedAt,, inv.observationHash, inv.valid) = inventory(base, quantity);
    observations = _observe(ids);
  }

  function claimState(bytes32 id) public view returns (ClaimObservation memory) {
    bytes32[] memory ids = new bytes32[](1);
    ids[0] = id;
    return _observe(ids)[0];
  }

  function _observe(bytes32[] memory ids) internal view returns (ClaimObservation[] memory result) {
    uint256[] memory nativeIds = _pendingIds(ids);
    (Queue.WithdrawalRequestStatus[] memory statuses, uint256[] memory cash) = LidoClaims.observe(ISSUER, nativeIds);
    result = new ClaimObservation[](ids.length);
    bool backed = SafeTransfer.balanceOf(ASSET, address(this)) >= _claims.totalCash;
    uint256 cursor;
    for (uint256 i; i < ids.length; ++i) {
      IssuerClaimLedger.Claim storage c = _claims.claims[ids[i]];
      ClaimObservation memory o;
      o.domain = c.domain;
      o.entitlement = c.nominal;
      o.cash = c.cash;
      o.observedAt = block.timestamp;
      if (c.stage == ClaimStage.CLOSED) {
        o.status = IHarborClaim.Status.CLOSED;
        o.valid = true;
      } else if (c.stage == ClaimStage.CASH_READY) {
        o.status = IHarborClaim.Status.CASH_READY;
        o.mark = c.cash;
        o.valid = backed;
      } else {
        _observePending(o, c, statuses[cursor], cash[cursor]);
        ++cursor;
      }
      result[i] = o;
    }
  }

  /// @dev Validate the complete caller-ordered set before reading issuer claim statuses, then
  /// gather only rights still requiring issuer evidence. LibSort's temporary
  /// memory hash table leaves ids untouched; the 64-element cap is checked first.
  /// This avoids pairwise comparisons without imposing sorted calldata on callers.
  function _pendingIds(bytes32[] memory ids) private view returns (uint256[] memory nativeIds) {
    if (ids.length > 64 || LibSort.hasDuplicate(ids)) revert InvalidObservation();
    nativeIds = new uint256[](ids.length);
    uint256 cursor;
    for (uint256 i; i < ids.length; ++i) {
      IssuerClaimLedger.Claim storage c = _claims.claims[ids[i]];
      if (c.stage == ClaimStage.NONE) revert InvalidObservation();
      if (c.stage == ClaimStage.PENDING) nativeIds[cursor++] = c.issuerId;
    }
    // Safety considerations: <=64 inputs, at most one write per input. The
    // shortened array exposes only initialized IDs, in unchanged caller order.
    assembly ("memory-safe") {
      mstore(nativeIds, cursor)
    }
  }

  /// @dev Only stored PENDING-stage rights reach here; FINALIZED remains an issuer
  /// observation, not a cached stage. All issuer calls in this view use STATICCALL.
  function _observePending(
    ClaimObservation memory o,
    IssuerClaimLedger.Claim storage c,
    Queue.WithdrawalRequestStatus memory q,
    uint256 cash
  ) private view {
    if (
      q.isClaimed || q.owner != address(this) || Queue(ISSUER).ownerOf(c.issuerId) != address(this)
        || q.amountOfStETH != c.nominal || q.amountOfShares == 0
    ) revert ReceiptMismatch();
    o.status = q.isFinalized ? IHarborClaim.Status.FINALIZED : IHarborClaim.Status.PENDING;
    o.mark = q.isFinalized ? cash : Math.fullMulDiv(c.nominal, claimFactor, 1e18);
    o.observedAt = q.isFinalized ? block.timestamp : observedAt;
    o.valid = q.isFinalized || _fresh();
  }

  function _fresh() private view returns (bool) {
    return publisher != address(0) && version != 0 && observedAt <= block.timestamp && block.timestamp <= validUntil;
  }
}
