// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {SafeTransferLib as SafeTransfer} from "solady/utils/SafeTransferLib.sol";
import {Operation} from "src/types/HarborTypes.sol";
import {IAqua} from "@1inch/aqua/src/interfaces/IAqua.sol";
import {ISwapVM} from "@1inch/swap-vm/src/interfaces/ISwapVM.sol";
import {VaultAccounting as Accounting} from "src/libraries/VaultAccounting.sol";
import {VaultState} from "src/vault/base/VaultState.sol";

/// @title VaultSettlement
/// @notice Book-only treasury transitions and vault-owned Aqua strategy publication.
/// @dev This abstract module is part of the vault, not an intermediate custodian.
/// Exact measured deltas are committed before Book releases the shared context.
abstract contract VaultSettlement is VaultState {
  using Accounting for Accounting.State;

  /// @notice Book-only callback; context remains locked after this method returns.
  /// @param context Nonzero operation identity held across callback returns.
  /// @param operation Treasury domain authorized by the immutable Book.
  function beginBookOperation(bytes32 context, Operation operation) external {
    if (msg.sender != address(BOOK)) revert Unauthorized();
    if (_context != 0) revert Busy();
    if (context == 0 || operation == Operation.NONE) revert InvalidContext();
    _context = context;
    _operation = operation;
    _cashAtBegin = SafeTransfer.balanceOf(WETH, address(this));
  }

  /// @notice Book-only matching release; no external calls between lock releases.
  /// @param context Exact identity supplied at acquisition; all transient fields clear.
  function finishBookOperation(bytes32 context) external {
    if (msg.sender != address(BOOK)) revert Unauthorized();
    if (_context == 0 || _context != context) revert InvalidContext();
    _context = 0;
    _operation = Operation.NONE;
    _cashAtBegin = 0;
    _redemptionTransferred = false;
  }

  /// @notice Exact approved inventory handoff; no general Book allowance exists.
  /// @param context Active issuer-request identity. Asset/amount/adapter come from Book.
  function transferForRedemption(bytes32 context) external {
    if (msg.sender != address(BOOK)) revert Unauthorized();
    if (_context != context || _operation != Operation.REDEMPTION || _redemptionTransferred) revert InvalidContext();
    (address base, address adapter, uint256 amount, uint256 managed) = BOOK.redemptionTransfer(context);
    uint256 beforeVault = SafeTransfer.balanceOf(base, address(this));
    uint256 beforeAdapter = SafeTransfer.balanceOf(base, adapter);
    if (amount == 0 || amount > managed || beforeVault < managed) revert InvalidAmount();
    _redemptionTransferred = true;
    SafeTransfer.safeTransfer(base, adapter, amount);
    if (
      SafeTransfer.balanceOf(base, address(this)) != beforeVault - amount
        || SafeTransfer.balanceOf(base, adapter) != beforeAdapter + amount
    ) revert AssetDeltaMismatch();
  }

  /// @notice Record verified issuer cash without requiring a functioning mark service.
  /// @param context Active request or recovery identity.
  /// @param cash Verified recovered WETH wei; zero for a completed inventory request.
  function settleIssuer(bytes32 context, uint256 cash) external {
    if (msg.sender != address(BOOK)) revert Unauthorized();
    if (
      _context != context
        || (_operation != Operation.RECOVERY
          && !(_operation == Operation.REDEMPTION && _redemptionTransferred && cash == 0))
    ) revert InvalidContext();
    if (SafeTransfer.balanceOf(WETH, address(this)) != _cashAtBegin + cash) revert AssetDeltaMismatch();
    if (cash != 0) _state.receiveCash(cash);
    else _state.invalidate();
    _operation = Operation.NONE;
  }

  /// @notice Commit only the verified WETH leg of a fully paid trade.
  /// @dev Only Book may call, while holding this exact trade context. Inventory
  /// belongs to Book; the prior NAV remains visible but invalid until checkpoint.
  /// @param context Active trader-intent identity.
  /// @param buyBase True when the vault bought base inventory and spent WETH.
  /// @param cashAmount Exact gross buy debit or net sell receipt, WETH wei.
  function settleTrade(bytes32 context, bool buyBase, uint256 cashAmount) external {
    if (msg.sender != address(BOOK)) revert Unauthorized();
    if (_context != context || _operation != Operation.TRADE) revert InvalidContext();
    uint256 expected = buyBase ? _cashAtBegin - cashAmount : _cashAtBegin + cashAmount;
    if (SafeTransfer.balanceOf(WETH, address(this)) != expected) revert AssetDeltaMismatch();
    if (buyBase) _state.spendCash(cashAmount, 0);
    else _state.receiveCash(cashAmount);
    // Prevent duplicate cash recording in the same operation.
    _operation = Operation.NONE;
  }

  /// @notice Book can close the issuance gate without changing NAV or LP credit.
  function invalidateValuation() external {
    if (msg.sender != address(BOOK)) revert Unauthorized();
    if (_context != 0) revert Busy();
    _state.invalidate();
  }

  /// @notice Current physically backed cash and withdrawal-priority capacity.
  /// @param buffer Additional cash floor in WETH wei.
  /// @return Spendable WETH wei after pending-withdrawal and physical-backing gates.
  function tradingCash(uint256 buffer) external view returns (uint256) {
    if (_state.withdrawals.totalPending != 0 || SafeTransfer.balanceOf(WETH, address(this)) < _state.cash) return 0;
    return _state.available(buffer);
  }

  /// @notice Identity of committed public marks, independent of the operation lock.
  /// @return policy Public valuation policy version.
  /// @return version Portfolio version at the committed mark.
  /// @return fresh Whether the committed mark meets the configured validity window.
  function valuationIdentity() external view returns (uint256 policy, uint256 version, bool fresh) {
    return (_state.policyVersion, _state.markedVersion, _state.fresh(MAX_MARK_AGE));
  }

  /// @notice Book uses this to invalidate quotes on material LP accounting changes.
  /// @return Commitment to tracked cash, NAV, supply, reserves, pending exits and mark identity.
  function portfolioHash() external view returns (bytes32) {
    return keccak256(
      abi.encode(
        _state.cash,
        _state.nav,
        _state.supply,
        _state.withdrawals.reserved,
        _state.withdrawals.totalPending,
        _state.observedAt,
        _state.policyVersion
      )
    );
  }

  /// @notice Publish/replace a canonical strategy from this vault's own address.
  /// @dev Book authenticates the original requester and keeps all route ledgers.
  /// @param route Fixed Book route to register or replace.
  /// @return hash Newly shipped Aqua order hash.
  /// @dev Aqua is approved for supported tokens; per-strategy allocation and live
  /// Book budgets, not the allowance value, bound each actual transfer.
  function refreshStrategy(uint256 route) external coordinated returns (bytes32 hash) {
    (ISwapVM.Order memory order, bytes32 previous, address base, uint256 managed) =
      BOOK.prepareStrategyFromVault(route, msg.sender);
    if (order.maker != address(this)) revert InvalidConfiguration();
    address aqua = BOOK.AQUA();
    address router = BOOK.ROUTER();
    address[] memory tokens = new address[](2);
    tokens[0] = WETH;
    tokens[1] = base;
    uint256[] memory allocations = new uint256[](2);
    _state.requireBacked(SafeTransfer.balanceOf(WETH, address(this)));
    if (SafeTransfer.balanceOf(base, address(this)) < managed) revert AssetDeltaMismatch();
    allocations[0] = _state.available(0);
    allocations[1] = managed;
    if (previous != 0) IAqua(aqua).dock(router, previous, tokens);
    // Aqua allowance is not the risk budget: its per-order counters and Book's
    // live managed-cash/inventory checks are. A bid must be able to sell newly
    // received inventory without a permission-changing refresh between fills.
    SafeTransfer.safeApprove(WETH, aqua, type(uint256).max);
    SafeTransfer.safeApprove(base, aqua, type(uint256).max);
    hash = IAqua(aqua).ship(router, abi.encode(order), tokens, allocations);
    if (hash != keccak256(abi.encode(order))) revert InvalidContext();
  }
}
