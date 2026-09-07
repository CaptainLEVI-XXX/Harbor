// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {SwapRegisters} from "@1inch/swap-vm/src/libs/VM.sol";
import {Opcode} from "@1inch/swap-vm/src/libs/OpcodeList.sol";
import {ISwapVM} from "@1inch/swap-vm/src/interfaces/ISwapVM.sol";
import {MakerTraitsLib} from "@1inch/swap-vm/src/libs/MakerTraits.sol";
import {Extruction} from "@1inch/swap-vm/src/instructions/Extruction.sol";
import {InstructionBuilder} from "@1inch/swap-vm/src/libs/InstructionBuilder.sol";
import {HarborProgram} from "src/swapvm/HarborProgram.sol";
import {HarborExtruction} from "src/swapvm/HarborExtruction.sol";

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
    return HarborExtruction.complete(r, exactIn, ai, ao);
  }

  function decode(bytes calldata data) external pure returns (uint256, uint256) {
    return HarborExtruction.decode(data);
  }

  function extension(uint256 size) external pure returns (bytes memory) {
    return Extruction.build(address(2), new bytes(size));
  }
}

/// @title HarborProgramTest
/// @notice Differential wire encoding, strict decoding and register preservation.
contract HarborProgramTest is Test {
  ProgramHarness internal h = new ProgramHarness();

  function testFuzz_ProgramMatchesReadableWireReference(uint64 salt, bool reversed) public view {
    ISwapVM.Order memory order = h.build(reversed ? address(4) : address(3), reversed ? address(3) : address(4), salt);
    bytes memory expected = abi.encodePacked(
      uint8(Opcode.Salt), uint8(8), salt, uint8(Opcode.Extruction), uint8(84), address(2), uint256(7), uint256(9)
    );
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
    vm.expectRevert(HarborExtruction.InvalidAmounts.selector);
    h.complete(r, true, 2, 2);
    vm.expectRevert(HarborExtruction.InvalidAmounts.selector);
    h.complete(r, false, 1, 3);
  }

  function test_ExactMetadataLength() public {
    (uint256 route, uint256 version) = h.decode(abi.encode(uint256(7), uint256(9)));
    assertEq(route, 7);
    assertEq(version, 9);
    vm.expectRevert(abi.encodeWithSelector(HarborExtruction.InvalidMetadataLength.selector, 65));
    h.decode(new bytes(65));
    vm.expectRevert(abi.encodeWithSelector(HarborExtruction.InvalidMetadataLength.selector, 63));
    h.decode(new bytes(63));
  }

  function test_UpstreamInstructionLengthBoundary() public {
    assertEq(h.extension(235).length, 257); // 255 argument bytes plus header.
    vm.expectRevert(abi.encodeWithSelector(InstructionBuilder.InstructionBuilderArgsLengthExceeded.selector, 256));
    h.extension(236);
  }
}
