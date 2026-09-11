// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;
import {AssetUnits} from "src/libraries/AssetUnits.sol";

import {SafeTransferLib as SafeTransfer} from "solady/utils/SafeTransferLib.sol";
import {IAqua} from "@1inch/aqua/src/interfaces/IAqua.sol";
import {ISwapVM} from "@1inch/swap-vm/src/interfaces/ISwapVM.sol";
import {IHarborClaim} from "src/interfaces/IHarborClaim.sol";
import {ERC4626} from "solady/tokens/ERC4626.sol";
import {IHarborBook} from "src/interfaces/IHarborBook.sol";
import {VaultLedger as Accounting} from "src/libraries/VaultLedger.sol";
import {Operation} from "src/types/HarborTypes.sol";

/// @title VaultCore
/// @notice Shared custody state, operation coordination and share-mutation guards.
/// @dev Compiler-managed accounting and Solady token storage have one owner.
/// Context survives external returns; persistent claims are never transient.
abstract contract VaultCore is ERC4626 {
  using Accounting for Accounting.State;

  /*//////////////////////////////////////////////////////////////
                         IMMUTABLES & STATE
  //////////////////////////////////////////////////////////////*/

  /// @dev Cash asset; all asset accounting is settlement-asset raw units.
  address public immutable ASSET;
  uint8 internal immutable _assetDecimals;
  /// @dev Immutable cross-contract authority; not a general-purpose spender.
  IHarborBook public immutable BOOK;
  /// @dev Maximum age of public observations, seconds.
  uint256 public immutable MAX_MARK_AGE;
  /// @dev Minimum first deposit, settlement-asset raw units.
  uint256 public immutable MIN_INITIAL_ASSETS;
  /// @dev Minimum partial exit request, LP share raw units.
  uint256 public immutable MIN_REQUEST_SHARES;
  /// @dev One million virtual LP share units paired with one virtual asset wei.
  uint256 internal constant VIRTUAL_SHARES = Accounting.VIRTUAL_SHARES;

  /// @dev Only managed cash/NAV/withdrawal ledger; donations are not adopted.
  Accounting.State internal _state;
  /// @dev ERC-7540 controller authorizations; no automatic token-spending allowance.
  mapping(address => mapping(address => bool)) public isOperator;
  /// @dev Receipt status/recovery commitment at the last public NAV checkpoint.
  bytes32 internal _valuationEvidence;

  /*//////////////////////////////////////////////////////////////
                         TRANSIENT CONTEXT
  //////////////////////////////////////////////////////////////*/

  /// @dev Compiler-assigned transient slots. Held across Book begin/finish calls,
  /// not a function-scoped modifier on beginBookOperation. No inherited guard slots.
  /// Nonzero while any coordinated Book/Vault operation is active.
  bytes32 internal transient _context;
  /// @dev Internal gate for intended mint, burn and transfer operations.
  bool internal transient _shareMutation;
  /// @dev Current treasury domain; successful recording disables repeated settlement.
  Operation internal transient _operation;
  /// @dev Prevents a second inventory handoff in one issuer request.
  bool internal transient _redemptionTransferred;
  bool private transient _tradeCheckpointed;
  /// @dev Physical ASSET balance at operation entry; excludes later donation subsidy.
  uint256 internal transient _cashAtBegin;

  /*//////////////////////////////////////////////////////////////
                         ERRORS & EVENTS
  //////////////////////////////////////////////////////////////*/

  /// @notice Caller lacks the required Book/controller authority.
  error Unauthorized();
  /// @notice Another Book/Vault operation already holds the context.
  error Busy();
  /// @notice Callback context, lifecycle or share-mutation gate does not match.
  error InvalidContext();
  /// @notice Immutable custody or limit configuration is invalid.
  error InvalidConfiguration();
  /// @notice Recipient is zero, the vault, or its accounting Book.
  error InvalidReceiver();
  /// @notice Amount is zero, dust, out of capacity, or exceeds managed inventory.
  error InvalidAmount();
  /// @notice A fresh valid public mark is required for this operation.
  error ValuationUnavailable();
  /// @notice Synchronous withdrawal previews and internal exits are disabled.
  error AsyncPreview();
  /// @notice Physical token movement differs from the exact accounting transition.
  error AssetDeltaMismatch();
  /// @notice Issuance would capture ownerless assets or revive zero-NAV shares.
  error OrphanedPortfolio();

  /// @notice A controller changes its ERC-7540 operator permission.
  event OperatorSet(address indexed controller, address indexed operator, bool approved);
  /// @notice Shares are escrowed, not burned; public requestId is always zero.
  event RedeemRequest(
    address indexed controller, address indexed owner, uint256 indexed requestId, address sender, uint256 shares
  );
  /// @notice Escrow shares are burned against reserved settlement-asset raw units at the recorded mark.
  event WithdrawalFunded(
    uint256 indexed ticket, address indexed controller, uint256 shares, uint256 assets, uint256 remaining
  );
  /// @notice Actual funding account, controller authorization and LP share recipient.
  /// @dev Supplements the standard Deposit event; assets are settlement-asset raw units, shares are LP raw units.
  event LiquidityIssued(
    address indexed payer, address indexed controller, address indexed receiver, uint256 assets, uint256 shares
  );
  /// @notice Internal FIFO identity; distinct from the standard aggregate requestId zero.
  event WithdrawalQueued(
    uint256 indexed ticket, address indexed controller, address indexed owner, address caller, uint256 shares
  );
  /// @notice Commit coherent NAV and noncash breakdown in settlement-asset raw units, with LP raw-unit supply.
  /// @dev Use transaction/log identity for history; no redundant valuation counter is stored.
  event ValuationCommitted(
    uint256 nav,
    uint256 supply,
    uint256 cash,
    uint256 reserved,
    uint256 inventoryMark,
    uint256 claimMark,
    uint256 observedAt
  );
  /// @notice ERC-7575 asset-to-vault discovery notification emitted at construction.
  event VaultUpdate(address indexed asset, address vault);

  /*//////////////////////////////////////////////////////////////
                         CONSTRUCTION & COORDINATION
  //////////////////////////////////////////////////////////////*/

  /// @notice Bind immutable custody, coordinator and deployment-specific limits.
  /// @dev Limits are configuration, not calibrated recommendations. Book may be
  /// under construction; deployment must bind it atomically without an initializer.
  constructor(address cashAsset, address book, uint256 maxAge, uint256 minSeed, uint256 minRequest) {
    if (
      cashAsset.code.length == 0 || book == address(0) || book == address(this) || maxAge == 0 || minSeed == 0
        || minRequest == 0
    ) revert InvalidConfiguration();
    ASSET = cashAsset;
    _assetDecimals = AssetUnits.decimals(cashAsset);
    BOOK = IHarborBook(book);
    MAX_MARK_AGE = maxAge;
    MIN_INITIAL_ASSETS = minSeed;
    MIN_REQUEST_SHARES = minRequest;
    emit VaultUpdate(cashAsset, address(this));
  }

  /// @dev Acquire Book then Vault context before a public share operation.
  /// Commit the actual inherited ERC20 supply only against a coherent mark;
  /// never use the public cached totalSupply() to checkpoint a mutation.
  modifier coordinated() {
    if (_context != 0) revert Busy();
    if (msg.sender == address(BOOK)) revert Unauthorized();
    bytes32 context = keccak256(abi.encode(address(this), msg.sender, msg.data));
    BOOK.beginVaultOperation(context);
    if (_context != context || _operation != Operation.VAULT) revert InvalidContext();
    _;
    // Stale portfolio marks must not be recombined with changed trade cash.
    // Requests/transfers/funded claims preserve the previous committed NAV.
    if (_state.valid) _state.commit(super.totalSupply());
    BOOK.finishVaultOperation(context);
    if (_context != 0) revert InvalidContext();
  }

  /// @dev Non-economic permissions/transfers need no Book call or NAV checkpoint.
  /// The same Vault context still excludes every active Book-held operation.
  modifier localOperation() {
    if (_context != 0) revert Busy();
    _context = bytes32(uint256(1));
    _;
    _context = bytes32(0);
  }

  /*//////////////////////////////////////////////////////////////
                         INTERNAL GUARDS
  //////////////////////////////////////////////////////////////*/

  /// @dev Controller or its approved operator only; share allowance is insufficient.
  function _authorize(address controller) internal view {
    if (msg.sender != controller && !isOperator[controller][msg.sender]) revert Unauthorized();
  }

  /// @dev New issuance/funding needs a valid non-stale mark; funded claims do not.
  function _requireFresh() internal view {
    if (!_fresh()) revert ValuationUnavailable();
  }

  function _fresh() internal view returns (bool) {
    if (!_state.fresh(MAX_MARK_AGE)) return false;
    // Cached timestamps alone cannot detect a changed haircut, issuer conversion,
    // native finalization or an observation revoked before its age limit. Compare
    // live bounded marks without committing a new NAV in this read path.
    try BOOK.valuation() returns (uint256 inventory, uint256 claims, uint256 time, bytes32 evidence, bool valid) {
      if (
        !valid || time == 0 || time > block.timestamp || block.timestamp - time > MAX_MARK_AGE
          || evidence != _valuationEvidence || inventory != _state.inventoryValue || claims != _state.claimsValue
      ) {
        return false;
      }
    } catch {
      return false;
    }
    return true;
  }

  /// @dev Reject destinations that cannot be a normal external LP beneficiary.
  function _receiverValid(address receiver) internal view returns (bool) {
    return receiver != address(0) && receiver != address(this) && receiver != address(BOOK);
  }

  /// @dev Prevent new depositors capturing residual rights after supply reaches zero.
  /// Zero-NAV existing supply also blocks issuance pending explicit resolution.
  function _orphaned() internal view returns (bool) {
    return
      (_state.supply == 0 && (_state.nav != 0 || BOOK.hasManagedPositions())) || (_state.supply != 0 && _state.nav == 0);
  }

  /// @dev Every inherited ERC20 mint/burn/transfer must be an intended LP transition.
  function _beforeTokenTransfer(address, address, uint256) internal view override {
    if (_context == 0 || !_shareMutation) revert InvalidContext();
  }

  /// @dev Retire inherited synchronous internal exit path as defense in depth.
  function _withdraw(address, address, address, uint256, uint256) internal pure override {
    revert AsyncPreview();
  }

  /// @notice Book-only callback; context remains locked after this method returns.
  /// @param context Nonzero operation identity held across callback returns.
  /// @param operation Treasury domain authorized by the immutable Book.
  function beginBookOperation(bytes32 context, Operation operation) external {
    if (msg.sender != address(BOOK)) revert Unauthorized();
    if (_context != 0) revert Busy();
    if (context == 0 || operation == Operation.NONE) revert InvalidContext();
    _context = context;
    _operation = operation;
    _cashAtBegin = SafeTransfer.balanceOf(ASSET, address(this));
  }

  /// @notice Book-only matching release; no external calls between lock releases.
  /// @param context Exact identity supplied at acquisition; all transient fields clear.
  function finishBookOperation(bytes32 context) external {
    if (msg.sender != address(BOOK)) revert Unauthorized();
    if (_context == 0 || _context != context) revert InvalidContext();
    _context = 0;
    _operation = Operation.NONE;
    _cashAtBegin = 0;
    _redemptionTransferred = false;
    _tradeCheckpointed = false;
  }

  /// @notice Exact approved inventory handoff; no general Book allowance exists.
  /// @param context Active issuer-request identity. Asset/amount/adapter come from Book.
  function transferForRedemption(bytes32 context) external {
    if (msg.sender != address(BOOK)) revert Unauthorized();
    if (_context != context || _operation != Operation.REDEMPTION || _redemptionTransferred) revert InvalidContext();
    (address base, address adapter, uint256 amount, uint256 managed) = BOOK.redemptionTransfer(context);
    uint256 beforeVault = SafeTransfer.balanceOf(base, address(this));
    uint256 beforeAdapter = SafeTransfer.balanceOf(base, adapter);
    if (amount == 0 || amount > managed || beforeVault < managed) revert InvalidAmount();
    _redemptionTransferred = true;
    SafeTransfer.safeTransfer(base, adapter, amount);
    if (
      SafeTransfer.balanceOf(base, address(this)) != beforeVault - amount
        || SafeTransfer.balanceOf(base, adapter) != beforeAdapter + amount
    ) revert AssetDeltaMismatch();
  }

  /// @notice Record verified issuer cash without requiring a functioning mark service.
  /// @param context Active request or recovery identity.
  /// @param cash Verified recovered settlement-asset raw units; zero for a completed inventory request.
  function settleIssuer(bytes32 context, uint256 cash) external {
    if (msg.sender != address(BOOK)) revert Unauthorized();
    if (
      _context != context
        || (_operation != Operation.RECOVERY
          && !(_operation == Operation.REDEMPTION && _redemptionTransferred && cash == 0))
    ) revert InvalidContext();
    if (SafeTransfer.balanceOf(ASSET, address(this)) != _cashAtBegin + cash) revert AssetDeltaMismatch();
    if (cash != 0) _state.receiveCash(cash);
    else _state.invalidate();
    _operation = Operation.NONE;
  }

  /// @notice Collect one managed receipt's recovery to the vault under the Book lock.
  /// @dev Only the Book chooses the approved receipt. No keeper-selected beneficiary.
  function recoverReceipt(bytes32 context, address receipt, bytes calldata data) external returns (uint256 cash) {
    if (msg.sender != address(BOOK)) revert Unauthorized();
    if (_context != context || _operation != Operation.RECOVERY || _redemptionTransferred) revert InvalidContext();
    if (SafeTransfer.balanceOf(receipt, address(this)) != 1) revert InvalidAmount();
    _redemptionTransferred = true;
    IHarborClaim c = IHarborClaim(receipt);
    if (c.ASSET() != ASSET) revert InvalidConfiguration();
    if (c.status() != IHarborClaim.Status.CASH_READY) c.recover(data);
    cash = c.redeem(address(this));
    // settleIssuer is the single authoritative Vault cash reconciliation before
    // Book releases this context; retain the distinct burned-ownership check here.
    if (SafeTransfer.balanceOf(receipt, address(this)) != 0) revert AssetDeltaMismatch();
  }

  /// @notice Commit only the verified ASSET leg of a fully paid trade.
  /// @dev Only Book may call, while holding this exact trade context. Inventory
  /// belongs to Book; the prior NAV remains visible but invalid until checkpoint.
  /// @param context Active trader-intent identity.
  /// @param buyBase True when the vault bought base inventory and spent ASSET.
  /// @param cashAmount Exact gross buy debit or net sell receipt, settlement-asset raw units.
  function settleTrade(bytes32 context, bool buyBase, uint256 cashAmount) external {
    if (msg.sender != address(BOOK)) revert Unauthorized();
    if (_context != context || _operation != Operation.TRADE) revert InvalidContext();
    uint256 expected = buyBase ? _cashAtBegin - cashAmount : _cashAtBegin + cashAmount;
    if (SafeTransfer.balanceOf(ASSET, address(this)) != expected) revert AssetDeltaMismatch();
    if (buyBase) _state.spendCash(cashAmount, 0);
    else _state.receiveCash(cashAmount);
    // Prevent duplicate cash recording in the same operation.
    _operation = Operation.NONE;
  }

  /// @notice Reuse Book's independent live snapshot, only before trade token movement.
  /// @dev Caller is immutable; no external party supplies a private NAV or arbitrary mark.
  function checkpointTrade(bytes32 context, uint256 inventory, uint256 claims, uint256 time, bytes32 evidence)
    external
  {
    if (msg.sender != address(BOOK)) revert Unauthorized();
    if (_context != context || _operation != Operation.TRADE || _tradeCheckpointed) revert InvalidContext();
    _tradeCheckpointed = true;
    _checkpoint(inventory, claims, time, evidence);
  }

  function _checkpoint(uint256 inventory, uint256 claims, uint256 time, bytes32 evidence) internal {
    _state.requireBacked(SafeTransfer.balanceOf(ASSET, address(this)));
    _state.checkpoint(inventory, claims, super.totalSupply(), time, MAX_MARK_AGE);
    _valuationEvidence = evidence;
    emit ValuationCommitted(
      _state.nav, _state.supply, _state.cash, _state.withdrawals.reserved, inventory, claims, time
    );
  }

  /// @notice Book can close the issuance gate without changing NAV or LP credit.
  function invalidateValuation() external {
    if (msg.sender != address(BOOK)) revert Unauthorized();
    if (_context != 0) revert Busy();
    _state.invalidate();
  }

  /// @notice Current physically backed cash and withdrawal-priority capacity.
  /// @param buffer Additional cash floor in settlement-asset raw units.
  /// @return Spendable settlement-asset raw units after pending-withdrawal and physical-backing gates.
  function tradingCash(uint256 buffer) external view returns (uint256) {
    if (_state.withdrawals.totalPending != 0 || SafeTransfer.balanceOf(ASSET, address(this)) < _state.cash) return 0;
    return _state.available(buffer);
  }

  /// @notice Identity of committed public marks, independent of the operation lock.
  /// @return evidence Live-data commitment at the last checkpoint.
  /// @return observedAt Oldest required observation time at the last checkpoint.
  /// @return fresh Whether the committed mark meets the configured validity window.
  function valuationIdentity() external view returns (bytes32 evidence, uint256 observedAt, bool fresh) {
    return (_valuationEvidence, _state.observedAt, _fresh());
  }

  /// @notice Publish/replace a canonical strategy from this vault's own address.
  /// @dev Book authenticates the original requester and keeps all route ledgers.
  /// @param route Fixed Book route to register or replace.
  /// @return hash Newly shipped Aqua order hash.
  /// @dev Aqua is approved for supported tokens; per-strategy allocation and live
  /// Book budgets, not the allowance value, bound each actual transfer.
  function refreshStrategy(uint256 route) external coordinated returns (bytes32 hash) {
    (ISwapVM.Order memory order, bytes32 previous, address base, uint256 managed) =
      BOOK.prepareStrategyFromVault(route, msg.sender);
    if (order.maker != address(this)) revert InvalidConfiguration();
    address aqua = BOOK.AQUA();
    address router = BOOK.ROUTER();
    address[] memory tokens = new address[](2);
    tokens[0] = ASSET;
    tokens[1] = base;
    uint256[] memory allocations = new uint256[](2);
    _state.requireBacked(SafeTransfer.balanceOf(ASSET, address(this)));
    if (SafeTransfer.balanceOf(base, address(this)) < managed) revert AssetDeltaMismatch();
    allocations[0] = _state.available(0);
    if (allocations[0] > type(uint248).max) allocations[0] = type(uint248).max;
    allocations[1] = managed;
    if (allocations[1] > type(uint248).max) allocations[1] = type(uint248).max;
    if (previous != 0) IAqua(aqua).dock(router, previous, tokens);
    // Aqua allowance is not the risk budget: its per-order counters and Book's
    // live managed-cash/inventory checks are. A bid must be able to sell newly
    // received inventory without a permission-changing refresh between fills.
    SafeTransfer.safeApprove(ASSET, aqua, type(uint256).max);
    SafeTransfer.safeApprove(base, aqua, type(uint256).max);
    hash = IAqua(aqua).ship(router, abi.encode(order), tokens, allocations);
    if (hash != keccak256(abi.encode(order))) revert InvalidContext();
  }
}
