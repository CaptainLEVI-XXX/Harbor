// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {ERC20} from "solady/tokens/ERC20.sol";
import {ReentrancyGuardTransient} from "solady/utils/ReentrancyGuardTransient.sol";
import {IHarborClaim} from "src/interfaces/IHarborClaim.sol";
import {IHarborClaimAdapter} from "src/interfaces/IHarborClaimAdapter.sol";
import {ClaimObservation, ClaimDomain} from "src/types/ClaimTypes.sol";

/// @title HarborClaimReceipt
/// @notice One indivisible ERC-20 unit owns one adapter-custodied redemption right.
/// @dev Non-upgradeable Solady immutable-argument clones. Adapter/claim binding
/// lives in code; custody and attributable cash remain in the canonical adapter.
contract HarborClaimReceipt is ERC20, ReentrancyGuardTransient {
  address public immutable FACTORY;
  address public immutable ASSET;
  uint256 public immutable CHAIN_ID;
  address private immutable _IMPLEMENTATION;
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
    _IMPLEMENTATION = address(this);
    _activated = true; // Lock the implementation; clones start with empty storage.
  }

  /// @notice Fixed issuer adapter, encoded in this canonical clone's runtime.
  function ADAPTER() public view returns (address adapter) {
    (adapter,) = _binding();
  }

  /// @notice Fixed issuer-domain identity; the adapter retains its closed tombstone.
  function CLAIM_ID() public view returns (bytes32 id) {
    (, id) = _binding();
  }

  /// @notice Factory-only mint after the adapter proves a positive tokenized right.
  /// @dev Issuer-specific import/status admission remains the adapter's responsibility.
  function activate(address receiver) external {
    if (msg.sender != FACTORY) revert Unauthorized();
    if (_activated || receiver == address(0) || receiver == address(this)) revert InvalidState();
    (address adapter, bytes32 id) = _binding();
    ClaimObservation memory o = IHarborClaimAdapter(adapter).claimState(id);
    if (
      o.domain != ClaimDomain.TOKENIZED
        || (o.status != IHarborClaim.Status.PENDING && o.status != IHarborClaim.Status.FINALIZED) || o.entitlement == 0
    ) revert InvalidState();
    _activated = true;
    _mint(receiver, 1);
    emit Activated(id, adapter, receiver, o.entitlement);
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
    (address adapter, bytes32 id) = _binding();
    if (!_activated || adapter == address(0)) return IHarborClaim.Status.UNINITIALIZED;
    return IHarborClaimAdapter(adapter).claimState(id).status;
  }

  /// @notice Verified nominal settlement-token units, not guaranteed cash or a price.
  function entitlement() external view returns (uint256) {
    (address adapter, bytes32 id) = _binding();
    return IHarborClaimAdapter(adapter).claimState(id).entitlement;
  }

  /// @notice This claim's unpaid adapter credit, in settlement-token raw units.
  function recovered() external view returns (uint256) {
    (address adapter, bytes32 id) = _binding();
    return IHarborClaimAdapter(adapter).claimState(id).cash;
  }

  /// @notice Anyone can collect issuer cash; the caller cannot select its owner.
  function recover(bytes calldata data) external nonReentrant returns (uint256) {
    (address adapter, bytes32 id) = _binding();
    return IHarborClaimAdapter(adapter).recoverTokenized(id, data);
  }

  /// @notice Burn and pay atomically. An allowance never authorizes a holder payout.
  function redeem(address receiver) external nonReentrant returns (uint256 cash) {
    if (balanceOf(msg.sender) != 1 || status() != IHarborClaim.Status.CASH_READY) revert InvalidState();
    (address adapter, bytes32 id) = _binding();
    if (receiver == address(0) || receiver == address(this) || receiver == adapter) revert InvalidRecipient();
    _burning = true;
    _burn(msg.sender, 1);
    _burning = false;
    cash = IHarborClaimAdapter(adapter).redeemTokenized(id, receiver);
    emit Redeemed(msg.sender, receiver, cash);
  }

  function _beforeTokenTransfer(address from, address to, uint256) internal view override {
    if (to == address(this)) revert InvalidRecipient();
    if (to == address(0)) {
      if (!_burning) revert InvalidState();
    } else if (from != address(0)) {
      _idleTransfer();
      (address adapter, bytes32 id) = _binding();
      if (IHarborClaimAdapter(adapter).claimBusy(id)) revert InvalidState();
    }
  }
  function _idleTransfer() private view nonReadReentrant {}

  /// @dev Safety considerations: factory creates only the pinned Solady CWIA
  /// layout: 45 runtime bytes followed by address:20 + bytes32:32. It records
  /// canonicality before custody callbacks and alone may activate. Arbitrary
  /// clones are not trusted by the adapter/Book. Direct implementation getters
  /// preserve zero bindings. EXTCODECOPY writes only scratch [0..51]; the ID
  /// read [20..51] is fully initialized. No allocation, free-pointer/zero-word
  /// mutation, storage access or arithmetic overflow. Calldata is irrelevant.
  function _binding() private view returns (address adapter, bytes32 id) {
    if (address(this) == _IMPLEMENTATION) return (address(0), bytes32(0));
    assembly ("memory-safe") {
      extcodecopy(address(), 0, 45, 52)
      adapter := shr(96, mload(0))
      id := mload(20)
    }
  }

  function _useTransientReentrancyGuardOnlyOnMainnet() internal pure override returns (bool) {
    return false;
  }

  function _givePermit2InfiniteAllowance() internal pure override returns (bool) {
    return false;
  }
}
