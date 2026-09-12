// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {DeployHarbor} from "script/deploy/DeployHarbor.s.sol";
import {HarborBook} from "src/book/HarborBook.sol";
import {HarborVault} from "src/vault/HarborVault.sol";
import {HarborClaimFactory} from "src/claims/HarborClaimFactory.sol";
import {LidoAdapter} from "src/adapters/LidoAdapter.sol";
import {LidoViews} from "src/adapters/lido/LidoViews.sol";
import {SwapVM} from "@1inch/swap-vm/src/SwapVM.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {RouteConfig} from "src/types/HarborTypes.sol";
import {PricingCurve, PricingPolicy, PricingParameters} from "src/types/PricingTypes.sol";

/// @notice Controlled Hoodi deployment. No proxies, token mocks or new Aqua/router.
/// @dev Separate commands deliberately do not auto-run trades or create issuer
/// requests. Simulate first without --broadcast. Resume interrupted broadcasts
/// from Foundry's recorded transactions; rerunning run() deploys a new pool.
contract DeployHarborHoodi is DeployHarbor {
  address internal constant WETH = 0xE0decAa66aED871ac9eb924443D1Bf333Fdb062E;
  address internal constant AQUA = 0xf40826aFd0de1078bc4b39b77E87E42d3b35Fe6A;
  address internal constant ROUTER = 0x63C78337758eA9c98b4Ce6Cc9988E72e2D8F3303;
  address internal constant WSTETH = 0x7E99eE3C66636DE415D2d7C880938F2f40f94De4;
  address internal constant QUEUE = 0xfe56573178f1bcdf53F01A6E9977670dcBBD9186;
  uint256 internal constant LIFETIME = 100 days;
  address public constant DEMO_TRADER = 0x7c5437B3Ac402EE9316981a66f37Ce46E1468aea;
  uint256 internal constant INVENTORY_MARGIN = 0.01e18;
  uint256 internal constant RECEIPT_BID = 0.97e18;
  uint256 internal constant RECEIPT_ASK = 0.98e18;

  error InvalidDemoConfiguration();

  /// @notice Deploy only Harbor using explicit raw-unit budgets from the environment.
  /// @dev The signer owns every admin role and receives fees (configured to zero).
  function run() external returns (Deployment memory d) {
    (uint256 key, address deployer) = _signer();
    if (address(SwapVM(payable(ROUTER)).AQUA()) != AQUA || address(SwapVM(payable(ROUTER)).WETH()) != WETH) {
      revert InvalidDemoConfiguration();
    }
    HarborBook.Config memory c;
    c.asset = WETH;
    c.aqua = AQUA;
    c.router = ROUTER;
    c.updater = c.governor = c.guardian = c.keeper = c.feeRecipient = deployer;
    c.maxParameterAge = c.maxMarkAge = LIFETIME;
    c.governanceDelay = 1 days; // Non-admission governance is NOT accelerated.
    c.maxBasisExposure = vm.envUint("HOODI_MAX_BASIS_WEI");
    c.cashBuffer = vm.envUint("HOODI_CASH_BUFFER_WEI");
    c.curve = PricingCurve(vm.envUint("HOODI_FACE_CAP_WEI"), 0.6e18, vm.envUint("HOODI_CAPACITY_KAPPA_WAD"));
    uint256 margin = INVENTORY_MARGIN;
    RouteConfig[] memory routes = new RouteConfig[](1);
    routes[0] = RouteConfig(
      WSTETH,
      address(0),
      1e18 - margin,
      1e18 + margin,
      0,
      0,
      c.maxBasisExposure,
      vm.envUint("HOODI_MAX_PURCHASES_WEI"),
      vm.envUint("HOODI_LOSS_BUDGET_WEI"),
      vm.envUint("HOODI_DAILY_REDEMPTION_WEI")
    );
    // Resolve all environment inputs before the first signed transaction.
    uint256 minSeed = vm.envUint("HOODI_MIN_SEED_WEI");
    uint256 minRequest = vm.envUint("HOODI_MIN_REQUEST_SHARES");
    vm.startBroadcast(key);
    d.factory = new HarborClaimFactory(WETH, deployer, 0);
    // _core creates Executor first; derive the adapter after that known nonce.
    // Executor + Book + Vault + registration = four deployer transactions.
    routes[0].adapter = vm.computeCreateAddress(deployer, vm.getNonce(deployer) + 4);
    (d.book, d.vault, d.executor) = _core(deployer, c, routes, minSeed, minRequest);
    d.adapter = new LidoAdapter(
      address(d.book),
      address(d.vault),
      WSTETH,
      WETH,
      QUEUE,
      LidoViews.Config(address(d.factory), deployer, deployer, LIFETIME, 1 days)
    );
    vm.stopBroadcast();
    if (address(d.adapter) != routes[0].adapter || d.book.FEE_BPS() != 0) revert DeploymentMismatch();
  }

  /// @notice Approve the receipt integration, then publish native-route price and NAV inputs.
  /// @dev Price publication follows configVersion-changing admission. No LP funds moved.
  function configure(address bookAddress) external {
    (uint256 key, address deployer) = _signer();
    (HarborBook book, HarborVault vault, LidoAdapter adapter) = _pool(bookAddress, deployer);
    HarborClaimFactory factory = HarborClaimFactory(adapter.FACTORY());
    uint256 bid = RECEIPT_BID;
    uint256 ask = RECEIPT_ASK;
    PricingPolicy memory policy = PricingPolicy(1e18, 1e18, 1e18 - book.route(0).bid, book.route(0).ask - 1e18, 0, 0);
    vm.startBroadcast(key);
    if (!factory.active(address(adapter))) {
      (uint64 ready,, bool retired,) = factory.admissions(address(adapter));
      if (retired) revert InvalidDemoConfiguration();
      if (ready == 0) factory.schedule(address(adapter));
      factory.activate(address(adapter));
    }
    if (!book.claimIntegration(address(factory), address(adapter)).enabled) {
      if (book.claimIntegration(address(factory), address(adapter)).readyAt == 0) {
        book.scheduleClaimFactory(address(factory), 0, bid, ask);
      }
      book.activateClaimFactory(address(factory), address(adapter));
    }
    if (
      book.claimIntegration(address(factory), address(adapter)).bid != bid
        || book.claimIntegration(address(factory), address(adapter)).ask != ask
    ) revert InvalidDemoConfiguration();
    // Independent public marks; do not discount LP NAV to manufacture a trading spread.
    adapter.publish(1e18, 1e18, block.timestamp, block.timestamp + LIFETIME, adapter.version() + 1);
    if (book.pricingPolicy(0).minDiscount == 0) book.configurePricing(0, policy);
    book.publishPricing(
      0,
      PricingParameters(
        1e18, block.timestamp, block.timestamp + LIFETIME, book.pricingParameters(0).version + 1, book.configVersion()
      )
    );
    vault.checkpointValuation();
    vm.stopBroadcast();
  }

  /// @notice Publish allocations after users deposit through the frontend.
  /// @dev No wrapping or deposits. Vault remains the maker and calls Aqua.ship.
  function publishStrategy(address bookAddress, uint256 route) external {
    (uint256 key, address deployer) = _signer();
    (, HarborVault vault,) = _pool(bookAddress, deployer);
    vm.startBroadcast(key);
    vault.refreshStrategy(route);
    vm.stopBroadcast();
  }

  /// @notice Register an already imported pending receipt held by the demo trader.
  /// @dev No asset acquisition, transfer, or issuer request; this configures its market.
  /// Run once per receipt. Resume partial broadcast transactions, not a fresh registration.
  function registerReceipt(address bookAddress, address receipt) external returns (uint256 route) {
    (uint256 key, address deployer) = _signer();
    (HarborBook book,, LidoAdapter adapter) = _pool(bookAddress, deployer);
    if (IERC20(receipt).balanceOf(DEMO_TRADER) != 1) revert InvalidDemoConfiguration();
    vm.startBroadcast(key);
    route = book.registerClaimMarket(adapter.FACTORY(), receipt);
    // 97.5% discount +/- 0.5% nominal margin gives 97% bid / 98% ask before capacity.
    book.configurePricing(route, PricingPolicy(0.975e18, 0.975e18, 0.005e18, 0.005e18, 0, 0));
    book.publishPricing(
      route, PricingParameters(0.975e18, block.timestamp, block.timestamp + LIFETIME, 1, book.configVersion())
    );
    vm.stopBroadcast();
    // publishStrategy is separate so users can first fund the Vault from the frontend.
  }

  function _signer() internal view returns (uint256 key, address deployer) {
    if (block.chainid != 560048) revert InvalidDemoConfiguration();
    key = vm.envUint("HOODI_PRIVATE_KEY");
    deployer = vm.addr(key);
  }

  function _pool(address target, address deployer)
    internal
    view
    returns (HarborBook book, HarborVault vault, LidoAdapter adapter)
  {
    book = HarborBook(target);
    vault = book.VAULT();
    adapter = LidoAdapter(payable(book.route(0).adapter));
    if (
      book.GOVERNOR() != deployer || book.parameterUpdater() != deployer || book.FEE_RECIPIENT() != deployer
        || book.GUARDIAN() != deployer || book.KEEPER() != deployer || adapter.GOVERNOR() != deployer
        || adapter.publisher() != deployer || HarborClaimFactory(adapter.FACTORY()).GOVERNOR() != deployer
        || book.FEE_BPS() != 0 || book.ASSET() != WETH || book.AQUA() != AQUA || book.ROUTER() != ROUTER
        || book.route(0).bid != 1e18 - INVENTORY_MARGIN || book.route(0).ask != 1e18 + INVENTORY_MARGIN
        || address(vault.BOOK()) != target || vault.ASSET() != WETH || adapter.BOOK() != target
        || adapter.VAULT() != address(vault) || adapter.BASE() != WSTETH || adapter.ASSET() != WETH
        || book.MAX_PARAMETER_AGE() != LIFETIME || book.MAX_MARK_AGE() != LIFETIME || vault.MAX_MARK_AGE() != LIFETIME
        || adapter.MAX_AGE() != LIFETIME
    ) revert InvalidDemoConfiguration();
  }
}
