// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {ERC4626} from "solady/tokens/ERC4626.sol";
import {IHarborBook} from "src/interfaces/IHarborBook.sol";
import {VaultAccounting as Accounting} from "src/libraries/VaultAccounting.sol";
import {Operation} from "src/types/HarborTypes.sol";

/// @title VaultState
/// @notice Shared custody state, operation coordination and share-mutation guards.
/// @dev Compiler-managed accounting and Solady token storage have one owner.
/// Context survives external returns; persistent claims are never transient.
abstract contract VaultState is ERC4626 {
  using Accounting for Accounting.State;

  /*//////////////////////////////////////////////////////////////
                         IMMUTABLES & STATE
  //////////////////////////////////////////////////////////////*/

  /// @dev Cash asset; all asset accounting is WETH wei.
  address public immutable WETH;
  /// @dev Immutable cross-contract authority; not a general-purpose spender.
  IHarborBook public immutable BOOK;
  /// @dev Maximum age of public observations, seconds.
  uint256 public immutable MAX_MARK_AGE;
  /// @dev Maximum issuance NAV, WETH wei.
  uint256 public immutable DEPOSIT_CAP;
  /// @dev Minimum first deposit, WETH wei.
  uint256 public immutable MIN_INITIAL_ASSETS;
  /// @dev Minimum partial exit request, LP share raw units.
  uint256 public immutable MIN_REQUEST_SHARES;
  /// @dev One million virtual LP share units paired with one virtual asset wei.
  uint256 internal constant VIRTUAL_SHARES = 1e6;

  /// @dev Only managed cash/NAV/withdrawal ledger; donations are not adopted.
  Accounting.State internal _state;
  /// @dev ERC-7540 controller authorizations; no automatic token-spending allowance.
  mapping(address => mapping(address => bool)) public isOperator;
  /// @dev Receipt status/recovery commitment at the last public NAV checkpoint.
  bytes32 internal _receiptState;

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
  /// @dev Physical WETH balance at operation entry; excludes later donation subsidy.
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
  /// @notice Escrow shares are burned against reserved WETH wei at the recorded mark.
  event WithdrawalFulfilled(
    uint256 indexed ticket,
    address indexed controller,
    uint256 shares,
    uint256 assets,
    uint256 valuationVersion,
    uint256 remaining
  );
  /// @notice Commit coherent NAV/cash/reserve WETH wei and LP share supply.
  event ValuationCheckpoint(
    uint256 nav, uint256 supply, uint256 cash, uint256 reserved, uint256 policyVersion, uint256 observedAt
  );
  /// @notice ERC-7575 asset-to-vault discovery notification emitted at construction.
  event VaultUpdate(address indexed asset, address vault);

  /*//////////////////////////////////////////////////////////////
                         CONSTRUCTION & COORDINATION
  //////////////////////////////////////////////////////////////*/

  /// @notice Bind immutable custody, coordinator and deployment-specific limits.
  /// @dev Limits are configuration, not calibrated recommendations. Book may be
  /// under construction; deployment must bind it atomically without an initializer.
  constructor(address weth, address book, uint256 maxAge, uint256 cap, uint256 minSeed, uint256 minRequest) {
    if (
      weth.code.length == 0 || book == address(0) || book == address(this) || maxAge == 0 || minSeed == 0
        || cap < minSeed || cap > type(uint128).max || minRequest == 0
    ) revert InvalidConfiguration();
    WETH = weth;
    BOOK = IHarborBook(book);
    MAX_MARK_AGE = maxAge;
    DEPOSIT_CAP = cap;
    MIN_INITIAL_ASSETS = minSeed;
    MIN_REQUEST_SHARES = minRequest;
    emit VaultUpdate(weth, address(this));
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
    if (_state.valid && _state.markedVersion == _state.portfolioVersion) _state.commit(super.totalSupply());
    BOOK.finishVaultOperation(context);
    if (_context != 0) revert InvalidContext();
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
    try BOOK.receiptState() returns (bytes32 current) {
      return current == _receiptState;
    } catch {
      return false;
    }
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
}
