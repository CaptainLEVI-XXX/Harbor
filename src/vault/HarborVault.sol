// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {ERC4626} from "solady/tokens/ERC4626.sol";
import {FixedPointMathLib as Math} from "solady/utils/FixedPointMathLib.sol";
import {SafeTransferLib as SafeTransfer} from "solady/utils/SafeTransferLib.sol";
import {IHarborBook} from "src/interfaces/IHarborBook.sol";
import {VaultAccounting as Accounting} from "src/libraries/VaultAccounting.sol";
import {WithdrawalQueue as Queue} from "src/libraries/WithdrawalQueue.sol";
import {Operation} from "src/types/HarborTypes.sol";
import {IAqua} from "@1inch/aqua/src/interfaces/IAqua.sol";
import {ISwapVM} from "@1inch/swap-vm/src/interfaces/ISwapVM.sol";

/// @title HarborVault
/// @notice WETH share custody with synchronous issuance and asynchronous exits.
/// @dev Immutable Book coordinates all share-moving calls. Real deposits require
/// a verified public mark; a mock Book proves mechanics, not production valuation.
contract HarborVault is ERC4626 {
  using Accounting for Accounting.State;
  using Queue for Queue.State;

  address public immutable WETH;
  IHarborBook public immutable BOOK;
  uint256 public immutable MAX_MARK_AGE;
  uint256 public immutable DEPOSIT_CAP;
  uint256 public immutable MIN_INITIAL_ASSETS;
  uint256 public immutable MIN_REQUEST_SHARES;
  uint256 private constant VIRTUAL_SHARES = 1e6;

  Accounting.State private _state;
  mapping(address => mapping(address => bool)) public isOperator;

  /// @dev Compiler-assigned transient slots. Held across Book begin/finish calls,
  /// not a function-scoped modifier on beginBookOperation. No inherited guard slots.
  bytes32 private transient _context;
  bool private transient _shareMutation;
  Operation private transient _operation;
  uint256 private transient _cashAtBegin;

  error Unauthorized();
  error Busy();
  error InvalidContext();
  error InvalidConfiguration();
  error InvalidReceiver();
  error InvalidAmount();
  error ValuationUnavailable();
  error AsyncPreview();
  error AssetDeltaMismatch();
  error OrphanedPortfolio();

  event OperatorSet(address indexed controller, address indexed operator, bool approved);
  event RedeemRequest(
    address indexed controller, address indexed owner, uint256 indexed requestId, address sender, uint256 shares
  );
  event WithdrawalFulfilled(
    uint256 indexed ticket,
    address indexed controller,
    uint256 shares,
    uint256 assets,
    uint256 valuationVersion,
    uint256 remaining
  );
  event ValuationCheckpoint(
    uint256 nav, uint256 supply, uint256 cash, uint256 reserved, uint256 policyVersion, uint256 observedAt
  );
  event VaultUpdate(address indexed asset, address vault);

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

  /// @notice Book-only callback; context remains locked after this method returns.
  function beginBookOperation(bytes32 context, Operation operation) external {
    if (msg.sender != address(BOOK)) revert Unauthorized();
    if (_context != 0) revert Busy();
    if (context == 0 || operation == Operation.NONE) revert InvalidContext();
    _context = context;
    _operation = operation;
    _cashAtBegin = SafeTransfer.balanceOf(WETH, address(this));
  }

  /// @notice Book-only matching release; no external calls between lock releases.
  function finishBookOperation(bytes32 context) external {
    if (msg.sender != address(BOOK)) revert Unauthorized();
    if (_context == 0 || _context != context) revert InvalidContext();
    _context = 0;
    _operation = Operation.NONE;
    _cashAtBegin = 0;
  }

  /// @notice Commit only the verified WETH leg of a fully paid trade.
  /// @dev Only Book may call, while holding this exact trade context. Inventory
  /// belongs to Book; the prior NAV remains visible but invalid until checkpoint.
  function settleTrade(bytes32 context, bool buyBase, uint256 cashAmount) external {
    if (msg.sender != address(BOOK)) revert Unauthorized();
    if (_context != context || _operation != Operation.TRADE) revert InvalidContext();
    uint256 expected = buyBase ? _cashAtBegin - cashAmount : _cashAtBegin + cashAmount;
    if (SafeTransfer.balanceOf(WETH, address(this)) != expected) revert AssetDeltaMismatch();
    if (buyBase) _state.spendCash(cashAmount, 0);
    else _state.receiveCash(cashAmount);
    // Prevent duplicate cash recording in the same operation.
    _operation = Operation.NONE;
  }

  /// @notice Book can close the issuance gate without changing NAV or LP credit.
  function invalidateValuation() external {
    if (msg.sender != address(BOOK)) revert Unauthorized();
    if (_context != 0) revert Busy();
    _state.invalidate();
  }

  /// @notice Current physically backed cash and withdrawal-priority capacity.
  function tradingCash(uint256 buffer) external view returns (uint256) {
    if (_state.withdrawals.totalPending != 0 || SafeTransfer.balanceOf(WETH, address(this)) < _state.cash) return 0;
    return _state.available(buffer);
  }

  /// @notice Identity of committed public marks, independent of the operation lock.
  function valuationIdentity() external view returns (uint256 policy, uint256 version, bool fresh) {
    return (_state.policyVersion, _state.markedVersion, _state.fresh(MAX_MARK_AGE));
  }

  /// @notice Book uses this to invalidate quotes on material LP accounting changes.
  function portfolioHash() external view returns (bytes32) {
    return keccak256(
      abi.encode(
        _state.cash,
        _state.nav,
        _state.supply,
        _state.withdrawals.reserved,
        _state.withdrawals.totalPending,
        _state.observedAt,
        _state.policyVersion
      )
    );
  }

  /// @notice Publish/replace a canonical strategy from this vault's own address.
  /// @dev Book authenticates the original requester and keeps all route ledgers.
  function refreshStrategy(uint256 route) external coordinated returns (bytes32 hash) {
    (ISwapVM.Order memory order, bytes32 previous, address base, uint256 managed) =
      BOOK.prepareStrategyFromVault(route, msg.sender);
    if (order.maker != address(this)) revert InvalidConfiguration();
    address aqua = BOOK.AQUA();
    address router = BOOK.ROUTER();
    address[] memory tokens = new address[](2);
    tokens[0] = WETH;
    tokens[1] = base;
    uint256[] memory allocations = new uint256[](2);
    _state.requireBacked(SafeTransfer.balanceOf(WETH, address(this)));
    if (SafeTransfer.balanceOf(base, address(this)) < managed) revert AssetDeltaMismatch();
    allocations[0] = _state.available(0);
    allocations[1] = managed;
    if (previous != 0) IAqua(aqua).dock(router, previous, tokens);
    // Aqua allowance is not the risk budget: its per-order counters and Book's
    // live managed-cash/inventory checks are. A bid must be able to sell newly
    // received inventory without a permission-changing refresh between fills.
    SafeTransfer.safeApprove(WETH, aqua, type(uint256).max);
    SafeTransfer.safeApprove(base, aqua, type(uint256).max);
    hash = IAqua(aqua).ship(router, abi.encode(order), tokens, allocations);
    if (hash != keccak256(abi.encode(order))) revert InvalidContext();
  }

  function name() public pure override returns (string memory) {
    return "Harbor WETH";
  }

  function symbol() public pure override returns (string memory) {
    return "hWETH";
  }

  function asset() public view override returns (address) {
    return WETH;
  }

  function share() external view returns (address) {
    return address(this);
  }

  function vault(address token) external view returns (address) {
    return token == WETH ? address(this) : address(0);
  }

  function _decimalsOffset() internal pure override returns (uint8) {
    return 6;
  }

  /// @dev No implicit third-party share allowance; all spenders require approval.
  function _givePermit2InfiniteAllowance() internal pure override returns (bool) {
    return false;
  }

  /// @notice Committed numerator and denominator stay coherent during callbacks.
  function totalAssets() public view override returns (uint256) {
    return _state.nav;
  }

  function totalSupply() public view override returns (uint256) {
    return _state.supply;
  }

  function convertToShares(uint256 assets) public view override returns (uint256) {
    return Math.fullMulDiv(assets, _state.supply + VIRTUAL_SHARES, _state.nav + 1);
  }

  function convertToAssets(uint256 shares) public view override returns (uint256) {
    return Math.fullMulDiv(shares, _state.nav + 1, _state.supply + VIRTUAL_SHARES);
  }

  function previewMint(uint256 shares) public view override returns (uint256) {
    return Math.fullMulDivUp(shares, _state.nav + 1, _state.supply + VIRTUAL_SHARES);
  }

  function previewWithdraw(uint256) public pure override returns (uint256) {
    revert AsyncPreview();
  }

  function previewRedeem(uint256) public pure override returns (uint256) {
    revert AsyncPreview();
  }

  function supportsInterface(bytes4 id) external pure returns (bool) {
    return id == 0x01ffc9a7 || id == 0x2f0a18c5 || id == 0xf815c03d || id == 0xe3bc4e65 || id == 0x620ee8e4;
  }

  /// @notice Separate telemetry; stale views are not executable prices.
  function accountingStatus()
    external
    view
    returns (uint256 cash, uint256 reserved, uint256 pending, bool valid, bool insolvent)
  {
    bool cashDeficit = SafeTransfer.balanceOf(WETH, address(this)) < _state.cash;
    return (
      _state.cash,
      _state.withdrawals.reserved,
      _state.withdrawals.totalPending,
      _state.fresh(MAX_MARK_AGE) && !cashDeficit && _context == 0,
      _state.insolvent || cashDeficit
    );
  }

  function maxDeposit(address receiver) public view override returns (uint256) {
    if (
      _context != 0 || !_receiverValid(receiver) || !_state.fresh(MAX_MARK_AGE)
        || SafeTransfer.balanceOf(WETH, address(this)) < _state.cash || _state.nav >= DEPOSIT_CAP || _orphaned()
    ) return 0;
    return DEPOSIT_CAP - _state.nav;
  }

  function maxMint(address receiver) public view override returns (uint256) {
    return convertToShares(maxDeposit(receiver));
  }

  function maxWithdraw(address controller) public view override returns (uint256) {
    if (_context != 0 || SafeTransfer.balanceOf(WETH, address(this)) < _state.withdrawals.reserved) return 0;
    return _state.withdrawals.credits[controller].assets;
  }

  function maxRedeem(address controller) public view override returns (uint256) {
    if (_context != 0 || SafeTransfer.balanceOf(WETH, address(this)) < _state.withdrawals.reserved) return 0;
    return _state.withdrawals.credits[controller].units;
  }

  function deposit(uint256 assets, address receiver) public override coordinated returns (uint256 shares) {
    shares = previewDeposit(assets);
    _issue(assets, shares, receiver, msg.sender);
  }

  function mint(uint256 shares, address receiver) public override coordinated returns (uint256 assets) {
    assets = previewMint(shares);
    _issue(assets, shares, receiver, msg.sender);
  }

  function deposit(uint256 assets, address receiver, address controller) external coordinated returns (uint256 shares) {
    _authorize(controller);
    shares = previewDeposit(assets);
    _issue(assets, shares, receiver, controller);
  }

  function mint(uint256 shares, address receiver, address controller) external coordinated returns (uint256 assets) {
    _authorize(controller);
    assets = previewMint(shares);
    _issue(assets, shares, receiver, controller);
  }

  /// @notice Request ID is always zero; internal FIFO tickets remain distinct.
  function requestRedeem(uint256 shares, address controller, address owner) external coordinated returns (uint256) {
    if (!_receiverValid(controller) || owner == address(this)) revert InvalidReceiver();
    if (shares == 0 || (shares < MIN_REQUEST_SHARES && shares != balanceOf(owner))) revert InvalidAmount();
    if (msg.sender != owner && !isOperator[owner][msg.sender]) _spendAllowance(owner, msg.sender, shares);
    _shareMutation = true;
    _transfer(owner, address(this), shares);
    _shareMutation = false;
    _state.withdrawals.append(controller, shares);
    emit RedeemRequest(controller, owner, 0, msg.sender, shares);
    return 0;
  }

  function pendingRedeemRequest(uint256 requestId, address controller) external view returns (uint256) {
    return requestId == 0 ? _state.withdrawals.credits[controller].pending : 0;
  }

  function claimableRedeemRequest(uint256 requestId, address controller) external view returns (uint256) {
    return requestId == 0 ? _state.withdrawals.credits[controller].units : 0;
  }

  function setOperator(address operator, bool approved) external coordinated returns (bool) {
    isOperator[msg.sender][operator] = approved;
    emit OperatorSet(msg.sender, operator, approved);
    return true;
  }

  /// @notice Fund up to eight oldest tickets at the same fresh pre-operation mark.
  function fulfillWithdrawals(uint256 maxTickets) external coordinated {
    if (maxTickets == 0 || maxTickets > Queue.MAX_PROCESS) revert InvalidAmount();
    _requireFresh();
    _state.requireBacked(SafeTransfer.balanceOf(WETH, address(this)));
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
      emit WithdrawalFulfilled(ticket, controller, shares, assets, _state.policyVersion, pending - shares);
      if (shares != pending) break;
    }
  }

  function redeem(uint256 shares, address receiver, address controller)
    public
    override
    coordinated
    returns (uint256 assets)
  {
    _claimChecks(receiver, controller);
    assets = _state.withdrawals.redeem(controller, shares);
    _payClaim(assets, shares, receiver, controller);
  }

  function withdraw(uint256 assets, address receiver, address controller)
    public
    override
    coordinated
    returns (uint256 shares)
  {
    _claimChecks(receiver, controller);
    shares = _state.withdrawals.withdraw(controller, assets);
    _payClaim(assets, shares, receiver, controller);
  }

  function transfer(address receiver, uint256 shares) public override coordinated returns (bool) {
    if (!_receiverValid(receiver)) revert InvalidReceiver();
    _shareMutation = true;
    _transfer(msg.sender, receiver, shares);
    _shareMutation = false;
    return true;
  }

  function transferFrom(address owner, address receiver, uint256 shares) public override coordinated returns (bool) {
    if (!_receiverValid(receiver) || owner == address(this)) revert InvalidReceiver();
    _spendAllowance(owner, msg.sender, shares);
    _shareMutation = true;
    _transfer(owner, receiver, shares);
    _shareMutation = false;
    return true;
  }

  /// @notice Anyone may checkpoint authenticated public observations from the Book.
  function checkpointValuation() external coordinated {
    _state.requireBacked(SafeTransfer.balanceOf(WETH, address(this)));
    (uint256 inventory, uint256 claims, uint256 observedAt, uint256 policy, bool valid) = BOOK.valuation();
    if (!valid) revert ValuationUnavailable();
    _state.checkpoint(inventory, claims, super.totalSupply(), observedAt, policy, MAX_MARK_AGE);
    emit ValuationCheckpoint(_state.nav, _state.supply, _state.cash, _state.withdrawals.reserved, policy, observedAt);
  }

  function _issue(uint256 assets, uint256 shares, address receiver, address controller) private {
    _requireFresh();
    if (!_receiverValid(receiver)) revert InvalidReceiver();
    if (assets == 0 || shares == 0 || assets > DEPOSIT_CAP || _state.nav > DEPOSIT_CAP - assets) {
      revert InvalidAmount();
    }
    if (_orphaned()) revert OrphanedPortfolio();
    if (_state.supply == 0 && assets < MIN_INITIAL_ASSETS) revert InvalidAmount();
    uint256 beforeBalance = SafeTransfer.balanceOf(WETH, address(this));
    _state.requireBacked(beforeBalance);
    SafeTransfer.safeTransferFrom(WETH, msg.sender, address(this), assets);
    if (SafeTransfer.balanceOf(WETH, address(this)) != beforeBalance + assets) revert AssetDeltaMismatch();
    _state.cash += assets; // Issuance cash flow is not portfolio profit or a new mark.
    _shareMutation = true;
    _mint(receiver, shares);
    _shareMutation = false;
    emit Deposit(controller, receiver, assets, shares);
  }

  function _claimChecks(address receiver, address controller) private view {
    _authorize(controller);
    if (!_receiverValid(receiver)) revert InvalidReceiver();
    uint256 actual = SafeTransfer.balanceOf(WETH, address(this));
    if (actual < _state.withdrawals.reserved) revert Accounting.CashDeficit(actual, _state.withdrawals.reserved);
  }

  function _payClaim(uint256 assets, uint256 shares, address receiver, address controller) private {
    _state.cash -= assets;
    uint256 beforeVault = SafeTransfer.balanceOf(WETH, address(this));
    uint256 beforeReceiver = SafeTransfer.balanceOf(WETH, receiver);
    if (assets != 0) SafeTransfer.safeTransfer(WETH, receiver, assets);
    if (
      SafeTransfer.balanceOf(WETH, address(this)) != beforeVault - assets
        || SafeTransfer.balanceOf(WETH, receiver) != beforeReceiver + assets
    ) revert AssetDeltaMismatch();
    emit Withdraw(msg.sender, receiver, controller, assets, shares);
  }

  function _authorize(address controller) private view {
    if (msg.sender != controller && !isOperator[controller][msg.sender]) revert Unauthorized();
  }

  function _requireFresh() private view {
    if (!_state.fresh(MAX_MARK_AGE)) revert ValuationUnavailable();
  }

  function _receiverValid(address receiver) private view returns (bool) {
    return receiver != address(0) && receiver != address(this) && receiver != address(BOOK);
  }

  function _orphaned() private view returns (bool) {
    return
      (_state.supply == 0 && (_state.nav != 0 || BOOK.hasManagedPositions())) || (_state.supply != 0 && _state.nav == 0);
  }

  function _beforeTokenTransfer(address, address, uint256) internal view override {
    if (_context == 0 || !_shareMutation) revert InvalidContext();
  }

  /// @dev Retire inherited synchronous internal exit path as defense in depth.
  function _withdraw(address, address, address, uint256, uint256) internal pure override {
    revert AsyncPreview();
  }
}
