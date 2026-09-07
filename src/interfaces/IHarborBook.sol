// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {ISwapVM} from "@1inch/swap-vm/src/interfaces/ISwapVM.sol";
import {Trade, FillTerms} from "src/types/HarborTypes.sol";

/// @title IHarborBook
/// @notice Vault-facing authority and public-valuation boundary.
interface IHarborBook {
  function AQUA() external view returns (address);
  function ROUTER() external view returns (address);
  function hasManagedPositions() external view returns (bool);
  function beginTrade(bytes32 tradeHash) external;
  function finishTrade(bytes32 fillDigest) external;
  function validate(Trade calldata trade, FillTerms calldata terms, bytes calldata signature)
    external
    view
    returns (bytes32);
  function prepareStrategyFromVault(uint256 route, address requester)
    external
    returns (ISwapVM.Order memory order, bytes32 previous, address base, uint256 managed);
  /// @notice Acquire Book then Vault context for a vault-originated operation.
  function beginVaultOperation(bytes32 context) external;
  /// @notice Release Vault then Book context after the vault commits accounting.
  function finishVaultOperation(bytes32 context) external;
  /// @notice Public marks in WETH wei; this must not be a private quote report.
  /// @return inventory Managed inventory value.
  /// @return claims Remaining issuer rights value.
  /// @return observedAt Oldest observation timestamp in Unix seconds.
  /// @return policyVersion Public valuation policy version.
  /// @return valid Whether the mark and real-capital launch gate are valid.
  function valuation()
    external
    view
    returns (uint256 inventory, uint256 claims, uint256 observedAt, uint256 policyVersion, bool valid);
}
