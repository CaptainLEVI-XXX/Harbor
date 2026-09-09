// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {SwapRegisters} from "@1inch/swap-vm/src/libs/VM.sol";
import {Opcode} from "@1inch/swap-vm/src/libs/OpcodeList.sol";
import {ISwapVM} from "@1inch/swap-vm/src/interfaces/ISwapVM.sol";
import {MakerTraitsLib} from "@1inch/swap-vm/src/libs/MakerTraits.sol";
import {HarborProgram} from "src/swapvm/HarborProgram.sol";
import {HarborExactFill} from "src/swapvm/instructions/HarborExactFill.sol";

contract ProgramHarness {
  function build(address weth, address base, uint64 salt) external pure returns (ISwapVM.Order memory) {
    return HarborProgram.build(address(1), address(2), weth, base, 7, 9, salt);
  }

  function program(ISwapVM.Order calldata order) external pure returns (bytes memory) {
    return MakerTraitsLib.program(order.traits, order.data);
  }

  function complete(SwapRegisters calldata r, bool exactIn, uint256 ai, uint256 ao)
    external
    pure
    returns (SwapRegisters memory)
  {
    SwapRegisters memory result = r;
    HarborExactFill.complete(result, exactIn, ai, ao);
    return result;
  }

  function decode(bytes calldata data) external pure returns (address, uint256, uint256) {
    return HarborExactFill.parse(data);
  }
}

/// @title HarborProgramTest
/// @notice Differential wire encoding, strict decoding and register preservation.
contract HarborProgramTest is Test {
  ProgramHarness internal h = new ProgramHarness();

  function testFuzz_ProgramMatchesReadableWireReference(uint64 salt, bool reversed) public view {
    ISwapVM.Order memory order = h.build(reversed ? address(4) : address(3), reversed ? address(3) : address(4), salt);
    bytes memory expected =
      abi.encodePacked(uint8(Opcode.Salt), uint8(8), salt, uint8(0x55), uint8(84), address(2), uint256(7), uint256(9));
    assertEq(h.program(order), expected);
    assertEq(order.maker, address(1));
  }

  function testFuzz_PreservesSpecifiedAndBalanceRegisters(SwapRegisters memory r, bool exactIn, uint256 complement)
    public
    view
  {
    r.amountIn = r.amountIn == 0 ? 1 : r.amountIn;
    r.amountOut = r.amountOut == 0 ? 1 : r.amountOut;
    complement = complement == 0 ? 1 : complement;
    SwapRegisters memory result =
      h.complete(r, exactIn, exactIn ? r.amountIn : complement, exactIn ? complement : r.amountOut);
    assertEq(result.balanceIn, r.balanceIn);
    assertEq(result.balanceOut, r.balanceOut);
    assertEq(result.amountIn, exactIn ? r.amountIn : complement);
    assertEq(result.amountOut, exactIn ? complement : r.amountOut);
  }

  function test_RejectsChangedSpecifiedRegister() public {
    SwapRegisters memory r = SwapRegisters(10, 20, 1, 2);
    vm.expectRevert(HarborExactFill.InvalidAmounts.selector);
    h.complete(r, true, 2, 2);
    vm.expectRevert(HarborExactFill.InvalidAmounts.selector);
    h.complete(r, false, 1, 3);
  }

  function test_ExactMetadataLength() public {
    (address authority, uint256 route, uint256 version) = h.decode(abi.encodePacked(address(2), uint256(7), uint256(9)));
    assertEq(authority, address(2));
    assertEq(route, 7);
    assertEq(version, 9);
    vm.expectRevert(abi.encodeWithSelector(HarborExactFill.InvalidArgumentsLength.selector, 85));
    h.decode(new bytes(85));
    vm.expectRevert(abi.encodeWithSelector(HarborExactFill.InvalidArgumentsLength.selector, 83));
    h.decode(new bytes(83));
  }
}
