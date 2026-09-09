// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {SafeTransferLib as SafeTransfer} from "solady/utils/SafeTransferLib.sol";
import {AdapterBase} from "src/adapters/base/AdapterBase.sol";
import {ILidoWithdrawalQueue as Queue, IWstETHConversion} from "src/interfaces/ILidoWithdrawalQueue.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IHarborClaimFactory} from "src/interfaces/IHarborClaim.sol";

/// @notice Bounded wstETH requests and adapter-owned unstETH recovery to one vault.
/// @dev Reviewed Lido minting does not call onERC721Received. No NFT receiver is
/// exposed: unsolicited safe transfers fail; unsafe transfers never become tracked.
contract LidoAdapter is AdapterBase {
  mapping(uint256 => bool) public accepted;
  mapping(uint256 => bool) public closed;
  /// @notice A transferred native right can never be recovered by this adapter again.

  event Requested(uint256 indexed id, uint256 wrappedAmount, uint256 entitlement);
  event Recovered(uint256 indexed id, uint256 wethAmount);
  event ClaimExported(uint256 indexed id, address indexed receipt);

  constructor(address book, address vault, address wsteth, address weth, address queue)
    AdapterBase(book, vault, wsteth, weth, queue)
  {
    if (Queue(queue).WSTETH() != wsteth) revert InvalidConfiguration();
  }

  function request(uint256[] calldata amounts, uint256 previousBalance)
    external
    onlyBook
    nonReentrant
    returns (Request[] memory requests)
  {
    if (amounts.length == 0 || amounts.length > 8) revert InvalidRequest();
    uint256 total;
    uint256 minimum = Queue(ISSUER).MIN_STETH_WITHDRAWAL_AMOUNT();
    uint256 maximum = Queue(ISSUER).MAX_STETH_WITHDRAWAL_AMOUNT();
    for (uint256 i; i < amounts.length; ++i) {
      uint256 underlying = IWstETHConversion(BASE).getStETHByWstETH(amounts[i]);
      if (amounts[i] == 0 || underlying < minimum || underlying > maximum) revert InvalidRequest();
      total += amounts[i];
    }
    if (SafeTransfer.balanceOf(BASE, address(this)) != previousBalance + total) revert ReceiptMismatch();
    SafeTransfer.safeApprove(BASE, ISSUER, total);
    uint256[] memory ids = Queue(ISSUER).requestWithdrawalsWstETH(amounts, address(this));
    SafeTransfer.safeApprove(BASE, ISSUER, 0);
    if (ids.length != amounts.length || SafeTransfer.balanceOf(BASE, address(this)) != previousBalance) {
      revert ReceiptMismatch();
    }
    Queue.WithdrawalRequestStatus[] memory statuses = Queue(ISSUER).getWithdrawalStatus(ids);
    if (statuses.length != ids.length) revert ReceiptMismatch();
    requests = new Request[](ids.length);
    for (uint256 i; i < ids.length; ++i) {
      Queue.WithdrawalRequestStatus memory s = statuses[i];
      if (
        ids[i] == 0 || accepted[ids[i]] || s.owner != address(this) || s.isClaimed || s.isFinalized
          || s.timestamp != block.timestamp || s.amountOfStETH == 0 || s.amountOfShares == 0
          || s.amountOfStETH != IWstETHConversion(BASE).getStETHByWstETH(amounts[i])
          || Queue(ISSUER).ownerOf(ids[i]) != address(this)
      ) revert InvalidRequest();
      accepted[ids[i]] = true;
      requests[i] = Request(ids[i], amounts[i], s.amountOfStETH);
      emit Requested(ids[i], amounts[i], s.amountOfStETH);
    }
  }

  function claim(uint256 id, uint256 hint) external onlyBook nonReentrant returns (uint256 cash, uint256 remaining) {
    if (!accepted[id] || closed[id]) revert InvalidRequest();
    uint256[] memory ids = new uint256[](1);
    uint256[] memory hints = new uint256[](1);
    ids[0] = id;
    hints[0] = hint;
    Queue.WithdrawalRequestStatus[] memory statuses = Queue(ISSUER).getWithdrawalStatus(ids);
    if (
      statuses.length != 1 || !statuses[0].isFinalized || statuses[0].isClaimed || statuses[0].owner != address(this)
        || Queue(ISSUER).ownerOf(id) != address(this)
    ) revert InvalidRequest();
    uint256[] memory claimable = Queue(ISSUER).getClaimableEther(ids, hints);
    if (claimable.length != 1 || claimable[0] > statuses[0].amountOfStETH) revert ReceiptMismatch();
    closed[id] = true;
    _receiving = true;
    Queue(ISSUER).claimWithdrawals(ids, hints);
    _receiving = false;
    statuses = Queue(ISSUER).getWithdrawalStatus(ids);
    if (statuses.length != 1 || !statuses[0].isClaimed) revert ReceiptMismatch();
    cash = _payVault(claimable[0]);
    // Lido burns the entire right on claim; partial receipt support is not implied.
    remaining = 0;
    emit Recovered(id, cash);
  }

  /// @notice Convert an accepted pending NFT into one receipt delivered to the fixed vault.
  /// @dev Book approves the integration and moves basis in the same transaction.
  /// NFT approval is specific to this ID and cleared by the issuer on transfer.
  function exportClaim(uint256 id, address factory) external onlyBook nonReentrant returns (address receipt) {
    if (!accepted[id] || closed[id]) revert InvalidRequest();
    IHarborClaimFactory f = IHarborClaimFactory(factory);
    if (f.ISSUER() != ISSUER || f.WETH() != WETH) revert InvalidConfiguration();
    closed[id] = true;
    IERC721(ISSUER).approve(factory, id);
    receipt = f.wrap(id);
    if (SafeTransfer.balanceOf(receipt, address(this)) != 1 || SafeTransfer.balanceOf(receipt, VAULT) != 0) {
      revert ReceiptMismatch();
    }
    SafeTransfer.safeTransfer(receipt, VAULT, 1);
    if (SafeTransfer.balanceOf(receipt, address(this)) != 0 || SafeTransfer.balanceOf(receipt, VAULT) != 1) {
      revert ReceiptMismatch();
    }
    emit ClaimExported(id, receipt);
  }
}
