// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {IHarborBook} from "src/interfaces/IHarborBook.sol";

import {SafeTransferLib as SafeTransfer} from "solady/utils/SafeTransferLib.sol";
import {ISwapVM} from "@1inch/swap-vm/src/interfaces/ISwapVM.sol";
import {IMakerHooks} from "@1inch/swap-vm/src/interfaces/IMakerHooks.sol";
import {IHarborFill} from "src/interfaces/IHarborFill.sol";
import {SwapQuery} from "@1inch/swap-vm/src/libs/VM.sol";
import {BookAccounting as Accounting} from "src/libraries/BookAccounting.sol";
import {QuoteHash} from "src/libraries/QuoteHash.sol";
import {HarborProgram} from "src/swapvm/HarborProgram.sol";
import {Trade, FillTerms, Side, AmountMode, Operation} from "src/types/HarborTypes.sol";
import {BookState} from "src/book/base/BookState.sol";
import {ClaimMarkets} from "src/libraries/ClaimMarkets.sol";
import {BookPortfolio} from "src/libraries/BookPortfolio.sol";
import {IHarborClaimFactory} from "src/interfaces/IHarborClaim.sol";

/// @title BookSettlement
/// @notice Aqua strategy publication, exact-fill authorization and transfer hooks.
/// @dev The custom VM instruction owns register completion. This module owns the
/// quote mandate, replay protection, portfolio budgets and measured accounting.
abstract contract BookSettlement is BookState, IHarborFill, IMakerHooks {
  using Accounting for Accounting.State;

  /*//////////////////////////////////////////////////////////////
                         STRATEGY & EXECUTOR
  //////////////////////////////////////////////////////////////*/

  /// @notice Rebuild the canonical order for the current route version.
  /// @param id Approved route identifier.
  /// @return Maker order whose encoded hash is registered in Aqua.
  function currentOrder(uint256 id) public view returns (ISwapVM.Order memory) {
    return _order(id, strategyVersion[id]);
  }

  /// @inheritdoc IHarborBook
  /// @dev Executor only; acquiring the shared lock precedes all token callbacks.
  function beginTrade(bytes32 tradeHash) external {
    if (msg.sender != address(EXECUTOR)) revert Unauthorized();
    _open(tradeHash, Operation.TRADE);
    _phase = SettlementPhase.OPENED;
  }

  /// @inheritdoc IHarborBook
  /// @dev Executor only, after output hooks and all trader/fee payouts. The Vault
  /// checks its net cash delta before either contract releases its operation lock.
  function finishTrade(bytes32 digest) external {
    if (
      msg.sender != address(EXECUTOR) || _operation != Operation.TRADE || _phase != SettlementPhase.OUTPUT_SENT
        || digest != _digest
    ) {
      revert Unauthorized();
    }
    if (_claimMarkets.markets[_route].factory != address(0)) {
      BookPortfolio.receiptCheck(_claimMarkets, _route, _buy, 1, _cash, strategyFactoryVersion[_route], WETH);
    }
    VAULT.settleTrade(_context, _buy, _cash);
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
    if (factory != address(0)) strategyFactoryVersion[id] = IHarborClaimFactory(factory).version();
    order = _order(id, version);
    base = ClaimMarkets.base(_claimMarkets, _routes, id);
    managed = _state.positions[id].shares;
    strategyHash[id] = keccak256(abi.encode(order));
    ++quoteEpoch;
    emit StrategyRegistered(id, strategyHash[id], version);
  }

  /// @inheritdoc IHarborBook
  /// @dev Public idle-state preflight only; does not reserve cash or consume a nonce.
  function validate(Trade calldata trade, FillTerms calldata terms, bytes calldata signature)
    external
    view
    returns (bytes32)
  {
    if (_operation != Operation.NONE) revert Busy();
    return _validate(trade, terms, signature);
  }

  /*//////////////////////////////////////////////////////////////
                         NATIVE FILL AUTHORIZATION
  //////////////////////////////////////////////////////////////*/

  /// @inheritdoc IHarborFill
  function authorizeFill(
    bool isStaticContext,
    SwapQuery calldata query,
    uint256 id,
    uint256 version,
    bytes calldata payload
  ) external returns (uint256 amountIn, uint256 amountOut) {
    if (msg.sender != ROUTER || query.maker != address(VAULT) || query.taker != address(EXECUTOR)) {
      revert InvalidCallback();
    }
    if (payload.length > 4096) revert InvalidQuote();
    (Trade memory trade, FillTerms memory terms, bytes memory signature) =
      abi.decode(payload, (Trade, FillTerms, bytes));
    if (keccak256(payload) != keccak256(abi.encode(trade, terms, signature))) revert InvalidQuote();
    if (
      id != trade.route || version != terms.strategyVersion || query.orderHash != terms.orderHash
        || query.tokenIn != trade.tokenIn || query.tokenOut != trade.tokenOut
        || query.isExactIn != (trade.mode == AmountMode.EXACT_IN)
    ) revert InvalidQuote();
    if (isStaticContext) {
      if (_operation != Operation.NONE) revert Busy();
    } else if (
      _operation != Operation.TRADE || _phase != SettlementPhase.OPENED || _context != QuoteHash.tradeHash(trade)
    ) {
      revert InvalidCallback();
    }
    bytes32 digest = _validate(trade, terms, signature);
    if (!isStaticContext) {
      usedQuoteNonce[terms.epoch][terms.nonce] = true;
      usedTraderNonce[trade.trader][trade.nonce] = true;
      _digest = digest;
      _phase = SettlementPhase.AUTHORIZED;
      _hookHash = keccak256(
        abi.encode(
          query.maker, query.taker, query.tokenIn, query.tokenOut, terms.routerIn, terms.routerOut, query.orderHash
        )
      );
      _beforeIn = SafeTransfer.balanceOf(query.tokenIn, address(VAULT));
      _beforeOut = SafeTransfer.balanceOf(query.tokenOut, address(VAULT));
      _route = id;
      _buy = trade.side == Side.BUY_BASE;
      _cash = _buy ? terms.routerOut : terms.routerIn;
    }
    return (terms.routerIn, terms.routerOut);
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
  /// Maker input must increase by exactly amountIn raw units. VM protocol fees are
  /// disabled: Harbor's executor pays the separately authorized WETH fee.
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
  ) external {
    _hook(
      maker, taker, tokenIn, tokenOut, amountIn, amountOut, orderHash, makerData, takerData, SettlementPhase.AUTHORIZED
    );
    if (fee != 0 || SafeTransfer.balanceOf(tokenIn, address(VAULT)) != _beforeIn + amountIn) {
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
  /// operation remains locked until the executor pays the user and fee recipient.
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
      SettlementPhase.OUTPUT_AUTHORIZED
    );
    if (fee != 0 || SafeTransfer.balanceOf(tokenOut, address(VAULT)) != _beforeOut - amountOut) {
      revert SettlementMismatch();
    }
    if (_claimMarkets.markets[_route].factory != address(0)) {
      if (_buy) ClaimMarkets.acquire(_claimMarkets, _state, _route, amountOut, false);
      else ClaimMarkets.dispose(_claimMarkets, _state, _route, amountIn, false);
    } else if (_buy) {
      _state.buy(_route, amountIn, amountOut);
    } else {
      _state.sell(_route, amountOut, amountIn);
    }
    _phase = SettlementPhase.OUTPUT_SENT;
    emit FillSettled(_digest, _route, _buy, amountIn, amountOut, _state.version);
  }

  /*//////////////////////////////////////////////////////////////
                         INTERNAL VALIDATION
  //////////////////////////////////////////////////////////////*/

  /// @notice Check immutable mandate, replay protection and live portfolio capacity.
  /// @dev Deliberately repeated at execution: preflight does not reserve state.
  /// The executor helper verifies signatures and public price bounds; this Book
  /// independently checks the receiver permit and all persistent spending budgets.
  /// @param t Trader intent; amounts use token raw units.
  /// @param f Signed exact pair, authority bindings, fee and observation identity.
  /// @param signature Bounded signature for the current quote signer.
  /// @return digest Fully domain-separated authorized fill identity.
  function _validate(Trade memory t, FillTerms memory f, bytes memory signature) private view returns (bytes32 digest) {
    if (
      stopped || t.route >= INVENTORY_ROUTES + _claimMarkets.count || signature.length > 1024 || signature.length == 0
    ) {
      revert InvalidQuote();
    }
    address factory = _claimMarkets.markets[t.route].factory;
    address adapter = factory == address(0) ? _routes[t.route].adapter : factory;
    address base = ClaimMarkets.base(_claimMarkets, _routes, t.route);
    if (
      t.trader == adapter || t.receiver == adapter || t.trader == AQUA || t.receiver == AQUA
        || t.trader == address(RECEIVER) || t.receiver == address(RECEIVER)
    ) revert InvalidQuote();
    Accounting.Position storage p = _state.positions[t.route];
    if (
      f.vault != address(VAULT) || f.adapter != adapter
        || f.adapterVersion != (factory == address(0) ? 1 : strategyFactoryVersion[t.route])
        || f.strategyVersion != strategyVersion[t.route] || f.orderHash == 0 || f.orderHash != strategyHash[t.route]
        || f.epoch != quoteEpoch || usedQuoteNonce[f.epoch][f.nonce] || usedTraderNonce[t.trader][t.nonce]
        || f.portfolioVersion != _state.version || f.positionVersion != p.version || f.policyVersion != 1
        || f.feeRecipient != FEE_RECIPIENT || f.feeBps != FEE_BPS || block.timestamp > t.deadline
        || f.validUntil > t.deadline || block.timestamp > f.validUntil || f.observedAt > block.timestamp
        || f.observedAt == 0 || f.validUntil < f.observedAt || f.validUntil - f.observedAt > MAX_QUOTE_AGE
    ) revert InvalidQuote();
    bool buy = t.side == Side.BUY_BASE;
    if (t.tokenIn != (buy ? base : WETH) || t.tokenOut != (buy ? WETH : base)) revert InvalidQuote();
    uint256 quantity = buy ? f.routerIn : f.routerOut;
    uint256 cash = buy ? f.routerOut : f.routerIn;
    if (factory != address(0)) {
      BookPortfolio.receiptCheck(_claimMarkets, t.route, buy, quantity, cash, f.adapterVersion, WETH);
    }
    BookPortfolio.capacity(
      _state,
      _claimMarkets,
      _routes,
      INVENTORY_ROUTES,
      t.route,
      buy,
      quantity,
      cash,
      buy ? VAULT.tradingCash(CASH_BUFFER) : 0,
      MAX_EXPOSURE,
      address(VAULT)
    );
    digest = EXECUTOR.validateQuote(t, f, signature, quoteSigner);
    if (!RECEIVER.isApproved(digest)) revert PolicyNotApproved();
  }

  /// @dev Bind the canonical program and publication salt to one route version.
  /// @param id Approved route index.
  /// @param version Nonzero version that must fit the upstream uint64 salt.
  /// @return Immutable maker order for the Harbor custom router.
  function _order(uint256 id, uint256 version) private view returns (ISwapVM.Order memory) {
    if (version == 0 || version > type(uint64).max) revert InvalidConfiguration();
    address factory = _claimMarkets.markets[id].factory;
    if (factory != address(0)) {
      return HarborProgram.claim(
        address(VAULT),
        address(this),
        WETH,
        _claimMarkets.markets[id].receipt,
        id,
        version,
        factory,
        strategyFactoryVersion[id]
      );
    }
    return HarborProgram.build(address(VAULT), address(this), WETH, _routes[id].base, id, version, uint64(version));
  }

  /// @dev Check router, operation, phase and the complete authorized hook tuple.
  /// Amounts are raw token units. Both hook-data blobs must be empty.
  /// The hash commits maker, taker, token direction, both amounts and order hash.
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
  ) private view {
    if (
      msg.sender != ROUTER || _operation != Operation.TRADE || _phase != phase || makerData.length != 0
        || takerData.length != 0
        || keccak256(abi.encode(maker, taker, tokenIn, tokenOut, amountIn, amountOut, orderHash)) != _hookHash
    ) revert InvalidCallback();
  }
}
