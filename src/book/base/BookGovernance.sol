// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Operation} from "src/types/HarborTypes.sol";
import {BookState} from "src/book/base/BookState.sol";

/// @title BookGovernance
/// @notice Bounded governance and emergency stops for one immutable Book mandate.
/// @dev Stopping trading invalidates quotes and fresh NAV, not funded LP claims.
/// Signer/resume changes are delayed; keeper revocation does not block recovery.
abstract contract BookGovernance is BookState {
  /// @notice Irreversibly revoke new keeper requests; existing recovery stays open.
  function revokeKeeper() external {
    if (msg.sender != GOVERNOR && msg.sender != GUARDIAN) revert Unauthorized();
    if (_operation != Operation.NONE) revert Busy();
    _redemptions.revoked = true;
    emit KeeperRevoked(++_redemptions.epoch);
  }

  /// @notice Immediately close trading and invalidate quotes and the cached mark.
  /// @dev Governor/guardian only, outside an active operation. Existing issuer
  /// recoveries and funded LP claims do not depend on this gate.
  function stopTrading() external {
    if (msg.sender != GUARDIAN && msg.sender != GOVERNOR) revert Unauthorized();
    if (_operation != Operation.NONE) revert Busy();
    stopped = true;
    resumeReadyAt = 0;
    ++quoteEpoch;
    VAULT.invalidateValuation();
    emit TradingStopped(quoteEpoch);
  }

  /// @notice Schedule a nonzero signer replacement after GOVERNANCE_DELAY.
  /// @param signer New quote signer; no other authority or policy changes.
  function scheduleSigner(address signer) external {
    _governance();
    if (signer == address(0)) revert InvalidConfiguration();
    pendingSigner = signer;
    signerReadyAt = block.timestamp + GOVERNANCE_DELAY;
    emit SignerScheduled(signer, signerReadyAt);
  }

  /// @notice Permissionlessly apply a matured signer replacement while idle.
  /// @dev Advancing quoteEpoch invalidates prior quotes; consumed nonces persist.
  function applySigner() external {
    if (_operation != Operation.NONE) revert Busy();
    if (signerReadyAt == 0 || block.timestamp < signerReadyAt) revert Unauthorized();
    quoteSigner = pendingSigner;
    pendingSigner = address(0);
    signerReadyAt = 0;
    ++quoteEpoch;
    emit SignerChanged(quoteSigner, quoteEpoch);
  }

  /// @notice Governor schedules resumption of an already stopped Book.
  /// @dev Requires an idle operation; a subsequent stop cancels this schedule.
  function scheduleResume() external {
    _governance();
    if (!stopped) revert InvalidConfiguration();
    resumeReadyAt = block.timestamp + GOVERNANCE_DELAY;
    emit ResumeScheduled(resumeReadyAt);
  }

  /// @notice Permissionlessly apply matured resumption while idle.
  /// @dev Does not refresh NAV or reopen deposits without a new public mark.
  function resumeTrading() external {
    if (_operation != Operation.NONE) revert Busy();
    if (resumeReadyAt == 0 || block.timestamp < resumeReadyAt) revert Unauthorized();
    resumeReadyAt = 0;
    stopped = false;
    ++quoteEpoch;
    emit TradingResumed(quoteEpoch);
  }

  /// @dev Require the governor and an idle shared operation context.
  function _governance() private view {
    if (msg.sender != GOVERNOR) revert Unauthorized();
    if (_operation != Operation.NONE) revert Busy();
  }
}
