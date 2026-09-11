// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {IHarborBook} from "src/interfaces/IHarborBook.sol";

import {SafeTransferLib as SafeTransfer} from "solady/utils/SafeTransferLib.sol";
import {ISwapVM} from "@1inch/swap-vm/src/interfaces/ISwapVM.sol";
import {IMakerHooks} from "@1inch/swap-vm/src/interfaces/IMakerHooks.sol";
import {IExtruction} from "@1inch/swap-vm/src/instructions/Extruction.sol";
import {SwapQuery, SwapRegisters} from "@1inch/swap-vm/src/libs/VM.sol";
import {HarborPricing} from "src/swapvm/instructions/HarborPricing.sol";
import {HarborProgram} from "src/swapvm/HarborProgram.sol";
import {Trade, FillAmounts, Side, Operation} from "src/types/HarborTypes.sol";
import {BookPricing} from "src/book/base/BookPricing.sol";
import {ClaimMarkets} from "src/libraries/ClaimMarkets.sol";
import {BookPortfolio} from "src/libraries/BookPortfolio.sol";
import {QuoteValidation} from "src/libraries/QuoteValidation.sol";
import {IHarborClaimFactory} from "src/interfaces/IHarborClaimFactory.sol";

/// @title BookSettlement
/// @notice Aqua strategy publication, exact-fill authorization and transfer hooks.
/// @dev Official Extruction invokes the Harbor pricing extension. This module owns the
/// pricing mandate, transaction-local authorization, budgets and measured accounting.
abstract contract BookSettlement is BookPricing, IExtruction, IMakerHooks {
  /*//////////////////////////////////////////////////////////////
                         STRATEGY & EXECUTOR
  //////////////////////////////////////////////////////////////*/

  /// @notice Rebuild the canonical order for the current route version.
  /// @param id Approved route identifier.
  /// @return Maker order whose encoded hash is registered in Aqua.
  function currentOrder(uint256 id) public view override returns (ISwapVM.Order memory) {
    return _order(id, strategyVersion[id]);
  }

  /// @inheritdoc IHarborBook
  /// @dev Executor only; acquiring the shared lock precedes all token callbacks.
  function prepareTrade(Trade calldata trade) external {
    if (msg.sender != address(EXECUTOR)) revert Unauthorized();
    _open(keccak256(abi.encode(trade)), Operation.TRADE);
    _phase = SettlementPhase.OPENED;
  }

  /// @inheritdoc IHarborBook
  /// @dev Executor only, after output hooks and all trader/fee payouts. The Vault
  /// checks its net cash delta before either contract releases its operation lock.
  function finishTrade(bytes32 digest) external returns (uint256 fee) {
    if (
      msg.sender != address(EXECUTOR) || _operation != Operation.TRADE || _phase != SettlementPhase.OUTPUT_SENT
        || digest != _context
    ) {
      revert Unauthorized();
    }
    BookPortfolio.checkSettlement(
      _claimMarkets,
      _routes,
      _route,
      _buy,
      _buy ? _preparedIn : _preparedOut,
      _cash,
      strategyFactoryVersion[_route],
      ASSET,
      _preparedObservation
    );
    VAULT.settleTrade(_context, _buy, _cash);
    fee = _preparedFee;
    _release();
  }

  /// @inheritdoc IHarborBook
  /// @dev Vault only on behalf of governor. Publication changes identity and
  /// invalidates old quotes, but never resets basis, losses or consumed nonces.
  function prepareStrategyFromVault(uint256 id, address requester)
    external
    returns (ISwapVM.Order memory order, bytes32 previous, address base, uint256 managed)
  {
    if (msg.sender != address(VAULT) || _operation != Operation.VAULT || requester != GOVERNOR) {
      revert Unauthorized();
    }
    previous = strategyHash[id];
    uint256 version = ++strategyVersion[id];
    address factory = _claimMarkets.markets[id].factory;
    if (factory != address(0)) {
      strategyFactoryVersion[id] = IHarborClaimFactory(factory).version(_claimMarkets.markets[id].adapter);
    }
    order = _order(id, version);
    base = ClaimMarkets.base(_claimMarkets, _routes, id);
    managed = _state.positions[id].shares;
    strategyHash[id] = keccak256(abi.encode(order));
    emit StrategyPublished(id, strategyHash[id], version, strategyFactoryVersion[id], configVersion);
  }

  /*//////////////////////////////////////////////////////////////
                         LIVE PRICING AUTHORIZATION
  //////////////////////////////////////////////////////////////*/

  /// @inheritdoc IExtruction
  /// @dev The immutable Book is the maker-committed target. Quote uses STATICCALL;
  /// swap computes once under the Executor-opened pool lock, before any funding.
  /// No program counter changes, caller-selected targets or caller-supplied prices.
  /// Pure pricing/validation libraries use fixed compiler links.
  function extruction(
    bool isStaticContext,
    uint256 nextPC,
    SwapQuery calldata query,
    SwapRegisters calldata swap,
    bytes calldata args,
    bytes calldata payload
  ) external returns (uint256 updatedNextPC, uint256 choppedLength, SwapRegisters memory updatedSwap) {
    if (msg.sender != ROUTER || query.maker != address(VAULT) || query.taker != address(EXECUTOR)) {
      revert InvalidCallback();
    }
    (Trade memory trade, bytes32 context) = QuoteValidation.intent(query, strategyHash, args, payload);
    uint256 id = trade.route;
    if (isStaticContext) {
      if (_operation != Operation.NONE) revert Busy();
    } else if (_operation != Operation.TRADE || _phase != SettlementPhase.OPENED || _context != context) {
      revert InvalidCallback();
    }
    (FillAmounts memory a, BookPortfolio.Value memory value, bytes32 evidence) =
      _quoteWithValue(trade, true, query.isExactIn ? swap.amountIn : swap.amountOut);
    updatedSwap = HarborPricing.complete(
      swap, trade, a.routerIn, a.routerOut, FEE_BPS, _claimMarkets.markets[id].factory != address(0)
    );
    if (!isStaticContext) {
      _preparedObservation = evidence;
      VAULT.checkpointTrade(_context, value.inventory, value.claims, value.observedAt, value.evidence);
      _preparedIn = a.routerIn;
      _preparedOut = a.routerOut;
      _hookHash = keccak256(abi.encode(query.maker, query.taker, query.tokenIn, query.tokenOut, query.orderHash));
      _beforeIn = SafeTransfer.balanceOf(query.tokenIn, address(VAULT));
      _beforeOut = SafeTransfer.balanceOf(query.tokenOut, address(VAULT));
      _route = id;
      _buy = trade.side == Side.BUY_BASE;
      _cash = _buy ? a.routerOut : a.routerIn;
      _phase = SettlementPhase.AUTHORIZED;
    }
    return (nextPC, payload.length, updatedSwap);
  }

  /*//////////////////////////////////////////////////////////////
                         AUTHENTICATED TRANSFER HOOKS
  //////////////////////////////////////////////////////////////*/

  /// @inheritdoc IMakerHooks
  /// @dev This hook is intentionally disabled in the maker program.
  function preTransferIn(address, address, address, address, uint256, uint256, bytes32, bytes calldata, bytes calldata)
    external
    pure
  {
    revert InvalidCallback();
  }

  /// @inheritdoc IMakerHooks
  /// @dev Only the authenticated router may advance AUTHORIZED -> INPUT_RECEIVED.
  /// Maker input must increase by amountIn minus its prepared input fee; the
  /// other direction has zero input fee. Amounts use raw token units.
  function postTransferIn(
    address maker,
    address taker,
    address tokenIn,
    address tokenOut,
    uint256 amountIn,
    uint256 amountOut,
    uint256 fee,
    bytes32 orderHash,
    bytes calldata makerData,
    bytes calldata takerData
  ) external virtual {
    // Only the canonical router may supply the post-fee pair. Capture the fee
    // as the difference from VM-priced core cash, never recalculate its rate.
    if (msg.sender != ROUTER || _phase != SettlementPhase.AUTHORIZED) revert InvalidCallback();
    _preparedFee = _buy ? _preparedOut - amountOut : amountIn - _preparedIn;
    _hook(
      maker, taker, tokenIn, tokenOut, amountIn, amountOut, orderHash, makerData, takerData, SettlementPhase.AUTHORIZED
    );
    uint256 expectedFee = _buy ? 0 : _preparedFee;
    if (fee != expectedFee || SafeTransfer.balanceOf(tokenIn, address(VAULT)) != _beforeIn + amountIn - expectedFee) {
      revert SettlementMismatch();
    }
    _phase = SettlementPhase.INPUT_RECEIVED;
  }

  /// @inheritdoc IMakerHooks
  /// @dev Authenticate the same exact pair before allowing maker output movement.
  function preTransferOut(
    address maker,
    address taker,
    address tokenIn,
    address tokenOut,
    uint256 amountIn,
    uint256 amountOut,
    bytes32 orderHash,
    bytes calldata makerData,
    bytes calldata takerData
  ) external {
    _hook(
      maker,
      taker,
      tokenIn,
      tokenOut,
      amountIn,
      amountOut,
      orderHash,
      makerData,
      takerData,
      SettlementPhase.INPUT_RECEIVED
    );
    _phase = SettlementPhase.OUTPUT_AUTHORIZED;
  }

  /// @inheritdoc IMakerHooks
  /// @dev Require the exact maker debit before recording inventory/basis. The
  /// operation remains locked through VM fee delivery and the executor's customer payout.
  function postTransferOut(
    address maker,
    address taker,
    address tokenIn,
    address tokenOut,
    uint256 amountIn,
    uint256 amountOut,
    uint256 fee,
    bytes32 orderHash,
    bytes calldata makerData,
    bytes calldata takerData
  ) external virtual {
    _hook(
      maker,
      taker,
      tokenIn,
      tokenOut,
      amountIn,
      amountOut,
      orderHash,
      makerData,
      takerData,
      SettlementPhase.OUTPUT_AUTHORIZED
    );
    uint256 expectedFee = _buy ? _preparedFee : 0;
    if (fee != expectedFee || SafeTransfer.balanceOf(tokenOut, address(VAULT)) != _beforeOut - amountOut - expectedFee)
    {
      revert SettlementMismatch();
    }
    ClaimMarkets.recordTrade(_claimMarkets, _state, _route, _buy, _buy ? amountIn : amountOut, _cash);
    _phase = SettlementPhase.OUTPUT_SENT;
    emit FillSettled(_context, _route, _buy, amountIn, amountOut, _state.positions[_route].version);
  }

  /*//////////////////////////////////////////////////////////////
                         INTERNAL VALIDATION
  //////////////////////////////////////////////////////////////*/

  /// @dev Bind the canonical program and publication salt to one route version.
  /// @param id Approved route index.
  /// @param version Nonzero version that must fit the upstream uint64 salt.
  /// @return Immutable maker order for the pinned official Aqua router instruction set.
  function _order(uint256 id, uint256 version) internal view virtual returns (ISwapVM.Order memory) {
    return HarborProgram.build(
      address(VAULT),
      address(this),
      ASSET,
      ClaimMarkets.base(_claimMarkets, _routes, id),
      id,
      version,
      FEE_RECIPIENT,
      FEE_BPS
    );
  }

  /// @dev Check router, operation, phase and the complete authorized hook tuple.
  /// Amounts are raw token units. Both hook-data blobs must be empty.
  /// The hash commits maker, taker, token direction and order hash. Core amounts
  /// and the fee measured from the router's first hook bind both customer amounts.
  function _hook(
    address maker,
    address taker,
    address tokenIn,
    address tokenOut,
    uint256 amountIn,
    uint256 amountOut,
    bytes32 orderHash,
    bytes calldata makerData,
    bytes calldata takerData,
    SettlementPhase phase
  ) internal view {
    if (
      msg.sender != ROUTER || _operation != Operation.TRADE || _phase != phase || makerData.length != 0
        || takerData.length != 0 || keccak256(abi.encode(maker, taker, tokenIn, tokenOut, orderHash)) != _hookHash
        || amountIn != _preparedIn + (_buy ? 0 : _preparedFee) || amountOut != _preparedOut - (_buy ? _preparedFee : 0)
    ) revert InvalidCallback();
  }
}
