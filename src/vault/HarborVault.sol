// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {FixedPointMathLib as Math} from "solady/utils/FixedPointMathLib.sol";
import {SafeTransferLib as SafeTransfer} from "solady/utils/SafeTransferLib.sol";
import {VaultLedger as Accounting} from "src/libraries/VaultLedger.sol";
import {LPExitQueue as Queue} from "src/libraries/LPExitQueue.sol";
import {VaultCore} from "src/vault/base/VaultCore.sol";

/// @title HarborVault
/// @notice Synchronous LP issuance, asynchronous exits and coherent public share views.
/// @dev Treasury callbacks live in VaultCore; all modules share VaultCore.
/// Pending issuer claims are not spendable cash and cannot directly fund exits.
contract HarborVault is VaultCore {
  using Accounting for Accounting.State;
  using Queue for Queue.State;

  /// @notice Deploy synchronous issuance and asynchronous LP redemption.
  /// @param cashAsset Approved cash asset.
  /// @param book Immutable accounting and settlement coordinator.
  /// @param maxAge Maximum public mark age, seconds.
  /// @param minSeed Minimum first deposit, settlement-asset raw units.
  /// @param minRequest Minimum exit request, LP share raw units; full exits are exempt.
  constructor(address cashAsset, address book, uint256 maxAge, uint256 minSeed, uint256 minRequest)
    VaultCore(cashAsset, book, maxAge, minSeed, minRequest)
  {}

  /*//////////////////////////////////////////////////////////////
                         SHARE & VALUATION VIEWS
  //////////////////////////////////////////////////////////////*/

  /// @notice LP share name; independent of the underlying token's metadata.
  function name() public pure override returns (string memory) {
    return "Harbor Vault";
  }

  /// @notice LP share ticker; not a promise of a fixed asset/share exchange rate.
  function symbol() public pure override returns (string memory) {
    return "hVAULT";
  }

  /// @notice Approved ASSET cash asset for issuance and funded claims.
  function asset() public view override returns (address) {
    return ASSET;
  }

  /// @notice ERC-7575 share token is this same vault.
  function share() external view returns (address) {
    return address(this);
  }

  /// @notice ERC-7575 discovery; returns zero for unsupported assets.
  /// @param token Asset to resolve.
  function vault(address token) external view returns (address) {
    return token == ASSET ? address(this) : address(0);
  }

  /// @dev Six extra share decimals implement the virtual-share inflation defense.
  function _decimalsOffset() internal pure override returns (uint8) {
    return 6;
  }

  /// @dev Approved asset metadata is fixed at deployment; LP precision is asset + 6.
  function _underlyingDecimals() internal view override returns (uint8) {
    return _assetDecimals;
  }

  /// @dev No implicit third-party share allowance; all spenders require approval.
  function _givePermit2InfiniteAllowance() internal pure override returns (bool) {
    return false;
  }

  /// @notice Committed numerator and denominator stay coherent during callbacks.
  function totalAssets() public view override returns (uint256) {
    return _state.nav;
  }

  /// @notice Committed LP supply, coherent with the cached NAV during callbacks.
  function totalSupply() public view override returns (uint256) {
    return _state.supply;
  }

  /// @notice Convert settlement-asset raw units to LP share raw units, rounding down.
  /// @dev Uses committed NAV/supply plus one virtual wei and 1e6 virtual shares.
  function convertToShares(uint256 assets) public view override returns (uint256) {
    return Math.fullMulDiv(assets, _state.supply + VIRTUAL_SHARES, _state.nav + 1);
  }

  /// @notice Convert LP share raw units to settlement-asset raw units, rounding down.
  /// @dev This is a valuation conversion, not a synchronous withdrawal entitlement.
  function convertToAssets(uint256 shares) public view override returns (uint256) {
    return Math.fullMulDiv(shares, _state.nav + 1, _state.supply + VIRTUAL_SHARES);
  }

  /// @notice settlement-asset raw units required for exact LP shares, rounding up.
  function previewMint(uint256 shares) public view override returns (uint256) {
    return Math.fullMulDivUp(shares, _state.nav + 1, _state.supply + VIRTUAL_SHARES);
  }

  /// @notice Revert: asynchronous exits have no synchronous asset-input preview.
  function previewWithdraw(uint256) public pure override returns (uint256) {
    revert AsyncPreview();
  }

  /// @notice Revert: asynchronous exits have no synchronous share-input preview.
  function previewRedeem(uint256) public pure override returns (uint256) {
    revert AsyncPreview();
  }

  /// @notice ERC165, ERC7540 operator/async-redeem and ERC7575 discovery.
  /// @dev Does not advertise asynchronous deposits or full synchronous ERC4626 exits.
  function supportsInterface(bytes4 id) external pure returns (bool) {
    return id == 0x01ffc9a7 || id == 0x2f0a18c5 || id == 0xf815c03d || id == 0xe3bc4e65 || id == 0x620ee8e4;
  }

  /// @notice Separate telemetry; stale views are not executable prices.
  function accountingStatus()
    external
    view
    returns (uint256 cash, uint256 reserved, uint256 pending, bool valid, bool insolvent)
  {
    bool cashDeficit = SafeTransfer.balanceOf(ASSET, address(this)) < _state.cash;
    return (
      _state.cash,
      _state.withdrawals.reserved,
      _state.withdrawals.totalPending,
      _fresh() && !cashDeficit && _context == 0,
      _state.insolvent || cashDeficit
    );
  }

  /// @notice Available deposit capacity in settlement-asset raw units; zero while gated or stale.
  function maxDeposit(address receiver) public view override returns (uint256) {
    if (!_issuanceAvailable(receiver)) return 0;
    (uint256 assets,) = _state.headroom();
    return assets;
  }

  /// @notice Exact LP shares issuable within asset and share numerical headroom.
  /// @dev Mint rounds assets up: it may fit when no floor-rounded deposit fits.
  function maxMint(address receiver) public view override returns (uint256) {
    if (!_issuanceAvailable(receiver)) return 0;
    (, uint256 shares) = _state.headroom();
    return shares;
  }

  /// @notice Funded claim cash in settlement-asset raw units, not the controller's unfunded NAV.
  function maxWithdraw(address controller) public view override returns (uint256) {
    if (_context != 0 || SafeTransfer.balanceOf(ASSET, address(this)) < _state.withdrawals.reserved) return 0;
    return _state.withdrawals.credits[controller].assets;
  }

  /// @notice Funded claim units, not the controller's transferable LP balance.
  function maxRedeem(address controller) public view override returns (uint256) {
    if (_context != 0 || SafeTransfer.balanceOf(ASSET, address(this)) < _state.withdrawals.reserved) return 0;
    return _state.withdrawals.credits[controller].units;
  }

  /*//////////////////////////////////////////////////////////////
                         SYNCHRONOUS ISSUANCE
  //////////////////////////////////////////////////////////////*/

  /// @notice Deposit exact settlement-asset raw units and mint LP shares rounded down.
  /// @param assets Exact settlement-asset raw units collected from the caller.
  /// @param receiver Beneficiary of newly minted LP shares.
  /// @return shares LP share raw units minted.
  function deposit(uint256 assets, address receiver) public override coordinated returns (uint256 shares) {
    shares = previewDeposit(assets);
    _issue(assets, shares, receiver, msg.sender);
  }

  /// @notice Mint exact LP share units and collect settlement-asset raw units rounded up.
  /// @param shares Exact LP share raw units to mint.
  /// @param receiver Beneficiary of newly minted LP shares.
  /// @return assets settlement-asset raw units collected.
  function mint(uint256 shares, address receiver) public override coordinated returns (uint256 assets) {
    assets = previewMint(shares);
    _issue(assets, shares, receiver, msg.sender);
  }

  /// @notice Deposit exact settlement-asset raw units and mint LP shares rounded down.
  /// @param assets Exact settlement-asset raw units collected from the caller.
  /// @param receiver Beneficiary of newly minted LP shares.
  /// @param controller Caller or its delegating ERC7540 controller; caller supplies funds.
  /// @return shares LP share raw units minted.
  function deposit(uint256 assets, address receiver, address controller) external coordinated returns (uint256 shares) {
    _authorize(controller);
    shares = previewDeposit(assets);
    _issue(assets, shares, receiver, controller);
  }

  /// @notice Mint exact LP share units and collect settlement-asset raw units rounded up.
  /// @param shares Exact LP share raw units to mint.
  /// @param receiver Beneficiary of newly minted LP shares.
  /// @param controller Caller or its delegating ERC7540 controller; caller supplies funds.
  /// @return assets settlement-asset raw units collected.
  function mint(uint256 shares, address receiver, address controller) external coordinated returns (uint256 assets) {
    _authorize(controller);
    assets = previewMint(shares);
    _issue(assets, shares, receiver, controller);
  }

  /*//////////////////////////////////////////////////////////////
                         ASYNCHRONOUS REDEMPTION
  //////////////////////////////////////////////////////////////*/

  /// @notice Request ID is always zero; internal FIFO tickets remain distinct.
  /// @dev Escrow without burning. Owner/operator or explicit share allowance may
  /// request; share allowance alone cannot claim a controller's later credit.
  /// @param shares LP share raw units to escrow.
  /// @param controller Beneficiary of pending and funded claim credits.
  /// @param owner Account whose LP shares are escrowed.
  /// @return Public request ID zero, aggregating this controller's internal tickets.
  function requestRedeem(uint256 shares, address controller, address owner) external coordinated returns (uint256) {
    if (!_receiverValid(controller) || owner == address(this)) revert InvalidReceiver();
    if (shares == 0 || (shares < MIN_REQUEST_SHARES && shares != balanceOf(owner))) revert InvalidAmount();
    if (msg.sender != owner && !isOperator[owner][msg.sender]) _spendAllowance(owner, msg.sender, shares);
    _shareMutation = true;
    _transfer(owner, address(this), shares);
    _shareMutation = false;
    uint256 ticket = _state.withdrawals.append(controller, shares);
    emit RedeemRequest(controller, owner, 0, msg.sender, shares);
    emit WithdrawalQueued(ticket, controller, owner, msg.sender, shares);
    return 0;
  }

  /// @notice Unfunded LP share units for requestId zero; other IDs return zero.
  function pendingRedeemRequest(uint256 requestId, address controller) external view returns (uint256) {
    return requestId == 0 ? _state.withdrawals.credits[controller].pending : 0;
  }

  /// @notice Funded claim units for requestId zero; other IDs return zero.
  function claimableRedeemRequest(uint256 requestId, address controller) external view returns (uint256) {
    return requestId == 0 ? _state.withdrawals.credits[controller].units : 0;
  }

  /// @notice Current FIFO range [head, tail); completed ticket payloads are not retained.
  function withdrawalQueueBounds() external view returns (uint256 head, uint256 tail) {
    return (_state.withdrawals.head, _state.withdrawals.tail);
  }

  /// @notice Read up to 32 live FIFO tickets without a historical indexer.
  /// @dev Pin all pages to one block. Start at head; stale cursors below head revert.
  /// @param cursor Internal ticket ID, between current head and tail inclusive.
  /// @param limit Page size, 1..32. Ticket IDs are cursor plus the returned array index.
  /// @return tickets Controller and still-pending LP units for each live ticket.
  /// @return next Cursor after this page; equals tail when complete.
  function withdrawalTickets(uint256 cursor, uint256 limit)
    external
    view
    returns (Queue.Ticket[] memory tickets, uint256 next)
  {
    return _state.withdrawals.page(cursor, limit);
  }

  /// @notice Grant or revoke ERC7540 operator authority for the caller.
  /// @param operator Account allowed to act for this controller.
  /// @param approved New operator permission.
  /// @return True when the permission is recorded.
  function setOperator(address operator, bool approved) external localOperation returns (bool) {
    isOperator[msg.sender][operator] = approved;
    emit OperatorSet(msg.sender, operator, approved);
    return true;
  }

  /// @notice Fund up to eight oldest tickets at the same fresh pre-operation mark.
  /// @dev Permissionless FIFO funding: burn escrow shares and reserve actual cash.
  /// Remaining issuer rights contribute no spendable cash. Partial head funding
  /// stops the batch; no later ticket may jump the queue.
  /// @param maxTickets Maximum tickets processed, between one and eight.
  function fulfillWithdrawals(uint256 maxTickets) external coordinated {
    if (maxTickets == 0 || maxTickets > Queue.MAX_PROCESS) revert InvalidAmount();
    _requireFresh();
    _state.requireBacked(SafeTransfer.balanceOf(ASSET, address(this)));
    Queue.State storage q = _state.withdrawals;
    uint256 numerator = _state.nav == 0 ? 0 : _state.nav + 1;
    uint256 denominator = _state.supply + VIRTUAL_SHARES;
    for (uint256 i; i < maxTickets && q.head < q.tail; ++i) {
      uint256 ticket = q.head;
      uint256 pending = q.tickets[ticket].pending;
      (uint256 shares, uint256 assets) = Queue.fundable(pending, _state.available(0), numerator, denominator);
      if (shares == 0) break;
      address controller = q.fundHead(shares, assets);
      _shareMutation = true;
      _burn(address(this), shares);
      _shareMutation = false;
      emit WithdrawalFunded(ticket, controller, shares, assets, pending - shares);
      if (shares != pending) break;
    }
  }

  /// @notice Claim ASSET using exact funded claim units; not another LP share burn.
  /// @dev Credit conversion rounds assets down; the queue prevents stranded final cash.
  /// @param shares Funded claim units to consume.
  /// @param receiver ASSET beneficiary chosen by controller/operator.
  /// @param controller Owner of the funded credit.
  /// @return assets settlement-asset raw units paid from reserved cash.
  function redeem(uint256 shares, address receiver, address controller)
    public
    override
    coordinated
    returns (uint256 assets)
  {
    uint256 balance = _claimChecks(receiver, controller);
    assets = _state.withdrawals.redeem(controller, shares);
    _payClaim(assets, shares, receiver, controller, balance);
  }

  /// @notice Claim exact settlement-asset raw units from a controller's funded credit.
  /// @dev Required claim units round up; unrelated LP balances are not burned.
  /// @param assets Exact settlement-asset raw units requested.
  /// @param receiver ASSET beneficiary chosen by controller/operator.
  /// @param controller Owner of the funded credit.
  /// @return shares Funded claim units consumed, rounded up.
  function withdraw(uint256 assets, address receiver, address controller)
    public
    override
    coordinated
    returns (uint256 shares)
  {
    uint256 balance = _claimChecks(receiver, controller);
    shares = _state.withdrawals.withdraw(controller, assets);
    _payClaim(assets, shares, receiver, controller, balance);
  }

  /*//////////////////////////////////////////////////////////////
                         SHARE TRANSFERS & CHECKPOINT
  //////////////////////////////////////////////////////////////*/

  /// @notice Transfer LP share raw units under the shared operation lock.
  function transfer(address receiver, uint256 shares) public override localOperation returns (bool) {
    if (!_receiverValid(receiver)) revert InvalidReceiver();
    _shareMutation = true;
    _transfer(msg.sender, receiver, shares);
    _shareMutation = false;
    return true;
  }

  /// @notice Allowance-authorized LP share transfer under the shared operation lock.
  function transferFrom(address owner, address receiver, uint256 shares) public override localOperation returns (bool) {
    if (!_receiverValid(receiver) || owner == address(this)) revert InvalidReceiver();
    _spendAllowance(owner, msg.sender, shares);
    _shareMutation = true;
    _transfer(owner, receiver, shares);
    _shareMutation = false;
    return true;
  }

  /// @notice Anyone may checkpoint authenticated public observations from the Book.
  /// @dev A fresh public mark is required, not a signer-supplied private NAV.
  function checkpointValuation() external coordinated {
    (uint256 inventory, uint256 claims, uint256 time, bytes32 evidence, bool valid) = BOOK.valuation();
    if (!valid) revert ValuationUnavailable();
    _checkpoint(inventory, claims, time, evidence);
  }

  /*//////////////////////////////////////////////////////////////
                         INTERNAL LP ACCOUNTING
  //////////////////////////////////////////////////////////////*/

  /// @dev Shared eligibility for idle max views, not a substitute for _issue's
  /// under-lock checks. Each view applies its own floor/ceil capacity afterward.
  function _issuanceAvailable(address receiver) private view returns (bool) {
    return _context == 0 && _receiverValid(receiver) && _fresh()
      && SafeTransfer.balanceOf(ASSET, address(this)) >= _state.cash && !_orphaned();
  }

  /// @dev Collect exact settlement-asset raw units from msg.sender, then mint shares to receiver.
  /// Controller affects authorization/event identity, not who funds the deposit.
  /// Caller supplies amounts computed with the public deposit/mint rounding rules.
  function _issue(uint256 assets, uint256 shares, address receiver, address controller) private {
    _requireFresh();
    if (!_receiverValid(receiver)) revert InvalidReceiver();
    (uint256 assetRoom, uint256 shareRoom) = _state.issuanceLimits();
    if (assets == 0 || shares == 0 || assets > assetRoom || shares > shareRoom) {
      revert InvalidAmount();
    }
    if (_orphaned()) revert OrphanedPortfolio();
    if (_state.supply == 0 && assets < MIN_INITIAL_ASSETS) revert InvalidAmount();
    uint256 beforeBalance = SafeTransfer.balanceOf(ASSET, address(this));
    _state.requireBacked(beforeBalance);
    SafeTransfer.safeTransferFrom(ASSET, msg.sender, address(this), assets);
    if (SafeTransfer.balanceOf(ASSET, address(this)) != beforeBalance + assets) revert AssetDeltaMismatch();
    _requireFresh();
    _state.cash += assets; // Issuance cash flow is not portfolio profit or a new mark.
    _shareMutation = true;
    _mint(receiver, shares);
    _shareMutation = false;
    emit Deposit(controller, receiver, assets, shares);
    emit LiquidityIssued(msg.sender, controller, receiver, assets, shares);
  }

  /// @dev Require controller authority and backed reserves; fresh NAV is not required.
  function _claimChecks(address receiver, address controller) private view returns (uint256 actual) {
    _authorize(controller);
    if (!_receiverValid(receiver)) revert InvalidReceiver();
    actual = SafeTransfer.balanceOf(ASSET, address(this));
    if (actual < _state.withdrawals.reserved) revert Accounting.CashDeficit(actual, _state.withdrawals.reserved);
  }

  /// @dev Debit tracked cash and pay exactly the funded ASSET amount.
  /// Check both vault and receiver deltas; donated balances are not claim revenue.
  /// The validated pre-payment balance crosses only internal queue/accounting operations.
  function _payClaim(uint256 assets, uint256 shares, address receiver, address controller, uint256 beforeVault)
    private
  {
    _state.cash -= assets;
    uint256 beforeReceiver = SafeTransfer.balanceOf(ASSET, receiver);
    if (assets != 0) SafeTransfer.safeTransfer(ASSET, receiver, assets);
    if (
      SafeTransfer.balanceOf(ASSET, address(this)) != beforeVault - assets
        || SafeTransfer.balanceOf(ASSET, receiver) != beforeReceiver + assets
    ) revert AssetDeltaMismatch();
    emit Withdraw(msg.sender, receiver, controller, assets, shares);
  }
}
