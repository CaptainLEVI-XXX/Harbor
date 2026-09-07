// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Vm} from "forge-std/Vm.sol";
import {TokenMock} from "@1inch/solidity-utils/contracts/mocks/TokenMock.sol";
import {ISwapVM} from "@1inch/swap-vm/src/interfaces/ISwapVM.sol";
import {HarborVault} from "src/vault/HarborVault.sol";
import {HarborBook} from "src/book/HarborBook.sol";
import {HarborExecutor} from "src/execution/HarborExecutor.sol";
import {Trade, FillTerms, Side, AmountMode} from "src/types/HarborTypes.sol";
import {TradingFixture} from "test/helpers/TradingFixture.sol";

/// @notice Deliberately adversarial test token, not production WETH behavior.
contract TradingCallbackToken is TokenMock {
  HarborVault private vault;
  HarborBook private book;
  address private executor;
  bytes private executeData;
  uint256 private nav;
  uint256 private supply;
  uint256 public rejected;
  constructor() TokenMock("Adversarial WETH", "BADWETH") {}

  function arm(HarborVault v, HarborBook b, address e, bytes calldata data) external onlyOwner {
    vault = v;
    book = b;
    executor = e;
    executeData = data;
    nav = v.totalAssets();
    supply = v.totalSupply();
  }

  function _update(address from, address to, uint256 amount) internal override {
    super._update(from, to, amount);
    if (executor == address(0)) return;
    _reject(address(vault), abi.encodeWithSignature("deposit(uint256,address)", 1, address(this)));
    _reject(address(vault), abi.encodeWithSignature("transfer(address,uint256)", address(1), 0));
    _reject(
      address(vault), abi.encodeWithSignature("requestRedeem(uint256,address,address)", 1, address(this), address(this))
    );
    _reject(address(vault), abi.encodeWithSignature("fulfillWithdrawals(uint256)", 1));
    _reject(address(vault), abi.encodeWithSignature("checkpointValuation()"));
    _reject(address(book), abi.encodeWithSignature("beginTrade(bytes32)", bytes32(uint256(1))));
    _reject(executor, executeData);
    require(vault.totalAssets() == nav && vault.totalSupply() == supply, "incoherent trade snapshot");
  }

  function _reject(address target, bytes memory data) private {
    (bool ok,) = target.call(data);
    require(!ok, "cross-domain reentry succeeded");
    ++rejected;
  }
}

/// @title TradingReentrancyTest
/// @notice Guards remain active through router output, fee and final trader payout.
contract TradingReentrancyTest is TradingFixture {
  function _deployWeth() internal override returns (TokenMock) {
    return new TradingCallbackToken();
  }

  function test_RouterFeeAndTraderCallbacksRemainLocked() public {
    (Trade memory t, FillTerms memory f, bytes memory sig, ISwapVM.Order memory order) =
      _quote(0, Side.BUY_BASE, AmountMode.EXACT_IN, 1 ether);
    TradingCallbackToken(address(weth))
      .arm(vault, book, address(executor), abi.encodeCall(executor.execute, (t, f, sig, order)));
    vm.prank(trader);
    executor.execute(t, f, sig, order);
    assertEq(TradingCallbackToken(address(weth)).rejected(), 21);
    vault.checkpointValuation();
    assertEq(vault.totalAssets(), 20.01 ether);
  }

  function test_ExecutorGuardUsesTransientPathOnBothChainIds() public {
    _traceGuard(31337);
    _traceGuard(1);
  }

  function _traceGuard(uint256 chain) private {
    vm.chainId(chain);
    Trade memory t;
    FillTerms memory f;
    ISwapVM.Order memory order;
    vm.startDebugTraceRecording();
    (bool success, bytes memory reason) =
      address(executor).call(abi.encodeCall(executor.execute, (t, f, bytes(""), order)));
    Vm.DebugStep[] memory steps = vm.stopAndReturnDebugTraceRecording();
    assertFalse(success);
    assertEq(bytes4(reason), HarborExecutor.UnauthorizedTrader.selector);
    bool read;
    bool write;
    for (uint256 i; i < steps.length; ++i) {
      if (steps[i].contractAddr != address(executor)) continue;
      if (steps[i].opcode == 0x5c) read = true;
      if (steps[i].opcode == 0x5d) write = true;
    }
    assertTrue(read);
    assertTrue(write);
  }
}
