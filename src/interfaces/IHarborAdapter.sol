// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

/// @notice Fixed-beneficiary issuer boundary. All amounts are raw token units.
interface IHarborAdapter {
  struct Request {
    uint256 id;
    uint256 shares; // Wrapped inventory actually consumed for this right.
    uint256 entitlement; // Underlying ETH wei, not cash or a guaranteed recovery.
  }

  function BOOK() external view returns (address);
  function VAULT() external view returns (address);
  function BASE() external view returns (address);
  function WETH() external view returns (address);

  /// @dev Book supplies its measured balance immediately before the typed transfer.
  function request(uint256[] calldata amounts, uint256 previousBalance) external returns (Request[] memory requests);

  /// @dev One right per call permits unambiguous receipt attribution. Book batches.
  function claim(uint256 id, uint256 hint) external returns (uint256 cash, uint256 remaining);
}
