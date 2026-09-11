// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

/// @notice Minimal ABI for Lido's WithdrawalQueueERC721; no issuer implementation.
/// @dev Reviewed against lidofinance/core 17005714f151e5502c559932319a3f2f74ac2436,
/// contracts/0.8.9/WithdrawalQueue.sol (v4.0.0). Deployment verification is separate.
interface ILidoWithdrawalQueue {
  struct WithdrawalRequestStatus {
    uint256 amountOfStETH;
    uint256 amountOfShares;
    address owner;
    uint256 timestamp;
    bool isFinalized;
    bool isClaimed;
  }

  function WSTETH() external view returns (address);
  function MIN_STETH_WITHDRAWAL_AMOUNT() external view returns (uint256);
  function MAX_STETH_WITHDRAWAL_AMOUNT() external view returns (uint256);
  function requestWithdrawalsWstETH(uint256[] calldata amounts, address owner) external returns (uint256[] memory ids);
  function getWithdrawalStatus(uint256[] calldata ids) external view returns (WithdrawalRequestStatus[] memory statuses);
  function getClaimableEther(uint256[] calldata ids, uint256[] calldata hints)
    external
    view
    returns (uint256[] memory amounts);
  function claimWithdrawals(uint256[] calldata ids, uint256[] calldata hints) external;
  function ownerOf(uint256 id) external view returns (address);
}

interface IWstETHConversion {
  function getStETHByWstETH(uint256 amount) external view returns (uint256);
}

/// @notice Queue checkpoint lookup used to verify finalized claimable amounts.
interface ILidoCheckpoints {
  function getLastCheckpointIndex() external view returns (uint256);
  function findCheckpointHints(uint256[] calldata ids, uint256 first, uint256 last)
    external
    view
    returns (uint256[] memory);
}

/// @notice Exact stETH numerator/denominator, not a rounded one-token conversion.
interface ILidoShareTotals {
  function getTotalPooledEther() external view returns (uint256);
  function getTotalShares() external view returns (uint256);
}

/// @notice Wrapped-share binding to the protocol's underlying share ledger.
interface ILidoWrappedShares {
  function stETH() external view returns (address);
}
