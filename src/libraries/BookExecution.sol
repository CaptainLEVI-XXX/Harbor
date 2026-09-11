// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {SafeTransferLib as SafeTransfer} from "solady/utils/SafeTransferLib.sol";
import {SwapQuery} from "@1inch/swap-vm/src/libs/VM.sol";
import {BookContext as Context} from "src/libraries/BookContext.sol";
import {BookAccounting as Accounting} from "src/libraries/BookAccounting.sol";
import {BookPortfolio} from "src/libraries/BookPortfolio.sol";
import {ClaimMarkets} from "src/libraries/ClaimMarkets.sol";
import {HarborVault} from "src/vault/HarborVault.sol";
import {RouteConfig, Operation} from "src/types/HarborTypes.sol";

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
  error SettlementMismatch();
  event FillSettled(
    bytes32 indexed context, uint256 indexed route, bool buy, uint256 amountIn, uint256 amountOut, uint256 version
  );

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
    BookPortfolio.Value calldata value,
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
