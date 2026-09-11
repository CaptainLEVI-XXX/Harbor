// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {ILidoWithdrawalQueue as Queue, ILidoCheckpoints} from "src/interfaces/ILidoWithdrawalQueue.sol";

/// @notice Bounded issuer reads shared by valuation and custody validation.
library LidoClaims {
  error ReceiptMismatch();

  function identity(address issuer, uint256 id) internal view returns (bytes32) {
    return keccak256(abi.encode(block.chainid, issuer, id));
  }

  /// @dev One status batch and one finalized-cash batch, never N single-item queries.
  function observe(address issuer, uint256[] memory ids)
    internal
    view
    returns (Queue.WithdrawalRequestStatus[] memory statuses, uint256[] memory cash)
  {
    // Once cash is credited, payout must not depend on issuer availability.
    if (ids.length == 0) return (new Queue.WithdrawalRequestStatus[](0), new uint256[](0));
    statuses = Queue(issuer).getWithdrawalStatus(ids);
    if (statuses.length != ids.length) revert ReceiptMismatch();
    cash = new uint256[](ids.length);
    uint256 count;
    for (uint256 i; i < ids.length; ++i) {
      if (statuses[i].isFinalized && !statuses[i].isClaimed) ++count;
    }
    if (count == 0) return (statuses, cash);
    uint256[] memory finalized = new uint256[](count);
    uint256 j;
    for (uint256 i; i < ids.length; ++i) {
      if (statuses[i].isFinalized && !statuses[i].isClaimed) finalized[j++] = ids[i];
    }
    ILidoCheckpoints q = ILidoCheckpoints(issuer);
    uint256[] memory hints = q.findCheckpointHints(finalized, 1, q.getLastCheckpointIndex());
    if (hints.length != count) revert ReceiptMismatch();
    uint256[] memory amounts = Queue(issuer).getClaimableEther(finalized, hints);
    if (amounts.length != count) revert ReceiptMismatch();
    j = 0;
    for (uint256 i; i < ids.length; ++i) {
      if (statuses[i].isFinalized && !statuses[i].isClaimed) {
        if (amounts[j] > statuses[i].amountOfStETH) revert ReceiptMismatch();
        cash[i] = amounts[j++];
      }
    }
  }
}
