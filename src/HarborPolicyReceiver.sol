// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {IReceiver} from "@chainlink/evm/contracts/cre/src/v1/interfaces/IReceiver.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IHarborPolicyReceiver} from "src/interfaces/IHarborPolicyReceiver.sol";

/// @title HarborPolicyReceiver
/// @notice Authenticated, expiring approvals for exact fills, without treasury authority.
/// @dev No token callouts or callbacks: report handling needs no transient guard.
/// Workflow, domain, model and policy are immutable. Cancellation only advances epoch.
contract HarborPolicyReceiver is IReceiver, IHarborPolicyReceiver {
  struct Config {
    address forwarder;
    address book;
    address vault;
    address governor;
    address guardian;
    bytes32 workflowId;
    bytes10 workflowName; // Already encoded upstream identity, not a human-readable cast.
    address workflowOwner;
    uint64 chainSelector; // Chainlink selector, distinct from EVM chain ID.
    uint256 policyVersion;
    bytes32 modelHash; // Public algorithm/build identity, never a bare private-parameter hash.
    uint256 maxLifetime; // Seconds; also bounds age, with zero future-clock tolerance.
  }

  /// @notice Fixed-width canonical ABI report. Times are Unix seconds.
  struct Report {
    uint256 schemaVersion;
    uint256 targetChainId;
    uint64 targetChainSelector;
    address receiver;
    address book;
    address vault;
    bytes32 finalFillDigest;
    uint256 authorizationEpoch;
    uint256 authorizationNonce;
    uint256 policyVersion;
    bytes32 modelHash;
    bytes32 publicObservationHash;
    uint256 observedAt;
    uint256 validUntil;
    uint256 decision; // 1 = APPROVE. Denials create no onchain permit.
  }

  struct Permit {
    bytes32 reportHash;
    uint256 epoch;
    uint256 validUntil;
  }

  address public immutable FORWARDER;
  address public immutable BOOK;
  address public immutable VAULT;
  address public immutable GOVERNOR;
  address public immutable GUARDIAN;
  bytes32 public immutable WORKFLOW_ID;
  bytes10 public immutable WORKFLOW_NAME;
  address public immutable WORKFLOW_OWNER;
  uint256 public immutable CHAIN_ID;
  uint64 public immutable CHAIN_SELECTOR;
  uint256 public immutable POLICY_VERSION;
  bytes32 public immutable MODEL_HASH;
  uint256 public immutable MAX_LIFETIME;

  uint256 public authorizationEpoch;
  mapping(uint256 => mapping(uint256 => bytes32)) public reportHashByNonce;
  mapping(bytes32 => Permit) public permits;

  error InvalidConfiguration();
  error Unauthorized();
  error InvalidMetadata();
  error InvalidReport();
  error ConflictingReport();

  event PermitApproved(
    bytes32 indexed digest,
    uint256 indexed epoch,
    uint256 indexed nonce,
    uint256 validUntil,
    bytes32 publicObservationHash,
    bytes2 reportId
  );
  event PermitsCancelled(uint256 epoch);

  constructor(Config memory c) {
    if (
      c.forwarder.code.length == 0 || c.book == address(0) || c.vault == address(0) || c.book == c.vault
        || c.governor == address(0) || c.guardian == address(0) || c.workflowId == 0 || c.workflowName == 0
        || c.workflowOwner == address(0) || c.chainSelector == 0 || c.policyVersion == 0 || c.modelHash == 0
        || c.maxLifetime == 0 || c.maxLifetime > 1 days
    ) revert InvalidConfiguration();
    FORWARDER = c.forwarder;
    BOOK = c.book;
    VAULT = c.vault;
    GOVERNOR = c.governor;
    GUARDIAN = c.guardian;
    WORKFLOW_ID = c.workflowId;
    WORKFLOW_NAME = c.workflowName;
    WORKFLOW_OWNER = c.workflowOwner;
    CHAIN_ID = block.chainid;
    CHAIN_SELECTOR = c.chainSelector;
    POLICY_VERSION = c.policyVersion;
    MODEL_HASH = c.modelHash;
    MAX_LIFETIME = c.maxLifetime;
  }

  function supportsInterface(bytes4 id) external pure returns (bool) {
    return id == type(IReceiver).interfaceId || id == type(IERC165).interfaceId;
  }

  function onReport(bytes calldata metadata, bytes calldata encoded) external {
    if (msg.sender != FORWARDER) revert Unauthorized();
    // Upstream forwards 64 bytes: 32 + 10 + 20 identity bytes, then bytes2 reportId.
    if (
      metadata.length != 64 || bytes32(metadata[:32]) != WORKFLOW_ID || bytes10(metadata[32:42]) != WORKFLOW_NAME
        || address(bytes20(metadata[42:62])) != WORKFLOW_OWNER
    ) {
      revert InvalidMetadata();
    }
    if (encoded.length != 15 * 32) revert InvalidReport();
    Report memory r = abi.decode(encoded, (Report));
    if (
      r.schemaVersion != 1 || r.targetChainId != CHAIN_ID || block.chainid != CHAIN_ID
        || r.targetChainSelector != CHAIN_SELECTOR || r.receiver != address(this) || r.book != BOOK || r.vault != VAULT
        || r.finalFillDigest == 0 || r.authorizationEpoch != authorizationEpoch || r.policyVersion != POLICY_VERSION
        || r.modelHash != MODEL_HASH || r.publicObservationHash == 0 || r.decision != 1 || r.observedAt == 0
        || r.observedAt > block.timestamp || r.validUntil < block.timestamp || r.validUntil < r.observedAt
        || r.validUntil - r.observedAt > MAX_LIFETIME
    ) revert InvalidReport();
    bytes32 hash = keccak256(encoded);
    bytes32 previous = reportHashByNonce[r.authorizationEpoch][r.authorizationNonce];
    if (previous != 0) {
      if (previous != hash) revert ConflictingReport();
      return; // No write, duplicate event, or lifetime extension.
    }
    // Changing only the report nonce cannot extend or replace a digest's permit.
    if (permits[r.finalFillDigest].reportHash != 0) revert ConflictingReport();
    reportHashByNonce[r.authorizationEpoch][r.authorizationNonce] = hash;
    permits[r.finalFillDigest] = Permit(hash, r.authorizationEpoch, r.validUntil);
    emit PermitApproved(
      r.finalFillDigest,
      r.authorizationEpoch,
      r.authorizationNonce,
      r.validUntil,
      r.publicObservationHash,
      bytes2(metadata[62:64])
    );
  }

  function isApproved(bytes32 digest) external view returns (bool) {
    Permit storage p = permits[digest];
    return
      block.chainid == CHAIN_ID && p.reportHash != 0 && p.epoch == authorizationEpoch && block.timestamp <= p.validUntil;
  }

  /// @notice Cancel outstanding approvals without altering funds, shares or claims.
  /// @dev Workflow must observe the new epoch; cancelled digests cannot be revived.
  function cancelPermits() external {
    if (msg.sender != GOVERNOR && msg.sender != GUARDIAN) revert Unauthorized();
    emit PermitsCancelled(++authorizationEpoch);
  }
}
