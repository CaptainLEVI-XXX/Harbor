// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {ERC20} from "solady/tokens/ERC20.sol";
import {ReentrancyGuardTransient} from "solady/utils/ReentrancyGuardTransient.sol";
import {IHarborClaim} from "src/interfaces/IHarborClaim.sol";
import {IHarborClaimAdapter} from "src/interfaces/IHarborClaimAdapter.sol";
import {ClaimObservation, ClaimDomain} from "src/types/ClaimTypes.sol";

/// @title HarborClaimReceipt
/// @notice One indivisible ERC-20 unit owns one adapter-custodied redemption right.
/// @dev Non-upgradeable clones. No issuer code, custody, estimate publisher or admin payout.
contract HarborClaimReceipt is ERC20, ReentrancyGuardTransient {
  address public immutable FACTORY;
  address public immutable ASSET;
  uint256 public immutable CHAIN_ID;
  address public ADAPTER;
  bytes32 public CLAIM_ID;
  bool private _activated;
  bool private transient _burning;

  error Unauthorized();
  error InvalidState();
  error InvalidRecipient();
  event Activated(bytes32 indexed claimId, address indexed adapter, address indexed owner, uint256 nominal);
  event Redeemed(address indexed holder, address indexed receiver, uint256 cash);

  constructor(address cashAsset) {
    FACTORY = msg.sender;
    ASSET = cashAsset;
    CHAIN_ID = block.chainid;
    _activated = true; // Lock the implementation; clones start with empty storage.
  }

  /// @notice Factory-only, write-once binding before collateral verification and mint.
  function initialize(address adapter, bytes32 id) external {
    if (msg.sender != FACTORY) revert Unauthorized();
    if (_activated || ADAPTER != address(0) || adapter == address(0) || id == bytes32(0)) revert InvalidState();
    ADAPTER = adapter;
    CLAIM_ID = id;
  }

  /// @notice Factory-only mint after the adapter proves a positive tokenized right.
  /// @dev Issuer-specific import/status admission remains the adapter's responsibility.
  function activate(address receiver) external {
    if (msg.sender != FACTORY) revert Unauthorized();
    if (_activated || receiver == address(0) || receiver == address(this)) revert InvalidState();
    ClaimObservation memory o = IHarborClaimAdapter(ADAPTER).claimState(CLAIM_ID);
    if (
      o.domain != ClaimDomain.TOKENIZED
        || (o.status != IHarborClaim.Status.PENDING && o.status != IHarborClaim.Status.FINALIZED) || o.entitlement == 0
    ) revert InvalidState();
    _activated = true;
    _mint(receiver, 1);
    emit Activated(CLAIM_ID, ADAPTER, receiver, o.entitlement);
  }

  function name() public pure override returns (string memory) {
    return "Harbor Redemption Claim";
  }

  function symbol() public pure override returns (string memory) {
    return "hCLAIM";
  }

  function decimals() public pure override returns (uint8) {
    return 0;
  }

  function status() public view returns (IHarborClaim.Status) {
    if (!_activated || ADAPTER == address(0)) return IHarborClaim.Status.UNINITIALIZED;
    return IHarborClaimAdapter(ADAPTER).claimState(CLAIM_ID).status;
  }

  /// @notice Verified nominal settlement-token units, not guaranteed cash or a price.
  function entitlement() external view returns (uint256) {
    return IHarborClaimAdapter(ADAPTER).claimState(CLAIM_ID).entitlement;
  }

  /// @notice This claim's unpaid adapter credit, in settlement-token raw units.
  function recovered() external view returns (uint256) {
    return IHarborClaimAdapter(ADAPTER).claimState(CLAIM_ID).cash;
  }

  /// @notice Anyone can collect issuer cash; the caller cannot select its owner.
  function recover(bytes calldata data) external nonReentrant returns (uint256) {
    return IHarborClaimAdapter(ADAPTER).recoverTokenized(CLAIM_ID, data);
  }

  /// @notice Burn and pay atomically. An allowance never authorizes a holder payout.
  function redeem(address receiver) external nonReentrant returns (uint256 cash) {
    if (balanceOf(msg.sender) != 1 || status() != IHarborClaim.Status.CASH_READY) revert InvalidState();
    if (receiver == address(0) || receiver == address(this) || receiver == ADAPTER) revert InvalidRecipient();
    _burning = true;
    _burn(msg.sender, 1);
    _burning = false;
    cash = IHarborClaimAdapter(ADAPTER).redeemTokenized(CLAIM_ID, receiver);
    emit Redeemed(msg.sender, receiver, cash);
  }

  function _beforeTokenTransfer(address from, address to, uint256) internal view override {
    if (to == address(this)) revert InvalidRecipient();
    if (to == address(0)) {
      if (!_burning) revert InvalidState();
    } else if (from != address(0)) {
      _idleTransfer();
      if (IHarborClaimAdapter(ADAPTER).claimBusy(CLAIM_ID)) revert InvalidState();
    }
  }
  function _idleTransfer() private view nonReadReentrant {}

  function _useTransientReentrancyGuardOnlyOnMainnet() internal pure override returns (bool) {
    return false;
  }

  function _givePermit2InfiniteAllowance() internal pure override returns (bool) {
    return false;
  }
}
