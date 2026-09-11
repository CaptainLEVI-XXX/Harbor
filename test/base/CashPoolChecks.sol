// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {TokenMock} from "@1inch/solidity-utils/contracts/mocks/TokenMock.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {HarborBook} from "src/book/HarborBook.sol";
import {HarborVault} from "src/vault/HarborVault.sol";
import {HarborExecutor} from "src/execution/HarborExecutor.sol";
import {HarborClaimFactory} from "src/claims/HarborClaimFactory.sol";
import {AssetUnits} from "src/libraries/AssetUnits.sol";
import {PricingState} from "src/libraries/PricingState.sol";
import {BookPortfolio} from "src/libraries/BookPortfolio.sol";
import {IHarborClaim} from "src/interfaces/IHarborClaim.sol";
import {IHarborAdapter} from "src/interfaces/IHarborAdapter.sol";
import {Trade, FillAmounts, Side, AmountMode, RouteConfig, RedeemIntent} from "src/types/HarborTypes.sol";
import {PricingPolicy, PricingParameters, PricingCurve} from "src/types/PricingTypes.sol";
import {
  ClaimImport,
  ClaimObservation,
  InventoryObservation,
  ClaimDomain,
  CollateralKind
} from "src/types/ClaimTypes.sol";

contract SixDecimalCash is TokenMock {
  constructor() TokenMock("Synthetic USD cash", "sUSD") {}

  function decimals() public pure override returns (uint8) {
    return 6;
  }
}

/// @notice Pre-funded synthetic issuer, not an integration with a live USDC protocol.
/// @dev One eighteen-decimal share represents one six-decimal cash token. Tests
/// fund cash explicitly; arbitrary ids/model observations are fixture controls.
contract CashIssuer {
  address public immutable BOOK;
  address public immutable VAULT;
  address public immutable BASE;
  address public immutable ASSET;
  HarborClaimFactory public immutable FACTORY;
  uint256 private _nextId;
  uint256 private _reserved;

  struct Right {
    uint256 face;
    address receipt;
    ClaimDomain domain;
    IHarborClaim.Status status;
  }
  mapping(bytes32 => Right) private _rights;

  constructor(address book, address vault, address base, address asset, HarborClaimFactory factory) {
    BOOK = book;
    VAULT = vault;
    BASE = base;
    ASSET = asset;
    FACTORY = factory;
  }

  function nativeClaimId(uint256 id) public pure returns (bytes32) {
    return bytes32(id);
  }

  function conversion(address base) external view returns (uint256, uint256) {
    require(base == BASE);
    return (1, 1e12);
  }

  function inventory(address base, uint256 quantity)
    public
    view
    returns (uint256, uint256, uint256, uint256, bytes32, bool)
  {
    require(base == BASE);
    uint256 face = quantity / 1e12;
    return (face, face, block.timestamp, 1, keccak256(abi.encode(base, face)), true);
  }

  function observePortfolio(address base, uint256 quantity, bytes32[] calldata ids)
    external
    view
    returns (InventoryObservation memory inv, ClaimObservation[] memory claims)
  {
    (inv.entitlement, inv.mark, inv.observedAt,, inv.observationHash, inv.valid) = inventory(base, quantity);
    claims = new ClaimObservation[](ids.length);
    for (uint256 i; i < ids.length; ++i) {
      claims[i] = claimState(ids[i]);
    }
  }

  function claimState(bytes32 id) public view returns (ClaimObservation memory o) {
    Right memory r = _rights[id];
    require(r.face != 0);
    o = ClaimObservation(
      r.domain,
      r.status,
      r.face,
      r.status == IHarborClaim.Status.CLOSED ? 0 : r.face,
      r.status == IHarborClaim.Status.CASH_READY ? r.face : 0,
      block.timestamp,
      true
    );
  }

  function claimBusy(bytes32) external pure returns (bool) {
    return false;
  }

  function request(uint256[] calldata amounts, uint256 previous)
    external
    returns (IHarborAdapter.Request[] memory result)
  {
    require(msg.sender == BOOK);
    result = new IHarborAdapter.Request[](amounts.length);
    uint256 total;
    for (uint256 i; i < amounts.length; ++i) {
      uint256 id = ++_nextId;
      uint256 face = amounts[i] / 1e12;
      require(face != 0);
      _rights[bytes32(id)] = Right(face, address(0), ClaimDomain.NATIVE_VAULT, IHarborClaim.Status.PENDING);
      result[i] = IHarborAdapter.Request(id, amounts[i], face);
      total += amounts[i];
    }
    require(IERC20(BASE).balanceOf(address(this)) == previous + total);
  }

  function claim(uint256 id, uint256) external returns (uint256 cash, uint256 remaining) {
    Right storage r = _rights[bytes32(id)];
    require(msg.sender == BOOK && r.domain == ClaimDomain.NATIVE_VAULT && r.status == IHarborClaim.Status.PENDING);
    cash = r.face;
    r.status = IHarborClaim.Status.CLOSED;
    require(IERC20(ASSET).balanceOf(address(this)) >= _reserved + cash);
    require(IERC20(ASSET).transfer(VAULT, cash));
    return (cash, 0);
  }

  function claimId(ClaimImport calldata input) public view returns (bytes32) {
    require(
      input.kind == CollateralKind.ERC20_AMOUNT && input.asset == BASE && input.tokenId != 0 && input.data.length == 0
    );
    return bytes32(input.tokenId);
  }

  function importClaim(address owner, ClaimImport calldata input, address receipt)
    external
    returns (bytes32 id, uint256 nominal)
  {
    require(msg.sender == address(FACTORY) && HarborBook(BOOK).isIdle());
    id = claimId(input);
    nominal = input.amount / 1e12;
    require(nominal != 0 && _rights[id].face == 0 && FACTORY.receiptOf(address(this), id) == receipt);
    require(IERC20(BASE).transferFrom(owner, address(this), input.amount));
    _rights[id] = Right(nominal, receipt, ClaimDomain.TOKENIZED, IHarborClaim.Status.PENDING);
  }

  function recoverTokenized(bytes32 id, bytes calldata) external returns (uint256 cash) {
    _allowed(id);
    Right storage r = _rights[id];
    require(r.domain == ClaimDomain.TOKENIZED && r.status == IHarborClaim.Status.PENDING);
    cash = r.face;
    _reserved += cash;
    require(IERC20(ASSET).balanceOf(address(this)) >= _reserved);
    r.status = IHarborClaim.Status.CASH_READY;
  }

  function redeemTokenized(bytes32 id, address receiver) external returns (uint256 cash) {
    _allowed(id);
    Right storage r = _rights[id];
    require(msg.sender == r.receipt && r.status == IHarborClaim.Status.CASH_READY);
    require(IERC20(ASSET).balanceOf(address(this)) >= _reserved);
    cash = r.face;
    r.status = IHarborClaim.Status.CLOSED;
    _reserved -= cash;
    require(IERC20(ASSET).transfer(receiver, cash));
  }

  function _allowed(bytes32 id) private view {
    require(HarborBook(BOOK).isIdle() || HarborBook(BOOK).claimOperationAllowed(address(this), id));
  }
}

/// @notice Cross-denomination lifecycle invoked by the existing shared-pool test slot.
contract CashPoolChecks is Test {
  HarborExecutor private executor;
  HarborBook private book;
  HarborVault private vault;
  SixDecimalCash private cash;
  TokenMock private base;
  CashIssuer private issuer;
  HarborClaimFactory private factory;
  address private constant FEE = address(0xcafe);

  /// @dev External boundary lets expectRevert check the internal metadata helper.
  function cashUnit(address token) external view returns (uint256) {
    return AssetUnits.unit(token);
  }

  function run(HarborExecutor shared, HarborBook peer) external {
    executor = shared;
    uint256 peerCash = IERC20(peer.ASSET()).balanceOf(address(peer.VAULT()));
    uint256 peerFace = peer.faceExposure();
    _deploy(peer);
    base.mint(address(this), 1_000 ether);
    cash.mint(address(this), 1_100e6);
    cash.mint(address(issuer), 1_000e6); // Explicit issuer backing, not a simulated payout.
    cash.approve(address(vault), 1_000e6);
    vault.checkpointValuation();
    assertEq(vault.deposit(1_000e6, address(this)), 1_000e12);
    assertEq(vault.decimals(), 12);
    cash.approve(address(executor), type(uint256).max);
    base.approve(address(executor), type(uint256).max);
    vault.refreshStrategy(0);
    vm.expectRevert(PricingState.InvalidConfiguration.selector);
    book.configurePricing(0, PricingPolicy(0.95e18, 1e18, 0.01e18, 0.01e18, 1e6 + 1, 0));
    _publish(0);
    // Wrong-currency observations cannot become authoritative LP NAV.
    vm.mockCall(address(issuer), abi.encodeWithSignature("ASSET()"), abi.encode(peer.ASSET()));
    vm.expectRevert(BookPortfolio.InvalidQuote.selector);
    vault.checkpointValuation();
    vm.clearMockedCalls();
    _swap(0, Side.BUY_BASE, AmountMode.EXACT_IN, 10 ether, 9_890_100, 9_900_000);
    _swap(0, Side.SELL_BASE, AmountMode.EXACT_OUT, 10_110_110, 10 ether, 10_100_000);
    _swap(0, Side.BUY_BASE, AmountMode.EXACT_OUT, 10 ether, 9_890_100, 9_900_000);
    _swap(0, Side.SELL_BASE, AmountMode.EXACT_IN, 10_110_110, 10 ether, 10_100_000);
    assertEq(cash.balanceOf(address(vault)), 1_000_400_000);
    _nativeRecovery();
    _receiptRoundTrip();
    assertEq(IERC20(peer.ASSET()).balanceOf(address(peer.VAULT())), peerCash);
    assertEq(peer.faceExposure(), peerFace);
    assertTrue(peer.isIdle());
    assertEq(cash.balanceOf(address(executor)), 0);
    assertEq(base.allowance(address(executor), address(executor.ROUTER())), 0);
    vault.checkpointValuation();
    uint256 backing = cash.balanceOf(address(vault));
    assertEq(vault.totalAssets(), backing);
    vault.requestRedeem(vault.balanceOf(address(this)), address(this), address(this));
    vault.fulfillWithdrawals(1);
    uint256 credit = vault.maxWithdraw(address(this));
    assertGt(credit, 1_000e6);
    assertLe(backing - credit, 1); // Virtual-share rounding, in six-decimal raw units.
    uint256 beforeCash = cash.balanceOf(address(this));
    vault.withdraw(credit, address(this), address(this));
    assertEq(cash.balanceOf(address(this)), beforeCash + credit);
    assertEq(vault.maxWithdraw(address(this)), 0);
    vm.expectRevert();
    vault.withdraw(1, address(this), address(this));
  }

  function _deploy(HarborBook peer) private {
    cash = new SixDecimalCash();
    base = new TokenMock("Synthetic cash shares", "sSHARE");
    factory = new HarborClaimFactory(address(cash), address(this), 1 days);
    uint64 nonce = vm.getNonce(address(this));
    HarborBook.Config memory c;
    c.vault = vm.computeCreateAddress(address(this), nonce + 1);
    c.executor = address(executor);
    c.asset = address(cash);
    c.aqua = peer.AQUA();
    c.router = peer.ROUTER();
    c.updater = c.governor = c.guardian = c.keeper = address(this);
    c.feeRecipient = FEE;
    c.feeBps = 10;
    c.maxParameterAge = c.maxMarkAge = 60;
    c.maxBasisExposure = 1_000_000e6;
    c.governanceDelay = 1 days;
    c.curve = PricingCurve(1_000_000e6, 0.6e18, 0.0025e18);
    RouteConfig[] memory routes = new RouteConfig[](1);
    routes[0] = RouteConfig(
      address(base),
      vm.computeCreateAddress(address(this), nonce + 2),
      0.99e18,
      1.01e18,
      0,
      0,
      1_000_000e6,
      1_000_000e6,
      10_000e6,
      1_000_000e6
    );
    book = new HarborBook(c, routes);
    vault = new HarborVault(address(cash), address(book), 60, 1e6, 1e6);
    issuer = new CashIssuer(address(book), address(vault), address(base), address(cash), factory);
    for (uint8 d = 5; d <= 19; d += 14) {
      vm.mockCall(address(cash), abi.encodeWithSignature("decimals()"), abi.encode(d));
      vm.expectRevert(AssetUnits.InvalidDecimals.selector);
      this.cashUnit(address(cash));
    }
    vm.clearMockedCalls();
    assertEq(this.cashUnit(address(cash)), 1e6);
    assertEq(this.cashUnit(address(base)), 1e18);
    assertEq(book.route(0).adapter, address(issuer));
    vm.expectRevert(HarborExecutor.Unauthorized.selector);
    executor.registerPool(address(book));
    address governor = executor.GOVERNOR();
    vm.mockCall(address(book), abi.encodeWithSignature("EXECUTOR()"), abi.encode(address(0xbeef)));
    vm.prank(governor);
    vm.expectRevert(HarborExecutor.InvalidPool.selector);
    executor.registerPool(address(book));
    vm.clearMockedCalls();
    vm.mockCall(address(vault), abi.encodeWithSignature("asset()"), abi.encode(peer.ASSET()));
    vm.prank(governor);
    vm.expectRevert(HarborExecutor.InvalidPool.selector);
    executor.registerPool(address(book));
    vm.clearMockedCalls();
    vm.prank(governor);
    executor.registerPool(address(book));
    vm.prank(governor);
    vm.expectRevert(HarborExecutor.InvalidPool.selector);
    executor.registerPool(address(book));
    Trade memory empty;
    vm.expectRevert(HarborExecutor.InvalidPool.selector);
    executor.quoteSwap(address(0xdead), empty);
  }

  function _publish(uint256 route) private {
    book.configurePricing(route, PricingPolicy(0.95e18, 1e18, 0.01e18, 0.01e18, 0, 0));
    book.publishPricing(route, PricingParameters(1e18, block.timestamp, block.timestamp + 60, 1, book.configVersion()));
  }

  function _swap(uint256 route, Side side, AmountMode mode, uint256 input, uint256 output, uint256 coreCash) private {
    bool buy = side == Side.BUY_BASE;
    address token = book.route(route).base;
    Trade memory t = Trade(
      address(this),
      address(this),
      buy ? token : address(cash),
      buy ? address(cash) : token,
      route,
      side,
      mode,
      mode == AmountMode.EXACT_IN ? input : output,
      mode == AmountMode.EXACT_IN ? output : input,
      block.timestamp + 60,
      book.pricingParameters(route).version,
      book.configVersion(),
      book.strategyVersion(route)
    );
    (uint256 qi, uint256 qo,) = executor.quoteSwap(address(book), t);
    assertEq(qi, input);
    assertEq(qo, output);
    FillAmounts memory a = executor.quote(address(book), t);
    assertEq(a.traderIn, input);
    assertEq(a.traderOut, output);
    uint256 cashBefore = cash.balanceOf(address(vault));
    uint256 feesBefore = cash.balanceOf(FEE);
    uint256 traderIn = IERC20(t.tokenIn).balanceOf(address(this));
    uint256 traderOut = IERC20(t.tokenOut).balanceOf(address(this));
    executor.execute(address(book), t);
    assertEq(IERC20(t.tokenIn).balanceOf(address(this)), traderIn - input);
    assertEq(IERC20(t.tokenOut).balanceOf(address(this)), traderOut + output);
    assertEq(cash.balanceOf(address(vault)), buy ? cashBefore - coreCash : cashBefore + coreCash);
    assertEq(cash.balanceOf(FEE) - feesBefore, buy ? coreCash - output : input - coreCash);
  }

  function _nativeRecovery() private {
    _swap(0, Side.BUY_BASE, AmountMode.EXACT_IN, 100 ether, 98_901_000, 99e6);
    uint256[] memory amounts = new uint256[](1);
    amounts[0] = 100 ether;
    RedeemIntent memory intent = RedeemIntent(
      block.chainid,
      address(vault),
      address(book),
      0,
      address(issuer),
      1,
      100 ether,
      100e6,
      1,
      book.getPosition(0).version,
      book.redemptionEpoch(),
      1,
      block.timestamp + 60,
      keccak256(abi.encode(amounts))
    );
    uint256 beforeCash = cash.balanceOf(address(vault));
    uint256 id = book.requestRedemption(intent, amounts)[0].id;
    assertEq(book.faceExposure(), 100e6);
    assertEq(cash.balanceOf(address(vault)), beforeCash);
    uint256[] memory ids = new uint256[](1);
    ids[0] = id;
    uint256[] memory hints = new uint256[](1);
    book.claimRedemptions(0, ids, hints);
    assertEq(cash.balanceOf(address(vault)), beforeCash + 100e6);
    assertEq(book.faceExposure(), 0);
    vm.expectRevert();
    book.claimRedemptions(0, ids, hints);
  }

  function _receiptRoundTrip() private {
    factory.schedule(address(issuer));
    vm.warp(vm.getBlockTimestamp() + 1 days);
    factory.activate(address(issuer));
    book.scheduleClaimFactory(address(factory), 0, 0.99e18, 1e18);
    vm.warp(vm.getBlockTimestamp() + 1 days);
    book.activateClaimFactory(address(factory), address(issuer));
    base.approve(address(issuer), 10 ether);
    address receipt = factory.wrap(
      address(issuer), ClaimImport(CollateralKind.ERC20_AMOUNT, address(base), 999, 10 ether, ""), address(this)
    );
    uint256 route = book.registerClaimMarket(address(factory), receipt);
    vault.refreshStrategy(route);
    _publish(route);
    IERC20(receipt).approve(address(executor), type(uint256).max);
    _swap(route, Side.BUY_BASE, AmountMode.EXACT_IN, 1, 9_890_100, 9_900_000);
    _swap(route, Side.SELL_BASE, AmountMode.EXACT_OUT, 10_110_110, 1, 10_100_000);
    _swap(route, Side.BUY_BASE, AmountMode.EXACT_OUT, 1, 9_890_100, 9_900_000);
    _swap(route, Side.SELL_BASE, AmountMode.EXACT_IN, 10_110_110, 1, 10_100_000);
    IHarborClaim(receipt).recover("");
    uint256 beforeCash = cash.balanceOf(address(this));
    assertEq(IHarborClaim(receipt).redeem(address(this)), 10e6);
    assertEq(cash.balanceOf(address(this)), beforeCash + 10e6);
    vm.expectRevert();
    IHarborClaim(receipt).redeem(address(this));
  }
}
