// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {ISwapVM} from "@1inch/swap-vm/src/interfaces/ISwapVM.sol";
import {Trade, FillTerms, RouteConfig} from "src/types/HarborTypes.sol";
import {IHarborPolicyReceiver} from "src/interfaces/IHarborPolicyReceiver.sol";
import {IHarborValuation} from "src/interfaces/IHarborValuation.sol";

/// @title IHarborBook
/// @notice Vault-facing authority and public-valuation boundary.
interface IHarborBook {
  function RECEIVER() external view returns (IHarborPolicyReceiver);
  function VALUATION() external view returns (IHarborValuation);
  function MAX_MARK_AGE() external view returns (uint256);
  function route(uint256 id) external view returns (RouteConfig memory);
  function AQUA() external view returns (address);
  function ROUTER() external view returns (address);
  function hasManagedPositions() external view returns (bool);
  function redemptionTransfer(bytes32 context)
    external
    view
    returns (address base, address adapter, uint256 amount, uint256 managed);
  /// @notice Acquire Book/Vault transaction context before the executor collects input.
  /// @param tradeHash Exact trader-intent hash; does not itself authorize a price.
  function beginTrade(bytes32 tradeHash) external;
  /// @notice Reconcile treasury cash after all router hooks and executor payouts.
  /// @param fillDigest Authorized fill identity recorded in the active context.
  function finishTrade(bytes32 fillDigest) external;
  /// @notice Idle-state preflight of exact-fill authority and portfolio capacity.
  /// @param trade Trader intent; limits and specified amount are raw token units.
  /// @param terms Exact pair, fee, observations and settlement authority bindings.
  /// @param signature Signature by the configured quote signer.
  /// @return Domain-separated fill digest; no capital is reserved by this view.
  function validate(Trade calldata trade, FillTerms calldata terms, bytes calldata signature)
    external
    view
    returns (bytes32);
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
