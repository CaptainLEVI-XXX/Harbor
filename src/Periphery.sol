// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {SafeTransferLib as SafeTransfer} from "solady/utils/SafeTransferLib.sol";
import {ReentrancyGuardTransient} from "solady/utils/ReentrancyGuardTransient.sol";
import {IWETH} from "@1inch/solidity-utils/contracts/interfaces/IWETH.sol";
import {HarborExecutor} from "src/execution/HarborExecutor.sol";
import {HarborVault} from "src/vault/HarborVault.sol";
import {HarborBook} from "src/book/HarborBook.sol";
import {IHarborNftAdapter} from "src/interfaces/IHarborNftAdapter.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {NftTrade} from "src/types/NftTypes.sol";
import {Trade, AmountMode, Side, FillAmounts} from "src/types/HarborTypes.sol";

/// @title Periphery
/// @notice Native ETH deposits, swaps and claims for registered WETH pools.
/// @dev Trusts the fixed WETH's 1:1 wrap/unwrap semantics and Executor's reviewed pool registry.
/// No durable balances, owner, sweep or delegated execution. Outputs belong to msg.sender.
contract Periphery is ReentrancyGuardTransient {
  address public immutable WETH;
  HarborExecutor public immutable EXECUTOR;

  error InvalidTarget();
  error InvalidIntent();
  error InsufficientOutput();
  error BalanceMismatch();

  /// @notice Links the original caller to Executor events whose trader is this wrapper.
  /// @dev Amounts are raw input/output token units. Refunds are native wei.
  event NativeTrade(address indexed caller, address indexed book, uint256 input, uint256 output, uint256 refund);

  /// @notice Funded claim units consumed and native wei paid; not a new LP share burn.
  event NativeWithdrawal(address indexed caller, address indexed book, uint256 assets, uint256 shares);

  /// @notice Original wallet attribution for the preceding Book NFT settlement.
  /// @dev buyBase is from the Vault's perspective; input/output are whole NFT units or native wei.
  event NativeNftTrade(
    address indexed caller,
    address indexed book,
    uint256 indexed tokenId,
    uint256 route,
    bool buyBase,
    uint256 input,
    uint256 output,
    uint256 fee,
    uint256 refund
  );

  constructor(address weth, address executor) {
    if (weth.code.length == 0 || executor.code.length == 0) revert InvalidTarget();
    WETH = weth;
    EXECUTOR = HarborExecutor(executor);
  }

  /// @notice Deposit all msg.value; mint floor-rounded shares directly to the caller.
  /// @param minShares Minimum acceptable raw LP shares, including the Vault's decimal offset.
  function deposit(address book, uint256 minShares) external payable nonReentrant returns (uint256 shares) {
    HarborVault vault = _vault(book);
    vault.checkpointValuation();
    uint256 beforeWeth = _wrap(address(vault));
    shares = vault.deposit(msg.value, msg.sender);
    if (shares < minShares) revert InsufficientOutput();
    _finish(address(vault), beforeWeth, msg.value);
  }

  /// @notice Mint exact raw LP shares, bounded by msg.value; refund unused ETH to the caller.
  /// @dev Vault rounds the required WETH up. A failing refund reverts the issuance too.
  function mint(address book, uint256 shares) external payable nonReentrant returns (uint256 assets) {
    HarborVault vault = _vault(book);
    vault.checkpointValuation();
    uint256 beforeWeth = _wrap(address(vault));
    assets = vault.mint(shares, msg.sender);
    _finish(address(vault), beforeWeth, assets);
  }

  /// @notice Swap native ETH for tokens/whole receipts, or tokens/whole receipts for native ETH.
  /// @dev Quote with trader=this and receiver=caller. No user signature is forwarded:
  /// this contract is the funding trader, and only the paying caller can receive output.
  /// Native input requires msg.value=amountSpecified (exact in) or maxIn (exact out).
  /// Native output requires zero msg.value and token approval to this contract.
  /// The VM retains all deadline, version, fee, whole-receipt and slippage enforcement.
  function execute(address book, Trade calldata trade)
    external
    payable
    nonReentrant
    returns (uint256 input, uint256 output)
  {
    _vault(book);
    if (trade.trader != address(this) || trade.receiver != msg.sender) revert InvalidIntent();
    if (trade.tokenIn != WETH) {
      if (trade.tokenOut != WETH || msg.value != 0) revert InvalidIntent();
      return _sell(book, trade);
    }
    if (msg.value != (trade.mode == AmountMode.EXACT_IN ? trade.amountSpecified : trade.limitAmount)) {
      revert InvalidIntent();
    }
    uint256 beforeWeth = _wrap(address(EXECUTOR));
    (input, output) = EXECUTOR.execute(book, trade);
    _finish(address(EXECUTOR), beforeWeth, input);
    emit NativeTrade(msg.sender, book, input, output, msg.value - input);
  }

  /// @dev Preview validates the original recipient and sizes collection, not settlement.
  /// Pull only actual input: maxIn may exceed a holder's one indivisible receipt.
  /// The locked VM execution must agree after token callbacks or everything reverts.
  /// Only the payout receiver changes internally, so WETH can be unwrapped here.
  function _sell(address book, Trade calldata trade) private returns (uint256 input, uint256 output) {
    (uint256 quotedIn, uint256 quotedOut,) = EXECUTOR.quoteSwap(book, trade);
    address token = trade.tokenIn;
    uint256 beforeToken = SafeTransfer.balanceOf(token, address(this));
    uint256 beforeWeth = SafeTransfer.balanceOf(WETH, address(this));
    SafeTransfer.safeTransferFrom(token, msg.sender, address(this), quotedIn);
    if (SafeTransfer.balanceOf(token, address(this)) != beforeToken + quotedIn) revert BalanceMismatch();
    SafeTransfer.safeApprove(token, address(EXECUTOR), quotedIn);
    Trade memory settlement = trade;
    settlement.receiver = address(this);
    (input, output) = EXECUTOR.execute(book, settlement);
    SafeTransfer.safeApprove(token, address(EXECUTOR), 0);
    if (input != quotedIn || output != quotedOut || SafeTransfer.balanceOf(token, address(this)) != beforeToken) {
      revert BalanceMismatch();
    }
    _unwrap(beforeWeth, output);
    emit NativeTrade(msg.sender, book, input, output, 0);
  }

  /// @notice Trade one original issuer NFT against native ETH without wrapping the right.
  /// @dev Unlike execute(Trade), this accepts the wallet's direct Book intent:
  /// trader=receiver=msg.sender, so an owned NFT can be quoted before moving it.
  /// Selling requires NFT approval to Periphery and zero ETH. Buying requires
  /// exact-input ETH or the exact-output maxIn budget; unused ETH is refunded.
  function executeNft(address book, NftTrade calldata trade)
    external
    payable
    nonReentrant
    returns (uint256 input, uint256 output)
  {
    _vault(book);
    if (trade.trader != msg.sender || trade.receiver != msg.sender) revert InvalidIntent();
    HarborBook target = HarborBook(book);
    NftTrade memory settlement = trade;
    settlement.trader = address(this);
    FillAmounts memory amounts;
    uint256 refund;
    if (trade.side == Side.BUY_BASE) {
      if (msg.value != 0) revert InvalidIntent();
      FillAmounts memory preview = target.quoteNft(trade);
      address adapter = target.route(trade.route).adapter;
      IERC721 token = IERC721(IHarborNftAdapter(adapter).ISSUER());
      uint256 beforeWeth = SafeTransfer.balanceOf(WETH, address(this));
      // Known transient custodian; transferFrom avoids exposing a general NFT
      // receiver. The Book sale and ETH payout must complete in this transaction.
      token.transferFrom(msg.sender, address(this), trade.tokenId);
      if (token.ownerOf(trade.tokenId) != address(this)) revert BalanceMismatch();
      token.approve(adapter, trade.tokenId);
      settlement.receiver = address(this);
      amounts = target.executeNft(settlement);
      if (
        amounts.traderIn != preview.traderIn || amounts.traderOut != preview.traderOut || amounts.fee != preview.fee
          || token.ownerOf(trade.tokenId) != adapter
      ) revert BalanceMismatch();
      _unwrap(beforeWeth, amounts.traderOut);
    } else {
      if (msg.value != (trade.mode == AmountMode.EXACT_IN ? trade.amountSpecified : trade.limitAmount)) {
        revert InvalidIntent();
      }
      uint256 beforeWeth = _wrap(book);
      amounts = target.executeNft(settlement);
      _finish(book, beforeWeth, amounts.traderIn);
      refund = msg.value - amounts.traderIn;
    }
    emit NativeNftTrade(
      msg.sender,
      book,
      trade.tokenId,
      trade.route,
      trade.side == Side.BUY_BASE,
      amounts.traderIn,
      amounts.traderOut,
      amounts.fee,
      refund
    );
    return (amounts.traderIn, amounts.traderOut);
  }

  /// @notice Claim exact funded WETH as native ETH. Requires Vault operator approval.
  /// @dev Only msg.sender's credit is accessible. No freshness checkpoint or queue bypass:
  /// already-funded claims remain payable during a valuation outage.
  function withdraw(address book, uint256 assets) external nonReentrant returns (uint256 shares) {
    HarborVault vault = _vault(book);
    uint256 beforeWeth = SafeTransfer.balanceOf(WETH, address(this));
    shares = vault.withdraw(assets, address(this), msg.sender);
    _unwrap(beforeWeth, assets);
    emit NativeWithdrawal(msg.sender, book, assets, shares);
  }

  /// @notice Redeem exact funded claim units as native ETH, respecting minimum proceeds.
  /// @param shares Funded claim units, not the caller's transferable LP balance.
  function redeem(address book, uint256 shares, uint256 minAssets) external nonReentrant returns (uint256 assets) {
    HarborVault vault = _vault(book);
    uint256 beforeWeth = SafeTransfer.balanceOf(WETH, address(this));
    assets = vault.redeem(shares, address(this), msg.sender);
    if (assets < minAssets) revert InsufficientOutput();
    _unwrap(beforeWeth, assets);
    emit NativeWithdrawal(msg.sender, book, assets, shares);
  }

  /// @dev Registry admission authenticates the target; an arbitrary asset() getter does not.
  function _vault(address book) private view returns (HarborVault vault) {
    address target = EXECUTOR.vaultOf(book);
    if (target == address(0)) revert InvalidTarget();
    vault = HarborVault(target);
    if (vault.asset() != WETH) revert InvalidTarget();
  }

  function _wrap(address spender) private returns (uint256 beforeWeth) {
    if (msg.value == 0) revert InvalidIntent();
    beforeWeth = SafeTransfer.balanceOf(WETH, address(this));
    IWETH(WETH).deposit{value: msg.value}();
    SafeTransfer.safeApprove(WETH, spender, msg.value);
  }

  /// @dev Only this call's unspent principal is refunded. Pre-existing WETH/forced ETH
  /// cannot be swept. The guard stays held through unwrap and the full-gas ETH refund.
  /// Exact approvals bound spending; the delta also checks the target's reported consumption.
  function _finish(address spender, uint256 beforeWeth, uint256 spent) private {
    SafeTransfer.safeApprove(WETH, spender, 0);
    uint256 refund = msg.value - spent;
    _unwrap(beforeWeth, refund);
  }

  /// @dev Retain pre-existing WETH, unwrap only measured proceeds. The shared guard
  /// covers both external calls; recipient rejection rolls back the Vault's credit debit.
  function _unwrap(uint256 beforeWeth, uint256 assets) private {
    if (SafeTransfer.balanceOf(WETH, address(this)) != beforeWeth + assets) revert BalanceMismatch();
    if (assets != 0) {
      IWETH(WETH).withdraw(assets);
      SafeTransfer.safeTransferETH(msg.sender, assets);
    }
  }

  /// @dev WETH9-style withdraw may use a 2,300-gas transfer. No storage writes here.
  receive() external payable {
    if (msg.sender != WETH) revert InvalidTarget();
  }

  function _useTransientReentrancyGuardOnlyOnMainnet() internal pure override returns (bool) {
    return false;
  }
}
