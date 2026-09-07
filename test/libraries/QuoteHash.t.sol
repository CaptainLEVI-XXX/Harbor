// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {QuoteHash} from "src/libraries/QuoteHash.sol";
import {Trade, FillTerms, Side, AmountMode} from "src/types/HarborTypes.sol";

/// @title QuoteHashTest
/// @notice Explicit-field reference for the static tuple hashing optimization.
contract QuoteHashTest is Test {
  function testFuzz_TradeTupleMatchesExplicitFieldReference(
    address trader,
    address receiver,
    uint128 amount,
    Side side,
    AmountMode mode
  ) public pure {
    Trade memory t = Trade(trader, receiver, address(3), address(4), 2, side, mode, amount, 8, 9, 10);
    bytes32 expected = keccak256(
      abi.encode(
        QuoteHash.TRADE_TYPEHASH,
        t.trader,
        t.receiver,
        t.tokenIn,
        t.tokenOut,
        t.route,
        uint8(t.side),
        uint8(t.mode),
        t.amountSpecified,
        t.limitAmount,
        t.deadline,
        t.nonce
      )
    );
    assertEq(QuoteHash.tradeHash(t), expected);
  }

  function testFuzz_TermsTupleMatchesExplicitFieldReference(uint128 amount, bytes32 observation) public pure {
    FillTerms memory f;
    f.vault = address(1);
    f.adapter = address(2);
    f.feeRecipient = address(3);
    f.strategyVersion = 4;
    f.adapterVersion = 5;
    f.epoch = 6;
    f.nonce = 7;
    f.portfolioVersion = 8;
    f.positionVersion = 9;
    f.valuationVersion = 10;
    f.policyVersion = 11;
    f.traderIn = amount;
    f.traderOut = 13;
    f.routerIn = 14;
    f.routerOut = 15;
    f.fee = 16;
    f.feeBps = 17;
    f.observedAt = 18;
    f.validUntil = 19;
    f.orderHash = bytes32(uint256(20));
    f.observationHash = observation;
    bytes32 expected = keccak256(
      abi.encode(
        QuoteHash.TERMS_TYPEHASH,
        f.vault,
        f.adapter,
        f.feeRecipient,
        f.strategyVersion,
        f.adapterVersion,
        f.epoch,
        f.nonce,
        f.portfolioVersion,
        f.positionVersion,
        f.valuationVersion,
        f.policyVersion,
        f.traderIn,
        f.traderOut,
        f.routerIn,
        f.routerOut,
        f.fee,
        f.feeBps,
        f.observedAt,
        f.validUntil,
        f.orderHash,
        f.observationHash
      )
    );
    assertEq(QuoteHash.termsHash(f), expected);
  }

  function test_DomainBindsEverySettlementAuthority() public pure {
    QuoteHash.Domain memory d = QuoteHash.Domain(1, address(1), address(2), address(3), address(4), address(5));
    Trade memory t;
    FillTerms memory f;
    bytes32 original = QuoteHash.digest(d, t, f);
    for (uint256 i; i < 6; ++i) {
      QuoteHash.Domain memory changed = QuoteHash.Domain(1, address(1), address(2), address(3), address(4), address(5));
      if (i == 0) changed.chainId = 2;
      if (i == 1) changed.book = address(9);
      if (i == 2) changed.vault = address(9);
      if (i == 3) changed.executor = address(9);
      if (i == 4) changed.router = address(9);
      if (i == 5) changed.receiver = address(9);
      assertNotEq(QuoteHash.digest(changed, t, f), original);
    }
  }
}
