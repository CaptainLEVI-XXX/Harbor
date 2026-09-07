// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {QuoteValidation} from "src/libraries/QuoteValidation.sol";
import {Side} from "src/types/HarborTypes.sol";

contract PriceGuardHarness {
  function check(Side side, uint256 cash, uint256 entitlement, uint256 multiplier, uint256 buffer) external pure {
    QuoteValidation.price(side, cash, entitlement, multiplier, buffer);
  }
}

/// @title QuoteValidationTest
/// @notice Public bid/ask guards round against the vault's economic risk.
contract QuoteValidationTest is Test {
  PriceGuardHarness internal h = new PriceGuardHarness();

  function test_BidUsesFloorAndSubtractsBuffer() public {
    h.check(Side.BUY_BASE, 97, 101, 0.99e18, 2);
    vm.expectRevert(QuoteValidation.PublicPriceViolation.selector);
    h.check(Side.BUY_BASE, 98, 101, 0.99e18, 2);
  }

  function test_AskUsesCeilingAndAddsBuffer() public {
    h.check(Side.SELL_BASE, 105, 101, 1.01e18, 2);
    vm.expectRevert(QuoteValidation.PublicPriceViolation.selector);
    h.check(Side.SELL_BASE, 104, 101, 1.01e18, 2);
  }

  function test_BufferCannotUnderflowIntoHugeBidCapacity() public {
    vm.expectRevert(QuoteValidation.PublicPriceViolation.selector);
    h.check(Side.BUY_BASE, 1, 1, 1e18, 2);
  }
}
