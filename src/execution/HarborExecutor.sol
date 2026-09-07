// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {SafeTransferLib as SafeTransfer} from "solady/utils/SafeTransferLib.sol";
import {ReentrancyGuardTransient} from "solady/utils/ReentrancyGuardTransient.sol";
import {ISwapVM} from "@1inch/swap-vm/src/interfaces/ISwapVM.sol";
import {TakerTraitsLib} from "@1inch/swap-vm/src/libs/TakerTraits.sol";
import {IHarborBook} from "src/interfaces/IHarborBook.sol";
import {Trade, FillTerms, FillAmounts, AmountMode} from "src/types/HarborTypes.sol";
import {QuoteHash} from "src/libraries/QuoteHash.sol";
import {QuoteValidation} from "src/libraries/QuoteValidation.sol";

/// @title HarborExecutor
/// @notice One indivisible, input-first trade with exact user limits and WETH fees.
/// @dev Book/Vault remain locked until all payouts and residue checks succeed.
contract HarborExecutor is ReentrancyGuardTransient {
  IHarborBook public immutable BOOK;
  address public immutable VAULT;
  ISwapVM public immutable ROUTER;
  address public immutable WETH;

  error UnauthorizedTrader();
  error InvalidReceiver();
  error SettlementMismatch();

  event TradeExecuted(
    bytes32 indexed fillDigest,
    address indexed trader,
    address indexed receiver,
    uint256 route,
    uint256 amountIn,
    uint256 amountOut,
    uint256 fee
  );

  constructor(address book, address vault, address router, address weth) {
    BOOK = IHarborBook(book);
    VAULT = vault;
    ROUTER = ISwapVM(router);
    WETH = weth;
  }

  function execute(
    Trade calldata trade,
    FillTerms calldata terms,
    bytes calldata signature,
    ISwapVM.Order calldata order
  ) external nonReentrant returns (uint256 actualIn, uint256 actualOut) {
    if (msg.sender != trade.trader) revert UnauthorizedTrader();
    _identities(trade, terms);
    FillAmounts memory a = QuoteValidation.amounts(trade, terms);
    bytes32 digest = BOOK.validate(trade, terms, signature);
    BOOK.beginTrade(QuoteHash.tradeHash(trade));
    uint256 beforeIn = SafeTransfer.balanceOf(trade.tokenIn, address(this));
    uint256 beforeOut = SafeTransfer.balanceOf(trade.tokenOut, address(this));
    SafeTransfer.safeTransferFrom(trade.tokenIn, msg.sender, address(this), a.traderIn);
    if (SafeTransfer.balanceOf(trade.tokenIn, address(this)) != beforeIn + a.traderIn) revert SettlementMismatch();
    SafeTransfer.safeApprove(trade.tokenIn, address(ROUTER), a.routerIn);
    (uint256 routerIn, uint256 routerOut, bytes32 orderHash) = ROUTER.swap(
      order, trade.mode == AmountMode.EXACT_IN ? a.routerIn : a.routerOut, _takerData(trade, terms, signature)
    );
    if (
      routerIn != a.routerIn || routerOut != a.routerOut || orderHash != terms.orderHash
        || SafeTransfer.balanceOf(trade.tokenOut, address(this)) != beforeOut + a.routerOut
    ) revert SettlementMismatch();
    SafeTransfer.safeApprove(trade.tokenIn, address(ROUTER), 0);
    _pay(WETH, terms.feeRecipient, a.fee);
    _pay(trade.tokenOut, trade.receiver, a.traderOut);
    if (
      SafeTransfer.balanceOf(trade.tokenIn, address(this)) != beforeIn
        || SafeTransfer.balanceOf(trade.tokenOut, address(this)) != beforeOut
    ) revert SettlementMismatch();
    BOOK.finishTrade(digest);
    emit TradeExecuted(digest, trade.trader, trade.receiver, trade.route, a.traderIn, a.traderOut, a.fee);
    return (a.traderIn, a.traderOut);
  }

  /// @notice Write-free same-prestate quote; separately simulate execute for callbacks.
  function quoteFill(
    Trade calldata trade,
    FillTerms calldata terms,
    bytes calldata signature,
    ISwapVM.Order calldata order
  ) external view returns (uint256 routerIn, uint256 routerOut) {
    _identities(trade, terms);
    QuoteValidation.amounts(trade, terms);
    BOOK.validate(trade, terms, signature);
    bytes32 hash;
    (routerIn, routerOut, hash) = ROUTER.quote(
      order, trade.mode == AmountMode.EXACT_IN ? terms.routerIn : terms.routerOut, _takerData(trade, terms, signature)
    );
    if (hash != terms.orderHash || routerIn != terms.routerIn || routerOut != terms.routerOut) {
      revert SettlementMismatch();
    }
  }

  function _takerData(Trade calldata trade, FillTerms calldata terms, bytes calldata signature)
    private
    view
    returns (bytes memory)
  {
    TakerTraitsLib.Args memory args;
    args.taker = address(this);
    args.isExactIn = trade.mode == AmountMode.EXACT_IN;
    args.isAToB = trade.tokenIn < trade.tokenOut;
    args.isFirstTransferFromTaker = true;
    args.useTransferFromAndAquaPush = true;
    args.isStrictThresholdAmount = true;
    args.threshold = abi.encode(args.isExactIn ? terms.routerOut : terms.routerIn);
    args.instructionsArgs = abi.encode(trade, terms, signature);
    return TakerTraitsLib.build(args);
  }

  function _identities(Trade calldata t, FillTerms calldata f) private view {
    if (
      !_recipient(t.trader) || !_recipient(t.receiver) || t.tokenIn == t.tokenOut || f.feeRecipient == t.trader
        || f.feeRecipient == t.receiver
    ) revert InvalidReceiver();
  }

  function _recipient(address a) private view returns (bool) {
    return a != address(0) && a != address(this) && a != VAULT && a != address(BOOK) && a != address(ROUTER);
  }

  function _pay(address token, address to, uint256 amount) private {
    if (amount == 0) return;
    uint256 beforeBalance = SafeTransfer.balanceOf(token, to);
    SafeTransfer.safeTransfer(token, to, amount);
    if (SafeTransfer.balanceOf(token, to) != beforeBalance + amount) revert SettlementMismatch();
  }

  function _useTransientReentrancyGuardOnlyOnMainnet() internal pure override returns (bool) {
    return false;
  }
}
