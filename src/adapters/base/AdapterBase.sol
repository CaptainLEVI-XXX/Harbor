// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {ReentrancyGuardTransient} from "solady/utils/ReentrancyGuardTransient.sol";
import {IHarborAdapter} from "src/interfaces/IHarborAdapter.sol";
import {IssuerClaimLedger} from "src/libraries/IssuerClaimLedger.sol";
import {IHarborBook} from "src/interfaces/IHarborBook.sol";

/// @notice Fixed custody authorities, claim-operation context and scoped issuer ETH receipts.
/// @dev No sweep, approvals to keepers, arbitrary target, or beneficiary setter.
abstract contract AdapterBase is IHarborAdapter, ReentrancyGuardTransient {
  address public immutable BOOK;
  address public immutable VAULT;
  address public immutable BASE;
  address public immutable ASSET;
  address public immutable ISSUER;
  address public immutable FACTORY;
  IssuerClaimLedger.State internal _claims;
  bytes32 internal transient _busyClaim;
  bool internal transient _receiving;
  uint256 internal transient _received;

  error Unauthorized();
  error InvalidConfiguration();
  error InvalidRequest();
  error ReceiptMismatch();

  constructor(address book, address vault, address base, address cashAsset, address issuer, address factory) {
    if (
      book == address(0) || vault == address(0) || book == vault || base.code.length == 0 || cashAsset.code.length == 0
        || base == cashAsset || issuer.code.length == 0 || factory.code.length == 0
    ) revert InvalidConfiguration();
    BOOK = book;
    VAULT = vault;
    BASE = base;
    ASSET = cashAsset;
    ISSUER = issuer;
    FACTORY = factory;
  }

  modifier onlyBook() {
    if (msg.sender != BOOK) revert Unauthorized();
    _;
  }

  /// @notice A receipt may not transfer while its adapter is collecting or paying it.
  function claimBusy(bytes32 id) external view returns (bool) {
    return _busyClaim == id && id != bytes32(0);
  }

  function totalClaimCash() external view returns (uint256) {
    return _claims.totalCash;
  }

  function _idle() internal view {
    if (!IHarborBook(BOOK).isIdle()) revert Unauthorized();
  }

  function _claimOperation(bytes32 id) internal view {
    if (!IHarborBook(BOOK).isIdle() && !IHarborBook(BOOK).claimOperationAllowed(address(this), id)) {
      revert Unauthorized();
    }
  }

  receive() external payable {
    if (msg.sender != ISSUER || !_receiving) revert Unauthorized();
    _received += msg.value;
  }

  function _useTransientReentrancyGuardOnlyOnMainnet() internal pure override returns (bool) {
    return false;
  }
}
