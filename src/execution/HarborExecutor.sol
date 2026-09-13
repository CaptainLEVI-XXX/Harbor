// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {SafeTransferLib as SafeTransfer} from "solady/utils/SafeTransferLib.sol";
import {ReentrancyGuardTransient} from "solady/utils/ReentrancyGuardTransient.sol";
import {ISwapVM} from "@1inch/swap-vm/src/interfaces/ISwapVM.sol";
import {TakerTraitsLib} from "@1inch/swap-vm/src/libs/TakerTraits.sol";
import {IHarborBook} from "src/interfaces/IHarborBook.sol";
import {ISwapVMQuote} from "src/interfaces/ISwapVMQuote.sol";
import {Amounts} from "src/libraries/Amounts.sol";
import {IHarborPool} from "src/interfaces/IHarborPool.sol";
import {HarborVault} from "src/vault/HarborVault.sol";
import {SwapVM} from "@1inch/swap-vm/src/SwapVM.sol";
import {Trade, FillAmounts, AmountMode} from "src/types/HarborTypes.sol";

/// @title HarborExecutor
/// @notice VM-priced, input-first trades with exact customer limits and measured payouts.
/// @dev Book/Vault remain locked through every token callback. Public quotes do
/// not reserve capital. Extruction prices before the authenticated funding callback.
contract HarborExecutor is ReentrancyGuardTransient {
  ISwapVM public immutable ROUTER;
  address public immutable GOVERNOR;
  /// @notice Book identity -> fixed Vault. Zero means unregistered; no rebinding.
  mapping(address => address) public vaultOf;

  /// @dev A single-use funding capability, cleared before calling user tokens.
  /// The outer reentrancy guard spans pricing, funding, all hooks and final payout.
  bytes32 private transient _fundingContext;
  address private transient _activeBook;
  bytes32 private transient _orderHash;
  uint256 private transient _actualIn;
  uint256 private transient _actualOut;

  error UnauthorizedTrader();
  error SettlementMismatch();
  error InvalidCallback();
  error InvalidPool();
  error Unauthorized();
  event PoolRegistered(address indexed book, address indexed vault, address indexed asset);

  /// @notice Actual customer amounts in raw token units; fee is settlement-asset raw units.
  /// @dev Repeated intents are distinct transactions, identified by log metadata.
  event TradeExecuted(
    address indexed book,
    bytes32 indexed context,
    address indexed trader,
    address receiver,
    uint256 route,
    uint256 amountIn,
    uint256 amountOut,
    uint256 fee,
    uint256 pricingVersion
  );

  constructor(address router, address governor) {
    if (router.code.length == 0 || governor == address(0)) revert InvalidPool();
    ROUTER = ISwapVM(router);
    GOVERNOR = governor;
  }

  /// @notice Admit a reviewed pool once, after both immutable contracts exist.
  /// @dev Reciprocal getters establish bindings, not code provenance. Governance
  /// must review the implementations. No power to replace existing bindings.
  function registerPool(address book) external nonReentrant {
    if (msg.sender != GOVERNOR) revert Unauthorized();
    if (book.code.length == 0 || vaultOf[book] != address(0)) revert InvalidPool();
    IHarborPool p = IHarborPool(book);
    address vault = p.VAULT();
    address asset = p.ASSET();
    if (
      vault.code.length == 0 || vault == book || asset.code.length == 0 || p.EXECUTOR() != address(this)
        || p.ROUTER() != address(ROUTER) || p.AQUA() != address(SwapVM(payable(address(ROUTER))).AQUA())
        || address(HarborVault(vault).BOOK()) != book || HarborVault(vault).asset() != asset
    ) revert InvalidPool();
    vaultOf[book] = vault;
    emit PoolRegistered(book, vault, asset);
  }

  /// @notice Execute the caller's unsigned intent against the current strategy.
  /// @dev Collect actual input rather than maxIn.
  /// Book checkpoints the independently observed pre-trade NAV under the same lock.
  function execute(address book, Trade calldata trade)
    external
    nonReentrant
    returns (uint256 actualIn, uint256 actualOut)
  {
    if (msg.sender != trade.trader) revert UnauthorizedTrader();
    _pool(book);
    _activeBook = book;
    IHarborBook(book).prepareTrade(trade);
    ISwapVM.Order memory order = IHarborBook(book).currentOrder(trade.route);
    bytes memory payload = abi.encode(trade);
    bytes memory funding = abi.encode(book, trade);
    bytes32 context = keccak256(payload);
    _fundingContext = keccak256(funding);
    _orderHash = keccak256(abi.encode(order));
    uint256 beforeIn = SafeTransfer.balanceOf(trade.tokenIn, address(this));
    uint256 beforeOut = SafeTransfer.balanceOf(trade.tokenOut, address(this));
    (uint256 routerIn, uint256 routerOut, bytes32 orderHash) =
      ROUTER.swap(order, trade.amountSpecified, _takerData(trade, payload, funding));
    if (
      _fundingContext != 0 || routerIn != _actualIn || routerOut != _actualOut || orderHash != _orderHash
        || SafeTransfer.balanceOf(trade.tokenOut, address(this)) != beforeOut + routerOut
    ) revert SettlementMismatch();
    SafeTransfer.safeApprove(trade.tokenIn, address(ROUTER), 0);
    _pay(trade.tokenOut, trade.receiver, routerOut);
    if (
      SafeTransfer.balanceOf(trade.tokenIn, address(this)) != beforeIn
        || SafeTransfer.balanceOf(trade.tokenOut, address(this)) != beforeOut
    ) revert SettlementMismatch();
    uint256 fee = IHarborBook(book).finishTrade(context);
    _activeBook = address(0);
    _orderHash = 0;
    _actualIn = 0;
    _actualOut = 0;
    emit TradeExecuted(
      book, context, trade.trader, trade.receiver, trade.route, routerIn, routerOut, fee, trade.pricingVersion
    );
    return (routerIn, routerOut);
  }

  /// @notice Fund only the current VM-priced trade, immediately before its input transfer.
  /// @dev Router identity alone is insufficient: bind the exact intent, order,
  /// maker, taker and tokens. Consuming context before transfer prevents duplicate
  /// or token-reentrant funding. No arbitrary callback target or spender exists.
  function preTransferInCallback(
    address maker,
    address taker,
    address tokenIn,
    address tokenOut,
    uint256 amountIn,
    uint256 amountOut,
    bytes32 orderHash,
    bytes calldata data
  ) external {
    if (
      msg.sender != address(ROUTER) || maker != vaultOf[_activeBook] || taker != address(this) || _fundingContext == 0
        || keccak256(data) != _fundingContext || orderHash != _orderHash
    ) revert InvalidCallback();
    (address book, Trade memory t) = abi.decode(data, (address, Trade));
    if (book != _activeBook) revert InvalidCallback();
    if (tokenIn != t.tokenIn || tokenOut != t.tokenOut) revert InvalidCallback();
    Amounts.normalize(t, amountIn, amountOut);
    _fundingContext = 0;
    _actualIn = amountIn;
    _actualOut = amountOut;
    uint256 beforeBalance = SafeTransfer.balanceOf(tokenIn, address(this));
    SafeTransfer.safeTransferFrom(tokenIn, t.trader, address(this), amountIn);
    if (SafeTransfer.balanceOf(tokenIn, address(this)) != beforeBalance + amountIn) revert SettlementMismatch();
    SafeTransfer.safeApprove(tokenIn, address(ROUTER), amountIn);
  }

  /// @notice Preview trade amounts and fees using the shared pricing kernel.
  /// @dev Token callbacks require execute simulation; quotes do not reserve cash.
  function quote(address book, Trade calldata trade) external view returns (FillAmounts memory a) {
    _pool(book);
    a = IHarborBook(book).quote(trade);
  }

  /// @notice Quote the actual canonical VM program, including native fees and limits.
  /// @dev A STATICCALL, with this Executor as the actual VM taker. No funding,
  /// publisher signature or token approval is needed to obtain the price.
  function quoteSwap(address book, Trade calldata trade)
    external
    view
    returns (uint256 input, uint256 output, bytes32 orderHash)
  {
    _pool(book);
    return ISwapVMQuote(address(ROUTER))
      .quote(
        IHarborBook(book).currentOrder(trade.route),
        trade.amountSpecified,
        _takerData(trade, abi.encode(trade), abi.encode(book, trade))
      );
  }

  function _pool(address book) private view {
    if (vaultOf[book] == address(0)) revert InvalidPool();
  }

  function _takerData(Trade calldata trade, bytes memory payload, bytes memory funding)
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
    args.threshold = abi.encode(trade.limitAmount);
    args.hasPreTransferInCallback = true;
    args.preTransferInCallbackData = funding;
    args.instructionsArgs = payload;
    return TakerTraitsLib.build(args);
  }

  /// @dev execute supplies the positive, VM-verified customer output. Zero fills
  /// are rejected by Book pricing and the instruction before this payout boundary.
  function _pay(address token, address to, uint256 amount) private {
    uint256 beforeBalance = SafeTransfer.balanceOf(token, to);
    SafeTransfer.safeTransfer(token, to, amount);
    if (SafeTransfer.balanceOf(token, to) != beforeBalance + amount) revert SettlementMismatch();
  }

  function _useTransientReentrancyGuardOnlyOnMainnet() internal pure override returns (bool) {
    return false;
  }
}
