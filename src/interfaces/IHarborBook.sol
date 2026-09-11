// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {ISwapVM} from "@1inch/swap-vm/src/interfaces/ISwapVM.sol";
import {Trade, FillAmounts, RouteConfig} from "src/types/HarborTypes.sol";

/// @title IHarborBook
/// @notice Vault-facing authority and public-valuation boundary.
interface IHarborBook {
  function MAX_MARK_AGE() external view returns (uint256);
  function route(uint256 id) external view returns (RouteConfig memory);
  /// @notice Public observation for exact inventory units or a whole canonical receipt.
  function observation(uint256 id, uint256 quantity)
    external
    view
    returns (uint256 entitlement, uint256 mark, uint256 observedAt, uint256 policy, bytes32 hash, bool valid);
  function AQUA() external view returns (address);
  function ROUTER() external view returns (address);
  function hasManagedPositions() external view returns (bool);
  function redemptionTransfer(bytes32 context)
    external
    view
    returns (address base, address adapter, uint256 amount, uint256 managed);
  /// @notice Acquire Book/Vault transaction context before the executor collects input.
  /// @param trade Authenticated intent. Only lock here; Extruction computes the price.
  function prepareTrade(Trade calldata trade) external;
  /// @notice Reconcile treasury cash after all router hooks and executor payouts.
  /// @param tradeHash Trader-intent identity recorded in the active context.
  /// @return fee Actual protocol fee reported by the canonical VM's transfer hooks, settlement-asset raw units.
  function finishTrade(bytes32 tradeHash) external returns (uint256 fee);
  /// @notice Idle-state live pricing with independent valuation and capacity checks.
  /// @param trade Trader intent; limits and specified amount are raw token units.
  function quote(Trade calldata trade) external view returns (FillAmounts memory);
  function currentOrder(uint256 route) external view returns (ISwapVM.Order memory);
  function FEE_RECIPIENT() external view returns (address);
  function FEE_BPS() external view returns (uint256);
  /// @notice Used by the independently authorized valuation publisher to avoid mid-settlement changes.
  function isIdle() external view returns (bool);
  /// @notice Exact adapter/claim mutation admitted by Book's current RECOVERY context.
  function claimOperationAllowed(address adapter, bytes32 id) external view returns (bool);
  /// @notice Prepare a fresh program for publication by the vault itself.
  /// @param route Approved token/adapter route.
  /// @param requester Original caller forwarded by the vault; must be governor.
  /// @return order Canonical maker order for HarborSwapVMRouter.
  /// @return previous Retired strategy hash to dock, or zero for first publication.
  /// @return base Approved wrapped inventory token.
  /// @return managed Current managed base inventory in raw token units.
  function prepareStrategyFromVault(uint256 route, address requester)
    external
    returns (ISwapVM.Order memory order, bytes32 previous, address base, uint256 managed);
  /// @notice Acquire Book then Vault context for a vault-originated operation.
  function beginVaultOperation(bytes32 context) external;
  /// @notice Release Vault then Book context after the vault commits accounting.
  function finishVaultOperation(bytes32 context) external;
  /// @notice Public marks in settlement-asset raw units; this must not be a private quote report.
  /// @return inventory Managed inventory value.
  /// @return claims Remaining issuer rights value.
  /// @return observedAt Oldest observation timestamp in Unix seconds.
  /// @return evidence Commitment to the live inventory and owned-claim observations.
  /// @return valid Whether observations are valid and Book is not stopped; callers separately enforce age.
  function valuation()
    external
    view
    returns (uint256 inventory, uint256 claims, uint256 observedAt, bytes32 evidence, bool valid);
}
