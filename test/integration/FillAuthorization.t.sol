// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {SwapQuery} from "@1inch/swap-vm/src/libs/VM.sol";
import {ISwapVM} from "@1inch/swap-vm/src/interfaces/ISwapVM.sol";
import {BookState} from "src/book/base/BookState.sol";
import {Trade, FillTerms, Side, AmountMode} from "src/types/HarborTypes.sol";
import {TradingFixture} from "test/helpers/TradingFixture.sol";

/// @title FillAuthorizationTest
/// @notice The native instruction's narrow callback grants no direct-call authority.
contract FillAuthorizationTest is TradingFixture {
  function test_DirectAuthorizationCannotBypassRouter() public {
    SwapQuery memory query;
    vm.expectRevert(BookState.InvalidCallback.selector);
    book.authorizeFill(true, query, 0, 1, "");
  }

  function test_RouterIdentityAloneCannotAuthorizeAnotherMaker() public {
    (SwapQuery memory query, bytes memory payload) = _input();
    query.maker = alice;
    vm.expectRevert(BookState.InvalidCallback.selector);
    vm.prank(address(router));
    book.authorizeFill(true, query, 0, 1, payload);
  }

  function test_RouteMetadataCannotSelectAnotherSignedTrade() public {
    (SwapQuery memory query, bytes memory payload) = _input();
    vm.expectRevert(BookState.InvalidQuote.selector);
    vm.prank(address(router));
    book.authorizeFill(true, query, 1, 1, payload);
  }

  function test_SwapAuthorizationRequiresExecutorOpenedContext() public {
    (SwapQuery memory query, bytes memory payload) = _input();
    vm.expectRevert(BookState.InvalidCallback.selector);
    vm.prank(address(router));
    book.authorizeFill(false, query, 0, 1, payload);
  }

  function testFuzz_TrailingPayloadRejected(bytes memory trailing) public {
    vm.assume(trailing.length > 0 && trailing.length <= 256);
    (SwapQuery memory query, bytes memory payload) = _input();
    payload = bytes.concat(payload, trailing);
    vm.expectRevert(BookState.InvalidQuote.selector);
    vm.prank(address(router));
    book.authorizeFill(true, query, 0, 1, payload);
  }

  function _input() private returns (SwapQuery memory query, bytes memory payload) {
    (Trade memory trade, FillTerms memory terms, bytes memory signature, ISwapVM.Order memory order) =
      _quote(0, Side.BUY_BASE, AmountMode.EXACT_IN, 1 ether);
    query = SwapQuery(terms.orderHash, order.maker, address(executor), trade.tokenIn, trade.tokenOut, true);
    payload = abi.encode(trade, terms, signature);
  }
}
