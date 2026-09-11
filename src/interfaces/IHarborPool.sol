// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

/// @notice Immutable pool bindings inspected during shared-executor admission.
/// @dev Getters alone do not prove implementation safety; only reviewed pools are admitted.
interface IHarborPool {
  function VAULT() external view returns (address);
  function EXECUTOR() external view returns (address);
  function ROUTER() external view returns (address);
  function AQUA() external view returns (address);
  function ASSET() external view returns (address);
}
