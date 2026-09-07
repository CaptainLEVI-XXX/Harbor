// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {TokenMock} from "@1inch/solidity-utils/contracts/mocks/TokenMock.sol";
import {ISwapVM} from "@1inch/swap-vm/src/interfaces/ISwapVM.sol";
import {AquaSwapVMRouter} from "@1inch/swap-vm/src/routers/AquaSwapVMRouter.sol";
import {AquaOpcodes} from "@1inch/swap-vm/src/opcodes/AquaOpcodes.sol";
import {HarborProgram} from "src/swapvm/HarborProgram.sol";
import {HarborAquaFixture, ContractMakerFixture} from "test/helpers/HarborAquaFixture.sol";

/// @title VaultAquaSwapVMTest
/// @notice Runtime compatibility, not LP accounting or live issuer proof.
contract VaultAquaSwapVMTest is HarborAquaFixture {
  function test_VaultBuysExactInput() public {
    _trade(true, true);
  }

  function test_VaultBuysExactOutput() public {
    _trade(true, false);
  }

  function test_VaultSellsExactInput() public {
    _trade(false, true);
  }

  function test_VaultSellsExactOutput() public {
    _trade(false, false);
  }

  function test_SequentialTradesClearContext() public {
    _trade(true, true);
    _trade(false, false);
    assertEq(book.settlements(), 2);
  }

  function test_HashMatchesInheritedRouterAndPublication() public view {
    bytes32 hash = keccak256(abi.encode(order));
    assertEq(router.hash(order), hash);
    (uint256 a, uint256 b) = aqua.safeBalances(address(maker), address(router), hash, address(weth), address(base));
    assertEq(a, 100 ether);
    assertEq(b, 100 ether);
    assertEq(weth.balanceOf(address(aqua)), 0);
    assertEq(weth.balanceOf(address(maker)), 100 ether);
  }

  function test_ShippingFromAnotherContractDoesNotPublishForVault() public {
    ISwapVM.Order memory other =
      HarborProgram.build(address(maker), address(book), address(weth), address(base), 0, 1, 2);
    ContractMakerFixture wrongPublisher = new ContractMakerFixture();
    _ship(other, wrongPublisher);
    book.configure(router.hash(other), 1 ether, 1 ether, false);
    bytes memory traits = _traits(true, true, 1 ether, true);
    vm.expectRevert();
    router.swap(other, 1 ether, traits);
  }

  function test_OutputFirstFailsAndRollsBack() public {
    book.configure(router.hash(order), 1 ether, 1 ether, false);
    bytes memory traits = _traits(true, true, 1 ether, false);
    vm.expectRevert(bytes("hook phase"));
    router.swap(order, 1 ether, traits);
    assertEq(book.settlements(), 0);
    assertEq(weth.balanceOf(address(maker)), 100 ether);
  }

  function test_LateHookFailureRollsBackTokensAndCounters() public {
    book.configure(router.hash(order), 1 ether, 1 ether, true);
    bytes memory traits = _traits(true, true, 1 ether, true);
    vm.expectRevert(bytes("output delta"));
    router.swap(order, 1 ether, traits);
    assertEq(base.balanceOf(address(maker)), 100 ether);
    assertEq(weth.balanceOf(address(maker)), 100 ether);
    assertEq(base.balanceOf(address(this)), 100 ether);
    assertEq(weth.balanceOf(address(this)), 100 ether);
    (uint256 a, uint256 b) =
      aqua.safeBalances(address(maker), address(router), router.hash(order), address(weth), address(base));
    assertEq(a, 100 ether);
    assertEq(b, 100 ether);
    _trade(true, true);
  }

  function test_ExactOutputRejectsOneWeiInsufficientInputThreshold() public {
    book.configure(router.hash(order), 2 ether, 1 ether, false);
    bytes memory traits = _traits(true, false, 2 ether - 1, true);
    vm.expectRevert();
    router.swap(order, 1 ether, traits);
    assertEq(book.settlements(), 0);
  }

  function test_DirectHookCallRejected() public {
    bytes32 hash = router.hash(order);
    vm.expectRevert(bytes("hook phase"));
    book.preTransferOut(address(maker), address(this), address(base), address(weth), 1, 1, hash, "", "");
  }

  function test_UnmodifiedOfficialRouterRejectsHarborOpcode() public {
    AquaSwapVMRouter upstream = new AquaSwapVMRouter(address(aqua), address(weth), address(this), "Harbor", "1");
    address[] memory tokens = new address[](2);
    tokens[0] = address(weth);
    tokens[1] = address(base);
    uint256[] memory amounts = new uint256[](2);
    amounts[0] = 100 ether;
    amounts[1] = 100 ether;
    maker.ship(aqua, address(upstream), order, tokens, amounts);
    bytes memory traits = _traits(true, true, 1 ether, true);
    vm.expectRevert(abi.encodeWithSelector(AquaOpcodes.UnknownOpcode.selector, uint256(0x55)));
    ISwapVM(address(upstream)).quote(order, 1 ether, traits);
    assertEq(book.settlements(), 0);
  }

  function _trade(bool baseIn, bool exactIn) private {
    (uint256 input, uint256 output) =
      baseIn ? (uint256(1 ether), uint256(1.1 ether)) : (uint256(1.2 ether), uint256(1 ether));
    book.configure(router.hash(order), input, output, false);
    bytes memory traits = _traits(baseIn, exactIn, exactIn ? output : input, true);
    uint256 specified = exactIn ? input : output;
    uint256 settledBefore = book.settlements();
    (uint256 quotedIn, uint256 quotedOut,) = ISwapVM(address(router)).quote(order, specified, traits);
    assertEq(book.settlements(), settledBefore);
    assertEq(quotedIn, input);
    assertEq(quotedOut, output);
    TokenMock tokenIn = baseIn ? base : weth;
    TokenMock tokenOut = baseIn ? weth : base;
    uint256 makerIn = tokenIn.balanceOf(address(maker));
    uint256 makerOut = tokenOut.balanceOf(address(maker));
    uint256 takerIn = tokenIn.balanceOf(address(this));
    uint256 takerOut = tokenOut.balanceOf(address(this));
    (uint256 actualIn, uint256 actualOut,) = router.swap(order, specified, traits);
    assertEq(actualIn, input);
    assertEq(actualOut, output);
    assertEq(tokenIn.balanceOf(address(maker)), makerIn + input);
    assertEq(tokenOut.balanceOf(address(maker)), makerOut - output);
    assertEq(tokenIn.balanceOf(address(this)), takerIn - input);
    assertEq(tokenOut.balanceOf(address(this)), takerOut + output);
    assertEq(tokenIn.balanceOf(address(router)), 0);
    assertEq(tokenOut.balanceOf(address(router)), 0);
    assertEq(book.settlements(), settledBefore + 1);
  }
}
