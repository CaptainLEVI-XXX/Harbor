// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {ReentrancyGuardTransient} from "solady/utils/ReentrancyGuardTransient.sol";
import {SafeTransferLib as SafeTransfer} from "solady/utils/SafeTransferLib.sol";
import {IWETH} from "@1inch/solidity-utils/contracts/interfaces/IWETH.sol";
import {IHarborAdapter} from "src/interfaces/IHarborAdapter.sol";

/// @notice Shared immutable authority and measured ETH-to-vault settlement.
/// @dev No sweep, approvals to keepers, arbitrary target, or beneficiary setter.
abstract contract AdapterBase is IHarborAdapter, ReentrancyGuardTransient {
  address public immutable BOOK;
  address public immutable VAULT;
  address public immutable BASE;
  address public immutable WETH;
  address public immutable ISSUER;
  bool internal transient _receiving;
  uint256 internal transient _received;

  error Unauthorized();
  error InvalidConfiguration();
  error InvalidRequest();
  error ReceiptMismatch();

  constructor(address book, address vault, address base, address weth, address issuer) {
    if (
      book == address(0) || vault == address(0) || book == vault || base.code.length == 0 || weth.code.length == 0
        || base == weth || issuer.code.length == 0
    ) revert InvalidConfiguration();
    BOOK = book;
    VAULT = vault;
    BASE = base;
    WETH = weth;
    ISSUER = issuer;
  }

  modifier onlyBook() {
    if (msg.sender != BOOK) revert Unauthorized();
    _;
  }

  receive() external payable {
    if (msg.sender != ISSUER || !_receiving) revert Unauthorized();
    _received += msg.value;
  }

  /// @dev Only ETH received through the active issuer callback becomes managed WETH.
  /// Forced ETH and pre-existing WETH remain excluded even during the issuer call.
  function _payVault(uint256 expected) internal returns (uint256 cash) {
    _receiving = false;
    cash = _received;
    _received = 0;
    if (cash != expected) revert ReceiptMismatch();
    if (cash == 0) return 0;
    uint256 adapterBefore = SafeTransfer.balanceOf(WETH, address(this));
    uint256 vaultBefore = SafeTransfer.balanceOf(WETH, VAULT);
    IWETH(WETH).deposit{value: cash}();
    if (SafeTransfer.balanceOf(WETH, address(this)) != adapterBefore + cash) revert ReceiptMismatch();
    SafeTransfer.safeTransfer(WETH, VAULT, cash);
    if (
      SafeTransfer.balanceOf(WETH, address(this)) != adapterBefore
        || SafeTransfer.balanceOf(WETH, VAULT) != vaultBefore + cash
    ) revert ReceiptMismatch();
  }

  function _useTransientReentrancyGuardOnlyOnMainnet() internal pure override returns (bool) {
    return false;
  }
}
