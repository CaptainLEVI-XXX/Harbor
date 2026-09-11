// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {TokenMock} from "@1inch/solidity-utils/contracts/mocks/TokenMock.sol";
import {Aqua} from "@1inch/aqua/src/Aqua.sol";
import {HarborSwapVMRouter} from "src/swapvm/HarborSwapVMRouter.sol";
import {ISwapVM} from "@1inch/swap-vm/src/interfaces/ISwapVM.sol";
import {TakerTraitsLib} from "@1inch/swap-vm/src/libs/TakerTraits.sol";
import {HarborBook} from "src/book/HarborBook.sol";
import {HarborVault} from "src/vault/HarborVault.sol";
import {HarborExecutor} from "src/execution/HarborExecutor.sol";
import {Trade, FillAmounts, RouteConfig, Side, AmountMode} from "src/types/HarborTypes.sol";
import {Fees} from "src/libraries/Fees.sol";
import {PricingPolicy, PricingParameters, PricingCurve} from "src/types/PricingTypes.sol";
import {FixedPointMathLib as Math} from "solady/utils/FixedPointMathLib.sol";
import {InventoryObservation, ClaimObservation} from "src/types/ClaimTypes.sol";

/// @dev Distinct route identity, sharing explicitly synthetic observation controls.
contract MockRouteObservation {
  address private immutable _provider;

  constructor(address provider) {
    _provider = provider;
  }

  fallback(bytes calldata input) external returns (bytes memory) {
    (bool ok, bytes memory output) = _provider.staticcall(input);
    require(ok);
    return output;
  }
}

/// @notice Synthetic public observations; does not prove a production NAV policy.
contract MockTradingValuation {
  address public ASSET;

  function setAsset(address token) external {
    ASSET = token;
  }
  uint256 public observedAt;
  bool public valid = true;
  mapping(address => uint256) private _numerator;
  mapping(address => uint256) private _denominator;

  function setConversion(address base, uint256 n, uint256 d) external {
    _numerator[base] = n;
    _denominator[base] = d;
  }

  function conversion(address base) public view returns (uint256, uint256) {
    return _denominator[base] == 0 ? (uint256(1), uint256(1)) : (_numerator[base], _denominator[base]);
  }

  constructor(uint256 time) {
    observedAt = time;
  }

  function setValid(bool v) external {
    valid = v;
  }

  function setObservedAt(uint256 time) external {
    observedAt = time;
  }

  function inventory(address base, uint256 shares)
    public
    view
    returns (uint256, uint256, uint256, uint256, bytes32, bool)
  {
    (uint256 n, uint256 d) = conversion(base);
    uint256 face = Math.fullMulDiv(shares, n, d);
    return (face, face, observedAt, 1, keccak256(abi.encode(base, n, d, observedAt)), valid);
  }

  function observePortfolio(address base, uint256 quantity, bytes32[] calldata ids)
    external
    view
    returns (InventoryObservation memory inv, ClaimObservation[] memory claims)
  {
    require(ids.length == 0, "mock has no issuer claims");
    (inv.entitlement, inv.mark, inv.observedAt,, inv.observationHash, inv.valid) = inventory(base, quantity);
    claims = new ClaimObservation[](0);
  }
}

abstract contract TradingFixture is Test {
  function _assertRouterQuote(Trade memory t, FillAmounts memory expected) internal {
    TakerTraitsLib.Args memory args;
    args.taker = address(executor);
    args.isExactIn = t.mode == AmountMode.EXACT_IN;
    args.isAToB = t.tokenIn < t.tokenOut;
    args.isFirstTransferFromTaker = true;
    args.useTransferFromAndAquaPush = true;
    args.isStrictThresholdAmount = true;
    args.threshold = abi.encode(args.isExactIn ? expected.traderOut : expected.traderIn);
    args.instructionsArgs = abi.encode(t);
    ISwapVM.Order memory order = book.currentOrder(t.route);
    bytes memory data = TakerTraitsLib.build(args);
    vm.prank(address(executor)); // Upstream query.taker is the actual caller, not Args.taker.
    (bool ok, bytes memory result) =
      address(router).staticcall(abi.encodeCall(ISwapVM.quote, (order, t.amountSpecified, data)));
    assertTrue(ok, "actual static Router quote");
    (uint256 input, uint256 output, bytes32 hash) = abi.decode(result, (uint256, uint256, bytes32));
    assertEq(input, expected.traderIn);
    assertEq(output, expected.traderOut);
    assertEq(hash, keccak256(abi.encode(order)));
    assertTrue(book.isIdle());
  }

  address internal trader = address(0x7ade);
  address internal alice = address(0xa11ce);
  address internal bob = address(0xb0b);
  address internal feeRecipient = address(0xfee);
  TokenMock internal weth;
  TokenMock[2] internal bases;
  Aqua internal aqua;
  HarborSwapVMRouter internal router;
  HarborBook internal book;
  HarborVault internal vault;
  HarborExecutor internal executor;
  MockTradingValuation internal valuation;
  MockRouteObservation internal secondObservation;
  HarborBook.Config internal deploymentConfig;

  function setUp() public virtual {
    vm.warp(1000);
    weth = _deployWeth();
    bases[0] = _deployBase(0);
    bases[1] = _deployBase(1);
    aqua = new Aqua();
    router = _deployRouter();
    valuation = _deployValuation();
    secondObservation = new MockRouteObservation(address(valuation));
    valuation.setAsset(address(weth));
    executor = new HarborExecutor(address(router), address(this));
    uint64 nonce = vm.getNonce(address(this));
    address expectedBook = vm.computeCreateAddress(address(this), nonce);
    address expectedVault = vm.computeCreateAddress(address(this), nonce + 1);
    HarborBook.Config memory c;
    c.vault = expectedVault;
    c.executor = address(executor);
    c.asset = address(weth);
    c.aqua = address(aqua);
    c.router = address(router);
    c.updater = address(this);
    c.governor = address(this);
    c.guardian = address(this);
    c.keeper = address(this);
    c.feeRecipient = feeRecipient;
    c.feeBps = 10;
    c.maxParameterAge = 60;
    c.maxMarkAge = 60;
    c.maxBasisExposure = 1000 ether;
    c.governanceDelay = 1 days;
    c.curve = PricingCurve(1000 ether, 0.6e18, 0.0025e18);
    deploymentConfig = c;
    RouteConfig[] memory routes = new RouteConfig[](_nativeRoutes());
    for (uint256 i; i < routes.length; ++i) {
      routes[i] = RouteConfig(
        address(bases[i]), _routeAdapter(i, nonce), 0.99e18, 1.01e18, 0, 0, 1000 ether, 1000 ether, 10 ether, 100 ether
      );
    }
    book = _deployBook(c, routes);
    vault = new HarborVault(address(weth), address(book), 60, 1e12, 1e6);
    executor.registerPool(address(book));
    assertEq(address(book), expectedBook);
    assertEq(address(vault), expectedVault);
    _afterDeploy();
    vault.checkpointValuation();
    weth.mint(alice, 10 ether);
    weth.mint(bob, 10 ether);
    weth.mint(trader, 100 ether);
    for (uint256 i; i < 2; ++i) {
      bases[i].mint(trader, 100 ether);
      vm.prank(trader);
      bases[i].approve(address(executor), type(uint256).max);
    }
    vm.prank(trader);
    weth.approve(address(executor), type(uint256).max);
    vm.startPrank(alice);
    weth.approve(address(vault), 10 ether);
    vault.deposit(10 ether, alice);
    vm.stopPrank();
    vm.startPrank(bob);
    weth.approve(address(vault), 10 ether);
    vault.deposit(10 ether, bob);
    vm.stopPrank();
    vault.refreshStrategy(0);
    if (_nativeRoutes() == 2) vault.refreshStrategy(1);
    for (uint256 i; i < _nativeRoutes(); ++i) {
      book.configurePricing(i, PricingPolicy(0.95e18, 1e18, 0.01e18, 0.01e18, 0, 0));
      _publish(i, 1e18);
    }
  }

  function _publish(uint256 route, uint256 discount) internal {
    book.publishPricing(
      route,
      PricingParameters(
        discount,
        vm.getBlockTimestamp(),
        vm.getBlockTimestamp() + 60,
        book.pricingParameters(route).version + 1,
        book.configVersion()
      )
    );
  }

  function _quote(uint256 route, Side side, AmountMode mode, uint256 quantity)
    internal
    view
    returns (Trade memory t, FillAmounts memory a)
  {
    bool buy = side == Side.BUY_BASE;
    (uint256 n, uint256 d) = valuation.conversion(address(bases[route]));
    uint256 face = Math.fullMulDiv(quantity, n, d);
    uint256 input = buy ? quantity : Fees.grossForNet(face * 101 / 100, 10);
    uint256 output = buy ? Fees.net(face * 99 / 100, 10) : quantity;
    t = _trade(route, side, mode, input, output);
    uint256 cash = face * (buy ? 99 : 101) / 100;
    a = FillAmounts(input, output, buy ? input : cash, buy ? cash : output, buy ? cash - output : input - cash);
  }

  function _trade(uint256 route, Side side, AmountMode mode, uint256 input, uint256 output)
    internal
    view
    returns (Trade memory t)
  {
    bool buy = side == Side.BUY_BASE;
    address base = book.route(route).base;
    t = Trade(
      trader,
      trader,
      buy ? base : address(weth),
      buy ? address(weth) : base,
      route,
      side,
      mode,
      mode == AmountMode.EXACT_IN ? input : output,
      mode == AmountMode.EXACT_IN ? output : input,
      vm.getBlockTimestamp() + 60,
      book.pricingParameters(route).version,
      book.configVersion(),
      book.strategyVersion(route)
    );
  }

  function _buy(uint256 route, uint256 quantity) internal virtual {
    (Trade memory t,) = _quote(route, Side.BUY_BASE, AmountMode.EXACT_IN, quantity);
    vm.prank(trader);
    executor.execute(address(book), t);
    vault.checkpointValuation();
  }

  function _deployWeth() internal virtual returns (TokenMock) {
    return new TokenMock("Synthetic ASSET", "ASSET");
  }

  function _deployRouter() internal virtual returns (HarborSwapVMRouter) {
    return new HarborSwapVMRouter(address(aqua), address(weth), address(this), "Harbor", "1");
  }

  function _deployBook(HarborBook.Config memory c, RouteConfig[] memory routes) internal virtual returns (HarborBook) {
    return new HarborBook(c, routes);
  }

  function _deployValuation() internal virtual returns (MockTradingValuation) {
    return new MockTradingValuation(1000);
  }

  function _nativeRoutes() internal pure virtual returns (uint256) {
    return 2;
  }

  function _deployBase(uint256 i) internal virtual returns (TokenMock) {
    return new TokenMock(i == 0 ? "Synthetic route A" : "Synthetic route B", i == 0 ? "BASEA" : "BASEB");
  }

  function _routeAdapter(uint256 i, uint64) internal virtual returns (address) {
    return i == 0 ? address(valuation) : address(secondObservation);
  }
  function _afterDeploy() internal virtual {}
}
