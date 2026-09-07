// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {TokenMock} from "@1inch/solidity-utils/contracts/mocks/TokenMock.sol";
import {Aqua} from "@1inch/aqua/src/Aqua.sol";
import {AquaSwapVMRouter} from "@1inch/swap-vm/src/routers/AquaSwapVMRouter.sol";
import {ISwapVM} from "@1inch/swap-vm/src/interfaces/ISwapVM.sol";
import {HarborBook} from "src/book/HarborBook.sol";
import {HarborVault} from "src/vault/HarborVault.sol";
import {HarborExecutor} from "src/execution/HarborExecutor.sol";
import {Trade, FillTerms, FillAmounts, RouteConfig, Side, AmountMode} from "src/types/HarborTypes.sol";
import {Amounts} from "src/libraries/Amounts.sol";
import {Fees} from "src/libraries/Fees.sol";

/// @notice Synthetic public observations; does not prove a production NAV policy.
contract MockTradingValuation {
  uint256 public observedAt;
  bool public valid = true;

  constructor(uint256 time) {
    observedAt = time;
  }

  function setValid(bool v) external {
    valid = v;
  }

  function inventory(address base, uint256 shares)
    external
    view
    returns (uint256, uint256, uint256, uint256, bytes32, bool)
  {
    return (shares, shares, observedAt, 1, keccak256(abi.encode(base, observedAt)), valid);
  }
}

/// @notice Synthetic permit fixture, not authenticated CRE evidence.
contract MockTradingPolicy {
  mapping(bytes32 => bool) public isApproved;

  function approve(bytes32 hash, bool allowed) external {
    isApproved[hash] = allowed;
  }
}

abstract contract TradingFixture is Test {
  uint256 internal constant QUOTE_TEST_KEY = 0x716f7465;
  address internal trader = address(0x7ade);
  address internal alice = address(0xa11ce);
  address internal bob = address(0xb0b);
  address internal feeRecipient = address(0xfee);
  TokenMock internal weth;
  TokenMock[2] internal bases;
  Aqua internal aqua;
  AquaSwapVMRouter internal router;
  HarborBook internal book;
  HarborVault internal vault;
  HarborExecutor internal executor;
  MockTradingValuation internal valuation;
  MockTradingPolicy internal policy;
  HarborBook.Config internal deploymentConfig;
  uint256 private nextNonce;

  function setUp() public virtual {
    vm.warp(1000);
    weth = _deployWeth();
    bases[0] = new TokenMock("Synthetic route A", "BASEA");
    bases[1] = new TokenMock("Synthetic route B", "BASEB");
    aqua = new Aqua();
    router = new AquaSwapVMRouter(address(aqua), address(weth), address(this), "Harbor", "1");
    valuation = new MockTradingValuation(1000);
    policy = new MockTradingPolicy();
    uint64 nonce = vm.getNonce(address(this));
    address expectedBook = vm.computeCreateAddress(address(this), nonce);
    address expectedVault = vm.computeCreateAddress(address(this), nonce + 1);
    address expectedExecutor = vm.computeCreateAddress(address(this), nonce + 2);
    HarborBook.Config memory c;
    c.vault = expectedVault;
    c.executor = expectedExecutor;
    c.weth = address(weth);
    c.aqua = address(aqua);
    c.router = address(router);
    c.signer = vm.addr(QUOTE_TEST_KEY);
    c.governor = address(this);
    c.guardian = address(this);
    c.receiver = address(policy);
    c.valuation = address(valuation);
    c.feeRecipient = feeRecipient;
    c.feeBps = 10;
    c.maxQuoteAge = 60;
    c.maxMarkAge = 60;
    c.depositCap = 1000 ether;
    c.governanceDelay = 1 days;
    deploymentConfig = c;
    RouteConfig[] memory routes = new RouteConfig[](2);
    for (uint256 i; i < 2; ++i) {
      routes[i] = RouteConfig(
        address(bases[i]), address(uint160(100 + i)), 0.99e18, 1.01e18, 0, 0, 1000 ether, 1000 ether, 10 ether
      );
    }
    book = new HarborBook(c, routes);
    vault = new HarborVault(address(weth), address(book), 60, 1000 ether, 1e12, 1e6);
    executor = new HarborExecutor(address(book), address(vault), address(router), address(weth));
    assertEq(address(book), expectedBook);
    assertEq(address(vault), expectedVault);
    assertEq(address(executor), expectedExecutor);
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
    vault.refreshStrategy(1);
  }

  function _quote(uint256 route, Side side, AmountMode mode, uint256 quantity)
    internal
    returns (Trade memory t, FillTerms memory f, bytes memory signature, ISwapVM.Order memory order)
  {
    bool buy = side == Side.BUY_BASE;
    uint256 input = buy ? quantity : Fees.grossForNet(quantity * 101 / 100, 10);
    uint256 output = buy ? Fees.net(quantity * 99 / 100, 10) : quantity;
    t = Trade(
      trader,
      trader,
      buy ? address(bases[route]) : address(weth),
      buy ? address(weth) : address(bases[route]),
      route,
      side,
      mode,
      mode == AmountMode.EXACT_IN ? input : output,
      mode == AmountMode.EXACT_IN ? output : input + 1 ether,
      1060,
      ++nextNonce
    );
    FillAmounts memory a = Amounts.normalize(t, input, output, 10);
    order = book.currentOrder(route);
    f.vault = address(vault);
    f.adapter = address(uint160(100 + route));
    f.feeRecipient = feeRecipient;
    f.strategyVersion = book.strategyVersion(route);
    f.adapterVersion = 1;
    f.epoch = book.quoteEpoch();
    f.nonce = nextNonce;
    f.portfolioVersion = book.portfolioVersion();
    f.positionVersion = book.getPosition(route).version;
    (, f.valuationVersion,) = vault.valuationIdentity();
    f.policyVersion = 1;
    f.traderIn = input;
    f.traderOut = output;
    f.routerIn = a.routerIn;
    f.routerOut = a.routerOut;
    f.fee = a.fee;
    f.feeBps = 10;
    f.observedAt = 1000;
    f.validUntil = 1060;
    f.orderHash = router.hash(order);
    f.observationHash = keccak256(abi.encode(address(bases[route]), uint256(1000)));
    signature = _sign(t, f);
  }

  function _sign(Trade memory t, FillTerms memory f) internal returns (bytes memory signature) {
    bytes32 digest = book.fillDigest(t, f);
    (uint8 v, bytes32 r, bytes32 s) = vm.sign(QUOTE_TEST_KEY, digest);
    policy.approve(digest, true);
    return abi.encodePacked(r, s, v);
  }

  function _buy(uint256 route, uint256 quantity) internal {
    (Trade memory t, FillTerms memory f, bytes memory sig, ISwapVM.Order memory order) =
      _quote(route, Side.BUY_BASE, AmountMode.EXACT_IN, quantity);
    vm.prank(trader);
    executor.execute(t, f, sig, order);
    vault.checkpointValuation();
  }

  function _deployWeth() internal virtual returns (TokenMock) {
    return new TokenMock("Synthetic WETH", "WETH");
  }
}
