// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {SafeTransferLib as SafeTransfer} from "solady/utils/SafeTransferLib.sol";
import {HarborVault} from "src/vault/HarborVault.sol";
import {ReentrancyGuardTransient} from "solady/utils/ReentrancyGuardTransient.sol";
import {ISwapVM} from "@1inch/swap-vm/src/interfaces/ISwapVM.sol";
import {TakerTraitsLib} from "@1inch/swap-vm/src/libs/TakerTraits.sol";
import {IHarborBook} from "src/interfaces/IHarborBook.sol";
import {Trade, FillAmounts, AmountMode} from "src/types/HarborTypes.sol";

/// @title HarborExecutor
/// @notice Input-first standing-price trades with exact customer limits and measured payouts.
/// @dev Book/Vault remain locked through every token callback. Public quotes do
/// not reserve capital; SwapVM recomputes the pair from live state under that lock.
contract HarborExecutor is ReentrancyGuardTransient {
  IHarborBook public immutable BOOK;
  address public immutable VAULT;
  ISwapVM public immutable ROUTER;
  address public immutable WETH;

  error UnauthorizedTrader();
  error SettlementMismatch();

  /// @notice Actual customer amounts in raw token units; fee is WETH wei.
  /// @dev Repeated intents are distinct transactions, identified by log metadata.
  event TradeExecuted(
    bytes32 indexed context,
    address indexed trader,
    address indexed receiver,
    uint256 route,
    uint256 amountIn,
    uint256 amountOut,
    uint256 fee,
    uint256 pricingVersion
  );

  constructor(address book, address vault, address router, address weth) {
    BOOK = IHarborBook(book);
    VAULT = vault;
    ROUTER = ISwapVM(router);
    WETH = weth;
  }

  /// @notice Execute the caller's unsigned intent against the current strategy.
  /// @dev Collect actual input, never the whole maxIn. No publisher participates.
  /// An independent permissionless NAV checkpoint precedes a trade if needed.
  function execute(Trade calldata trade) external nonReentrant returns (uint256 actualIn, uint256 actualOut) {
    if (msg.sender != trade.trader) revert UnauthorizedTrader();
    (,, bool fresh) = HarborVault(VAULT).valuationIdentity();
    if (!fresh) HarborVault(VAULT).checkpointValuation();
    FillAmounts memory a = BOOK.quote(trade);
    ISwapVM.Order memory order = BOOK.currentOrder(trade.route);
    bytes32 context = keccak256(abi.encode(trade));
    BOOK.beginTrade(context);
    uint256 beforeIn = SafeTransfer.balanceOf(trade.tokenIn, address(this));
    uint256 beforeOut = SafeTransfer.balanceOf(trade.tokenOut, address(this));
    SafeTransfer.safeTransferFrom(trade.tokenIn, msg.sender, address(this), a.traderIn);
    if (SafeTransfer.balanceOf(trade.tokenIn, address(this)) != beforeIn + a.traderIn) revert SettlementMismatch();
    SafeTransfer.safeApprove(trade.tokenIn, address(ROUTER), a.routerIn);
    (uint256 routerIn, uint256 routerOut, bytes32 orderHash) =
      ROUTER.swap(order, trade.mode == AmountMode.EXACT_IN ? a.routerIn : a.routerOut, _takerData(trade, a));
    if (
      routerIn != a.routerIn || routerOut != a.routerOut || orderHash != keccak256(abi.encode(order))
        || SafeTransfer.balanceOf(trade.tokenOut, address(this)) != beforeOut + a.routerOut
    ) revert SettlementMismatch();
    SafeTransfer.safeApprove(trade.tokenIn, address(ROUTER), 0);
    _pay(WETH, BOOK.FEE_RECIPIENT(), a.fee);
    _pay(trade.tokenOut, trade.receiver, a.traderOut);
    if (
      SafeTransfer.balanceOf(trade.tokenIn, address(this)) != beforeIn
        || SafeTransfer.balanceOf(trade.tokenOut, address(this)) != beforeOut
    ) revert SettlementMismatch();
    BOOK.finishTrade(context);
    emit TradeExecuted(
      context, trade.trader, trade.receiver, trade.route, a.traderIn, a.traderOut, a.fee, trade.pricingVersion
    );
    return (a.traderIn, a.traderOut);
  }

  /// @notice Write-free customer quote, cross-checked through the SwapVM program.
  /// @dev Token callbacks require execute simulation; quotes do not reserve cash.
  function quote(Trade calldata trade) external view returns (FillAmounts memory a) {
    a = BOOK.quote(trade);
    ISwapVM.Order memory order = BOOK.currentOrder(trade.route);
    (uint256 amountIn, uint256 amountOut, bytes32 hash) =
      ROUTER.quote(order, trade.mode == AmountMode.EXACT_IN ? a.routerIn : a.routerOut, _takerData(trade, a));
    if (hash != keccak256(abi.encode(order)) || amountIn != a.routerIn || amountOut != a.routerOut) {
      revert SettlementMismatch();
    }
  }

  function _takerData(Trade calldata trade, FillAmounts memory a) private view returns (bytes memory) {
    TakerTraitsLib.Args memory args;
    args.taker = address(this);
    args.isExactIn = trade.mode == AmountMode.EXACT_IN;
    args.isAToB = trade.tokenIn < trade.tokenOut;
    args.isFirstTransferFromTaker = true;
    args.useTransferFromAndAquaPush = true;
    args.isStrictThresholdAmount = true;
    args.threshold = abi.encode(args.isExactIn ? a.routerOut : a.routerIn);
    args.instructionsArgs = abi.encode(trade);
    return TakerTraitsLib.build(args);
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
