// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Operation} from "src/types/HarborTypes.sol";
import {BookState} from "src/book/base/BookState.sol";

/// @title BookGovernance
/// @notice Bounded governance and emergency stops for one immutable Book mandate.
/// @dev Stopping trading invalidates quotes and fresh NAV, not funded LP claims.
/// Updater/resume changes are delayed; keeper revocation does not block recovery.
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
    ++configVersion;
    VAULT.invalidateValuation();
    emit TradingStopped(configVersion);
  }

  /// @notice Schedule a publisher replacement after GOVERNANCE_DELAY.
  /// @param updater New parameter publisher, without valuation or treasury authority.
  function scheduleUpdater(address updater) external {
    _governance();
    if (updater == address(0)) revert InvalidConfiguration();
    pendingUpdater = updater;
    updaterReadyAt = block.timestamp + GOVERNANCE_DELAY;
    emit UpdaterScheduled(updater, updaterReadyAt);
  }

  /// @notice Immediately revoke publication and invalidate standing observations.
  /// @dev Recovery and funded LP claims stay available. Re-enabling requires a delayed rotation.
  function revokeUpdater() external {
    if (msg.sender != GOVERNOR && msg.sender != GUARDIAN) revert Unauthorized();
    if (_operation != Operation.NONE) revert Busy();
    parameterUpdater = address(0);
    pendingUpdater = address(0);
    updaterReadyAt = 0;
    emit UpdaterChanged(address(0), ++configVersion);
  }

  /// @notice Permissionlessly apply a matured updater replacement while idle.
  /// @dev Advancing configVersion invalidates prior quotes; consumed nonces persist.
  function applyUpdater() external {
    if (_operation != Operation.NONE) revert Busy();
    if (updaterReadyAt == 0 || block.timestamp < updaterReadyAt) revert Unauthorized();
    parameterUpdater = pendingUpdater;
    pendingUpdater = address(0);
    updaterReadyAt = 0;
    ++configVersion;
    emit UpdaterChanged(parameterUpdater, configVersion);
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
    ++configVersion;
    emit TradingResumed(configVersion);
  }

  /// @dev Require the governor and an idle shared operation context.
  function _governance() private view {
    if (msg.sender != GOVERNOR) revert Unauthorized();
    if (_operation != Operation.NONE) revert Busy();
  }
}
