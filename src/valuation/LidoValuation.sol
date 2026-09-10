// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {FixedPointMathLib as Math} from "solady/utils/FixedPointMathLib.sol";
import {IHarborValuation} from "src/interfaces/IHarborValuation.sol";
import {IHarborAdapter} from "src/interfaces/IHarborAdapter.sol";
import {IHarborBook} from "src/interfaces/IHarborBook.sol";
import {IHarborClaim, IHarborClaimFactory, IHarborClaimExporter} from "src/interfaces/IHarborClaim.sol";
import {ClaimMarkets} from "src/libraries/ClaimMarkets.sol";
import {RouteConfig} from "src/types/HarborTypes.sol";
import {ILidoWithdrawalQueue as Queue} from "src/interfaces/ILidoWithdrawalQueue.sol";

/// @notice Exact underlying share totals; a rounded one-token rate is insufficient.
interface ILidoShareTotals {
  function getTotalPooledEther() external view returns (uint256);
  function getTotalShares() external view returns (uint256);
}

interface ILidoWrappedShares {
  function stETH() external view returns (address);
}

interface ILidoValuationQueue {
  function getLastCheckpointIndex() external view returns (uint256);
  function findCheckpointHints(uint256[] calldata ids, uint256 first, uint256 last)
    external
    view
    returns (uint256[] memory);
}

interface ILidoValuationBook {
  function claimIntegration(address factory) external view returns (ClaimMarkets.Integration memory);
  function route(uint256 id) external view returns (RouteConfig memory);
}

/// @title LidoValuation
/// @notice Protocol-native entitlement with a separate, explicit public haircut policy.
/// @dev Pending marks remain authorized estimates, not executable cash or pricing
/// parameters. Finalized rights use issuer claimable amounts; custody and receipt
/// ownership remain enforced by Book/adapters. No external oracle service is used.
contract LidoValuation is IHarborValuation {
  struct Config {
    address wsteth;
    address queue;
    address adapter; // May be a predicted deployment; validated before publication.
    address governor;
    address publisher;
    uint256 maxAge;
    uint256 governanceDelay;
  }

  address public immutable WSTETH;
  address public immutable STETH;
  address public immutable QUEUE;
  address public immutable ADAPTER;
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

  error Unauthorized();
  error InvalidObservation();
  error InvalidConfiguration();
  error Busy();

  event MarksPublished(
    uint256 indexed version, uint256 inventoryFactor, uint256 claimFactor, uint256 observedAt, uint256 validUntil
  );
  event PublisherScheduled(address indexed publisher, uint256 readyAt);
  event PublisherChanged(address indexed publisher);

  constructor(Config memory c) {
    if (
      c.wsteth.code.length == 0 || c.queue.code.length == 0 || c.adapter == address(0) || c.governor == address(0)
        || c.publisher == address(0) || c.maxAge == 0 || c.maxAge > 1 days || c.governanceDelay < 1 days
        || c.governanceDelay > 30 days || Queue(c.queue).WSTETH() != c.wsteth
    ) revert InvalidConfiguration();
    WSTETH = c.wsteth;
    STETH = ILidoWrappedShares(c.wsteth).stETH();
    if (STETH.code.length == 0) revert InvalidConfiguration();
    QUEUE = c.queue;
    ADAPTER = c.adapter;
    GOVERNOR = c.governor;
    publisher = c.publisher;
    MAX_AGE = c.maxAge;
    GOVERNANCE_DELAY = c.governanceDelay;
  }

  /// @notice Publish public NAV haircuts, independently of Harbor trading parameters.
  /// @dev Zero haircuts allow explicit impairment. The publisher cannot change
  /// conversion totals, issuer claimable cash, owned quantities or the fee policy.
  /// @param inventoryFactor_ Inventory multiplier, 0..1e18; one means no impairment.
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
        || expiry < block.timestamp || expiry < time || expiry - time > MAX_AGE || nextVersion != version + 1
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
    if (base != WSTETH) revert InvalidConfiguration();
    numerator = ILidoShareTotals(STETH).getTotalPooledEther();
    denominator = ILidoShareTotals(STETH).getTotalShares();
    if (numerator == 0 || denominator == 0) revert InvalidObservation();
  }

  /// @inheritdoc IHarborValuation
  function inventory(address base, uint256 quantity)
    external
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

  /// @inheritdoc IHarborValuation
  function claim(address adapter, uint256 id, uint256 remaining)
    external
    view
    returns (uint256 mark, uint256 time, uint256 policy, bool valid)
  {
    if (adapter != ADAPTER) revert InvalidConfiguration();
    _adapter();
    uint256[] memory ids = new uint256[](1);
    ids[0] = id;
    Queue.WithdrawalRequestStatus[] memory s = Queue(QUEUE).getWithdrawalStatus(ids);
    policy = POLICY_VERSION;
    if (s.length != 1 || s[0].isClaimed || !_backedOwner(id, s[0].owner) || remaining != s[0].amountOfStETH) {
      return (0, 0, policy, false);
    }
    if (s[0].isFinalized) {
      uint256 last = ILidoValuationQueue(QUEUE).getLastCheckpointIndex();
      uint256[] memory hints = ILidoValuationQueue(QUEUE).findCheckpointHints(ids, 1, last);
      uint256[] memory cash = Queue(QUEUE).getClaimableEther(ids, hints);
      if (cash.length != 1 || cash[0] > remaining) return (0, 0, policy, false);
      return (cash[0], block.timestamp, policy, true);
    }
    return (Math.fullMulDiv(remaining, claimFactor, 1e18), observedAt, policy, _fresh());
  }

  function _fresh() private view returns (bool) {
    return publisher != address(0) && version != 0 && observedAt <= block.timestamp && block.timestamp <= validUntil;
  }

  function _idle() private view {
    _adapter();
    if (!IHarborBook(IHarborAdapter(ADAPTER).BOOK()).isIdle()) revert Busy();
  }

  function _adapter() private view {
    if (IHarborAdapter(ADAPTER).BASE() != WSTETH || IHarborClaimExporter(ADAPTER).ISSUER() != QUEUE) {
      revert InvalidConfiguration();
    }
  }

  /// @dev A queue NFT must back either the native adapter or a canonical receipt
  /// from a governance-admitted factory. The receipt holder may be an incoming
  /// trader; Book separately checks vault custody when aggregating held assets.
  function _backedOwner(uint256 id, address owner) private view returns (bool) {
    if (owner == ADAPTER) return true;
    if (owner.code.length == 0) return false;
    try IHarborClaim(owner).FACTORY() returns (address factory) {
      ILidoValuationBook b = ILidoValuationBook(IHarborAdapter(ADAPTER).BOOK());
      ClaimMarkets.Integration memory i = b.claimIntegration(factory);
      if ((!i.enabled && !i.retired) || b.route(i.sourceRoute).adapter != ADAPTER) return false;
      IHarborClaimFactory f = IHarborClaimFactory(factory);
      return f.ISSUER() == QUEUE && f.isReceipt(owner) && f.receiptOf(id) == owner;
    } catch {
      return false;
    }
  }
}
