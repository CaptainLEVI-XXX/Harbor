// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {RedemptionMarketFixture} from "test/helpers/RedemptionMarketFixture.sol";
import {ISwapVM} from "@1inch/swap-vm/src/interfaces/ISwapVM.sol";
import {Trade, FillTerms, Side, AmountMode} from "src/types/HarborTypes.sol";

/// @notice Fixture-warm call-scope snapshots, not transaction fees or mainnet gas estimates.
/// @dev Quote construction, admission, finalization and calldata intrinsic gas are excluded.
contract ClaimGasTest is RedemptionMarketFixture {
  function test_GasWrap() public {
    uint256 id = _userRequest();
    vm.prank(trader);
    queue.approve(address(factory), id);
    vm.prank(trader);
    vm.startSnapshotGas("HarborClaims", "wrap-fixture-warm");
    factory.wrap(id);
    vm.stopSnapshotGas();
  }

  function test_GasClaimBuy() public {
    _execute(Side.BUY_BASE);
  }

  function test_GasClaimSell() public {
    _execute(Side.SELL_BASE);
  }

  function _execute(Side side) private {
    (uint256 route,,) = _externalMarket(1 ether);
    if (side == Side.SELL_BASE) _tradeClaim(route, Side.BUY_BASE, AmountMode.EXACT_IN);
    (Trade memory t, FillTerms memory f, bytes memory sig, ISwapVM.Order memory order) =
      _claimQuote(route, side, AmountMode.EXACT_IN);
    vm.prank(trader);
    vm.startSnapshotGas("HarborClaims", side == Side.BUY_BASE ? "buy-fixture-warm" : "sell-fixture-warm");
    executor.execute(t, f, sig, order);
    vm.stopSnapshotGas();
  }

  function test_GasExport() public {
    uint256 id = _request(1 ether);
    vm.startSnapshotGas("HarborClaims", "export-fixture-warm");
    book.exportClaim(0, id, address(factory));
    vm.stopSnapshotGas();
  }

  function test_GasVaultRecovery() public {
    (uint256 route, uint256 id,) = _externalMarket(1 ether);
    _tradeClaim(route, Side.BUY_BASE, AmountMode.EXACT_IN);
    queue.setFinalized(id, 1.1 ether);
    vm.startSnapshotGas("HarborClaims", "vault-recovery-fixture-warm");
    book.recoverClaim(route, 1);
    vm.stopSnapshotGas();
  }

  /// @dev Lower bound only: two transfers, no signature, vault, risk checks or Aqua settlement.
  function test_GasDirectNftTransferReference() public {
    uint256 id = _userRequest();
    address buyer = address(0xbeef);
    weth.mint(buyer, 1 ether);
    vm.prank(buyer);
    weth.approve(address(this), 1 ether);
    vm.prank(trader);
    queue.approve(address(this), id);
    vm.startSnapshotGas("HarborClaims", "direct-two-transfer-reference-warm");
    queue.safeTransferFrom(trader, buyer, id);
    weth.transferFrom(buyer, trader, 1 ether);
    vm.stopSnapshotGas();
    assertEq(queue.ownerOf(id), buyer);
  }

  function _userRequest() private returns (uint256 id) {
    uint256[] memory amounts = new uint256[](1);
    amounts[0] = 1 ether;
    vm.startPrank(trader);
    bases[0].approve(address(queue), 1 ether);
    id = queue.requestWithdrawalsWstETH(amounts, trader)[0];
    vm.stopPrank();
  }
}
