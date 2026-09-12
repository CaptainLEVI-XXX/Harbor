// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {SafeTransferLib as SafeTransfer} from "solady/utils/SafeTransferLib.sol";
import {SwapQuery, SwapRegisters} from "@1inch/swap-vm/src/libs/VM.sol";
import {BookContext as Context} from "src/libraries/BookContext.sol";
import {BookAccounting as Accounting} from "src/libraries/BookAccounting.sol";
import {BookPortfolio} from "src/libraries/BookPortfolio.sol";
import {ClaimMarkets} from "src/libraries/ClaimMarkets.sol";
import {HarborVault} from "src/vault/HarborVault.sol";
import {RouteConfig, Operation, Trade, FillAmounts, Side} from "src/types/HarborTypes.sol";
import {QuoteValidation} from "src/libraries/QuoteValidation.sol";
import {HarborPricing} from "src/swapvm/instructions/HarborPricing.sol";
import {ISwapVM} from "@1inch/swap-vm/src/interfaces/ISwapVM.sol";
import {IHarborClaimFactory} from "src/interfaces/IHarborClaimFactory.sol";

/// @title BookExecution
/// @notice Fixed linked settlement code using Book-owned ledgers and context.
/// @dev Book authenticates the router/executor and rejects nonempty hook data
/// before entering this library. Compiler-linked delegatecalls preserve Book as
/// storage owner, event emitter and Vault caller. No mutable target or separate
/// custody exists; mutating library functions cannot be called directly.
library BookExecution {
  /// @dev Customer pair and maker tuple delivered by the authenticated router.
  struct Hook {
    address maker;
    address taker;
    address tokenIn;
    address tokenOut;
    uint256 amountIn;
    uint256 amountOut;
    bytes32 orderHash;
  }

  error InvalidCallback();
  error Busy();
  error SettlementMismatch();
  event FillSettled(
    bytes32 indexed context, uint256 indexed route, bool buy, uint256 amountIn, uint256 amountOut, uint256 version
  );
  event StrategyPublished(
    uint256 indexed route, bytes32 indexed orderHash, uint256 version, uint256 factoryVersion, uint256 configVersion
  );

  /// @dev Book authenticates Vault/governor and the VAULT lock before entry.
  /// The currentOrder self-read preserves the canonical (and virtual) program builder.
  function publishStrategy(
    Accounting.State storage book,
    ClaimMarkets.State storage markets,
    RouteConfig[] storage routes,
    mapping(uint256 => uint256) storage versions,
    mapping(uint256 => bytes32) storage hashes,
    mapping(uint256 => uint256) storage factoryVersions,
    uint256 id,
    uint256 epoch
  ) public returns (ISwapVM.Order memory order, bytes32 previous, address base, uint256 managed) {
    previous = hashes[id];
    uint256 version = ++versions[id];
    ClaimMarkets.Market storage market = markets.markets[id];
    if (market.factory != address(0)) {
      factoryVersions[id] = IHarborClaimFactory(market.factory).version(market.adapter);
    }
    order = IBookPricing(address(this)).currentOrder(id);
    base = ClaimMarkets.base(markets, routes, id);
    managed = book.positions[id].shares;
    bytes32 hash = keccak256(abi.encode(order));
    hashes[id] = hash;
    emit StrategyPublished(id, hash, version, factoryVersions[id], epoch);
  }

  /// @notice Bind the VM-computed core pair and independent NAV before funding.
  /// @dev Caller proved TRADE/OPENED, exact context, canonical order and VM
  /// maker/taker. Checkpoint precedes authorization just as in the Book entrypoint.
  function authorize(
    address vault,
    uint256 route,
    bool buy,
    SwapQuery calldata query,
    uint256 input,
    uint256 output,
    BookPortfolio.Value memory value,
    bytes32 evidence
  ) public {
    Context.set(Context.EVIDENCE, uint256(evidence));
    HarborVault(vault)
      .checkpointTrade(Context.context(), value.inventory, value.claims, value.observedAt, value.evidence);
    Context.set(Context.INPUT, input);
    Context.set(Context.OUTPUT, output);
    Context.set(
      Context.HOOK_HASH,
      uint256(keccak256(abi.encode(query.maker, query.taker, query.tokenIn, query.tokenOut, query.orderHash)))
    );
    Context.set(Context.BEFORE_IN, SafeTransfer.balanceOf(query.tokenIn, vault));
    Context.set(Context.BEFORE_OUT, SafeTransfer.balanceOf(query.tokenOut, vault));
    Context.set(Context.ROUTE, route);
    Context.set(Context.CASH, buy ? output : input);
    Context.control(Operation.TRADE, Context.Phase.AUTHORIZED, buy);
  }

  /// @dev Book authenticates router/maker/taker before entry. Fixed delegatecall
  /// preserves Book storage and caller; the priceTrade self-call retains its
  /// existing self-only authorization. No new pricing or settlement authority.
  function priceAndAuthorize(
    ClaimMarkets.State storage markets,
    mapping(uint256 => bytes32) storage strategyHashes,
    bool isStaticContext,
    SwapQuery calldata query,
    SwapRegisters calldata swap,
    bytes calldata args,
    bytes calldata payload,
    uint256 feeBps,
    address vault
  ) public returns (SwapRegisters memory updatedSwap) {
    (Trade memory trade, bytes32 context) = QuoteValidation.intent(query, strategyHashes, args, payload);
    if (isStaticContext) {
      if (Context.operation() != Operation.NONE) revert Busy();
    } else if (
      Context.operation() != Operation.TRADE || Context.phase() != Context.Phase.OPENED || Context.context() != context
    ) {
      revert InvalidCallback();
    }
    (FillAmounts memory a, BookPortfolio.Value memory value, bytes32 evidence) =
      IBookPricing(address(this)).priceTrade(trade, true, query.isExactIn ? swap.amountIn : swap.amountOut);
    updatedSwap = HarborPricing.complete(
      swap, trade, a.routerIn, a.routerOut, feeBps, markets.markets[trade.route].factory != address(0)
    );
    if (!isStaticContext) {
      authorize(vault, trade.route, trade.side == Side.BUY_BASE, query, a.routerIn, a.routerOut, value, evidence);
    }
  }

  /// @notice Measure the one VM fee and the actual maker credit after input.
  /// @dev Identity/phase authentication precedes fee subtraction; no fee-rate
  /// arithmetic is duplicated here. The input fee is zero when acquiring base.
  function postInput(address vault, Hook calldata h, uint256 fee) public {
    _identity(h, Context.Phase.AUTHORIZED);
    bool buy = Context.buy();
    uint256 measuredFee = buy ? Context.get(Context.OUTPUT) - h.amountOut : h.amountIn - Context.get(Context.INPUT);
    _amounts(h, buy, measuredFee);
    Context.set(Context.FEE, measuredFee);
    uint256 expectedFee = buy ? 0 : measuredFee;
    if (
      fee != expectedFee
        || SafeTransfer.balanceOf(h.tokenIn, vault) != Context.get(Context.BEFORE_IN) + h.amountIn - expectedFee
    ) {
      revert SettlementMismatch();
    }
    Context.advance(Context.Phase.INPUT_RECEIVED);
  }

  /// @notice Authorize maker output only after the exact input has arrived.
  function preOutput(Hook calldata h) public {
    _identity(h, Context.Phase.INPUT_RECEIVED);
    _amounts(h, Context.buy(), Context.get(Context.FEE));
    Context.advance(Context.Phase.OUTPUT_AUTHORIZED);
  }

  /// @notice Verify maker debit and record the corresponding inventory transition.
  /// @dev Keep the operation locked through subsequent fee and trader payouts.
  function postOutput(
    Accounting.State storage book,
    ClaimMarkets.State storage markets,
    address vault,
    Hook calldata h,
    uint256 fee
  ) public {
    _identity(h, Context.Phase.OUTPUT_AUTHORIZED);
    bool buy = Context.buy();
    uint256 measuredFee = Context.get(Context.FEE);
    _amounts(h, buy, measuredFee);
    uint256 expectedFee = buy ? measuredFee : 0;
    if (
      fee != expectedFee
        || SafeTransfer.balanceOf(h.tokenOut, vault) != Context.get(Context.BEFORE_OUT) - h.amountOut - expectedFee
    ) {
      revert SettlementMismatch();
    }
    uint256 route = Context.get(Context.ROUTE);
    ClaimMarkets.recordTrade(markets, book, route, buy, buy ? h.amountIn : h.amountOut, Context.get(Context.CASH));
    Context.advance(Context.Phase.OUTPUT_SENT);
    emit FillSettled(Context.context(), route, buy, h.amountIn, h.amountOut, book.positions[route].version);
  }

  /// @notice Reobserve after all callbacks and settle Vault cash before unlocking.
  /// @dev Book authenticates executor/context/OUTPUT_SENT; it releases both locks
  /// only after this function returns. Pending recovery is never credited here.
  function finish(
    ClaimMarkets.State storage markets,
    RouteConfig[] storage routes,
    mapping(uint256 => uint256) storage factoryVersions,
    address vault
  ) public returns (uint256 fee) {
    uint256 route = Context.get(Context.ROUTE);
    bool buy = Context.buy();
    BookPortfolio.checkSettlement(
      markets,
      routes,
      route,
      buy,
      Context.get(buy ? Context.INPUT : Context.OUTPUT),
      factoryVersions[route],
      bytes32(Context.get(Context.EVIDENCE))
    );
    HarborVault(vault).settleTrade(Context.context(), buy, Context.get(Context.CASH));
    return Context.get(Context.FEE);
  }

  /// @dev Router and empty hook-data checks belong to the Book entrypoint.
  function _identity(Hook calldata h, Context.Phase phase) private view {
    if (
      Context.operation() != Operation.TRADE || Context.phase() != phase
        || keccak256(abi.encode(h.maker, h.taker, h.tokenIn, h.tokenOut, h.orderHash))
          != bytes32(Context.get(Context.HOOK_HASH))
    ) {
      revert InvalidCallback();
    }
  }

  function _amounts(Hook calldata h, bool buy, uint256 fee) private view {
    if (
      h.amountIn != Context.get(Context.INPUT) + (buy ? 0 : fee)
        || h.amountOut != Context.get(Context.OUTPUT) - (buy ? fee : 0)
    ) revert InvalidCallback();
  }
}

interface IBookPricing {
  function currentOrder(uint256 id) external view returns (ISwapVM.Order memory);
  function priceTrade(Trade calldata trade, bool vmPricing, uint256 specified)
    external
    view
    returns (FillAmounts memory, BookPortfolio.Value memory, bytes32);
}
