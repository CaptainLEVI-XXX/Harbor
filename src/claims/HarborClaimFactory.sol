// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {LibClone} from "solady/utils/LibClone.sol";
import {ReentrancyGuardTransient} from "solady/utils/ReentrancyGuardTransient.sol";
import {HarborClaimReceipt} from "src/claims/HarborClaimReceipt.sol";
import {IHarborClaimAdapter} from "src/interfaces/IHarborClaimAdapter.sol";
import {ClaimImport} from "src/types/ClaimTypes.sol";

/// @title HarborClaimFactory
/// @notice Shared canonical ERC-20 receipts for individually approved custody adapters.
/// @dev Admission permits wrapping, not pool exposure. Retirement never blocks payouts.
contract HarborClaimFactory is ReentrancyGuardTransient {
  struct Admission {
    uint64 readyAt; // Unix seconds; zero when not scheduled.
    bool enabled;
    bool retired;
    uint256 version; // Bound by canonical receipt trading programs.
  }
  address public immutable GOVERNOR;
  address public immutable ASSET;
  address public immutable IMPLEMENTATION;
  uint256 public immutable GOVERNANCE_DELAY;
  mapping(address => Admission) public admissions;
  /// @notice Permanent adapter/claim binding, including after final payout.
  mapping(address => mapping(bytes32 => address)) public receiptOf;
  mapping(address => bool) public isReceipt;

  error Unauthorized();
  error InvalidConfiguration();
  error InvalidImport();
  event AdapterScheduled(address indexed adapter, uint256 readyAt);
  event AdapterAdmission(address indexed adapter, bool enabled, uint256 version);
  event ClaimWrapped(
    address indexed adapter, bytes32 indexed claimId, address indexed receipt, address owner, address receiver
  );

  constructor(address cashAsset, address governor, uint256 delay) {
    if (
      cashAsset.code.length == 0 || governor == address(0)
        || (delay < 1 days && !(block.chainid == 560048 && delay == 0)) || delay > 30 days
    ) {
      revert InvalidConfiguration();
    }
    ASSET = cashAsset;
    GOVERNOR = governor;
    GOVERNANCE_DELAY = delay;
    IMPLEMENTATION = address(new HarborClaimReceipt(cashAsset));
  }

  function active(address adapter) public view returns (bool) {
    return admissions[adapter].enabled;
  }

  function version(address adapter) external view returns (uint256) {
    return admissions[adapter].version;
  }

  /// @notice Governor proposes reciprocal factory/ASSET bindings; activation remains explicit.
  /// @dev Controlled Hoodi demo admissions have no waiting period. Other chains retain the configured delay.
  function schedule(address adapter) external {
    if (msg.sender != GOVERNOR) revert Unauthorized();
    Admission storage a = admissions[adapter];
    if (
      a.retired || a.enabled || a.readyAt != 0 || IHarborClaimAdapter(adapter).FACTORY() != address(this)
        || IHarborClaimAdapter(adapter).ASSET() != ASSET
    ) revert InvalidConfiguration();
    uint256 readyAt = block.timestamp + (block.chainid == 560048 ? 0 : GOVERNANCE_DELAY);
    if (readyAt > type(uint64).max) revert InvalidConfiguration();
    a.readyAt = uint64(readyAt);
    emit AdapterScheduled(adapter, a.readyAt);
  }

  /// @notice Anyone may apply a matured admission; retired adapters cannot return.
  function activate(address adapter) external {
    Admission storage a = admissions[adapter];
    if (a.retired || a.enabled || a.readyAt == 0 || block.timestamp < a.readyAt) revert InvalidConfiguration();
    a.readyAt = 0;
    a.enabled = true;
    emit AdapterAdmission(adapter, true, ++a.version);
  }

  /// @notice Governor permanently stops new wrapping without touching existing payouts.
  function retire(address adapter) external {
    if (msg.sender != GOVERNOR) revert Unauthorized();
    Admission storage a = admissions[adapter];
    if (a.retired) revert InvalidConfiguration();
    a.enabled = false;
    a.retired = true;
    a.readyAt = 0;
    emit AdapterAdmission(adapter, false, ++a.version);
  }

  /// @notice Atomically import caller-owned collateral and mint its one canonical unit.
  /// @param adapter Individually admitted custody implementation.
  /// @param input Typed collateral descriptor; the adapter verifies actual ownership/backing.
  /// @param receiver Owner of the newly issued unit.
  /// @return receipt Generic ERC-20 clone; raw supply is exactly one.
  function wrap(address adapter, ClaimImport calldata input, address receiver)
    external
    nonReentrant
    returns (address receipt)
  {
    bytes32 id = IHarborClaimAdapter(adapter).claimId(input);
    receipt = _create(adapter, id, receiver);
    (bytes32 actualId, uint256 nominal) = IHarborClaimAdapter(adapter).importClaim(msg.sender, input, receipt);
    if (actualId != id || nominal == 0) revert InvalidImport();
    HarborClaimReceipt(receipt).activate(receiver);
    emit ClaimWrapped(adapter, id, receipt, msg.sender, receiver);
  }

  /// @notice The adapter has already changed the native right's ownership domain.
  function exportClaim(bytes32 id, address receiver) external nonReentrant returns (address receipt) {
    receipt = _create(msg.sender, id, receiver);
    HarborClaimReceipt(receipt).activate(receiver);
    emit ClaimWrapped(msg.sender, id, receipt, msg.sender, receiver);
  }

  function _create(address adapter, bytes32 id, address receiver) private returns (address receipt) {
    if (!active(adapter) || id == bytes32(0) || receiver == address(0) || receiptOf[adapter][id] != address(0)) {
      revert InvalidImport();
    }
    // Fixed-width immutable payload: adapter [0..19], claim ID [20..51].
    // Solady appends it to clone runtime, not delegatecall calldata.
    receipt =
      LibClone.cloneDeterministic(IMPLEMENTATION, abi.encodePacked(adapter, id), keccak256(abi.encode(adapter, id)));
    receiptOf[adapter][id] = receipt; // Before custody callbacks; mint remains deferred.
    isReceipt[receipt] = true;
  }

  function _useTransientReentrancyGuardOnlyOnMainnet() internal pure override returns (bool) {
    return false;
  }
}
