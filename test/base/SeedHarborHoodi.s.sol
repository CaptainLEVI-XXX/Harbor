// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IAqua} from "@1inch/aqua/src/interfaces/IAqua.sol";
import {HarborBook} from "src/book/HarborBook.sol";
import {HarborVault} from "src/vault/HarborVault.sol";
import {HarborExecutor} from "src/execution/HarborExecutor.sol";
import {Trade, Side, AmountMode} from "src/types/HarborTypes.sol";

interface IWethDeposit {
  function deposit() external payable;
}

/// @title SeedHarborHoodi
/// @notice Historical LP funding fixture for the pinned Hoodi regression test.
/// @dev No deployment, price update, donation, trade, or issuer request. Each
/// entrypoint is a separate reviewed broadcast. Dry runs never fund the live pool.
contract SeedHarborHoodi is Script {
  HarborBook public constant BOOK = HarborBook(0x056349edd023191eab7e9E93c376B08de34494DB);
  HarborVault public constant VAULT = HarborVault(0x4c5BfF5143aa26BBb84535df27704B32091ecD25);
  HarborExecutor public constant EXECUTOR = HarborExecutor(0xF7c2593Ba433C261eee79eEc4bcaEbA97636083d);
  address public constant WETH = 0xE0decAa66aED871ac9eb924443D1Bf333Fdb062E;
  address public constant WSTETH = 0x7E99eE3C66636DE415D2d7C880938F2f40f94De4;
  address public constant AQUA = 0xf40826aFd0de1078bc4b39b77E87E42d3b35Fe6A;
  address public constant ROUTER = 0x63C78337758eA9c98b4Ce6Cc9988E72e2D8F3303;
  address public constant TRADER = 0x7c5437B3Ac402EE9316981a66f37Ce46E1468aea;

  error WrongDeployment();
  error NotNewLP();
  error InvalidFunding();
  error VerificationFailed();

  /// @notice Public balances only; env private keys are never logged.
  function inspect() external view {
    _bindings();
    address governor = vm.addr(vm.envUint("HOODI_PRIVATE_KEY"));
    if (governor != BOOK.GOVERNOR()) revert WrongDeployment();
    console2.log("Deployer", governor);
    console2.log("Deployer ETH wei", governor.balance);
    console2.log("Deployer WETH wei", IERC20(WETH).balanceOf(governor));
    for (uint256 index = 1; index <= 2; ++index) {
      address lp = vm.addr(vm.envUint(index == 1 ? "LP_A" : "LP_B"));
      console2.log("LP index", index);
      console2.log("LP address", lp);
      console2.log("LP ETH wei", lp.balance);
      console2.log("LP WETH wei", IERC20(WETH).balanceOf(lp));
      console2.log("LP shares raw", VAULT.balanceOf(lp));
    }
    console2.log("Strategy version", BOOK.strategyVersion(0));
  }

  function prepareLP1() external {
    _prepareLP(1);
  }

  function prepareLP2() external {
    _prepareLP(2);
  }

  /// @notice Bounded gas-only top-up; cannot repeat either WETH allocation.
  function topUpGas() external {
    _bindings();
    uint256 key = vm.envUint("HOODI_PRIVATE_KEY");
    if (vm.addr(key) != BOOK.GOVERNOR()) revert WrongDeployment();
    for (uint256 index = 1; index <= 2; ++index) {
      address lp = vm.addr(vm.envUint(index == 1 ? "LP_A" : "LP_B"));
      if (lp != vm.envAddress(index == 1 ? "HOODI_LP1_ADDRESS" : "HOODI_LP2_ADDRESS")) revert InvalidFunding();
      if (lp.balance < 0.002 ether) {
        uint256 value = 0.002 ether - lp.balance;
        vm.startBroadcast(key);
        (bool ok,) = lp.call{value: value}("");
        vm.stopBroadcast();
        if (!ok) revert VerificationFailed();
        console2.log("Gas top-up recipient", lp);
        console2.log("Gas top-up wei", value);
      }
    }
  }

  /// @dev Deployer transfers exactly the reviewed allocation. Foundry records,
  /// not a wallet's later token balance, determine whether this step already ran.
  function _prepareLP(uint256 index) private {
    _bindings();
    uint256 key = vm.envUint("HOODI_PRIVATE_KEY");
    address governor = vm.addr(key);
    if (governor != BOOK.GOVERNOR()) revert WrongDeployment();
    string memory prefix = index == 1 ? "HOODI_LP1_" : "HOODI_LP2_";
    address lp = vm.addr(vm.envUint(index == 1 ? "LP_A" : "LP_B"));
    if (lp != vm.envAddress(string.concat(prefix, "ADDRESS")) || lp == governor || lp == TRADER) {
      revert InvalidFunding();
    }
    if (VAULT.balanceOf(lp) != 0) revert NotNewLP();
    uint256 assets = vm.envUint(string.concat(prefix, "ASSETS_WEI"));
    if (assets == 0) revert InvalidFunding();
    uint256 beforeBalance = IERC20(WETH).balanceOf(lp);
    uint256 cash = IERC20(WETH).balanceOf(governor);
    uint256 wrap = assets > cash ? assets - cash : 0;
    uint256 gasTopUp = lp.balance < 0.001 ether ? 0.001 ether - lp.balance : 0;
    if (governor.balance <= wrap + gasTopUp) revert InvalidFunding();
    vm.startBroadcast(key);
    if (wrap != 0) IWethDeposit(WETH).deposit{value: wrap}();
    // An explicit bounded native transfer; the LP may be an EIP-7702 account.
    if (gasTopUp != 0) {
      (bool ok,) = lp.call{value: gasTopUp}("");
      if (!ok) revert VerificationFailed();
    }
    if (!IERC20(WETH).transfer(lp, assets)) revert VerificationFailed();
    vm.stopBroadcast();
    if (IERC20(WETH).balanceOf(lp) != beforeBalance + assets) revert VerificationFailed();
    console2.log("Funded LP", lp);
    console2.log("Transferred WETH wei", assets);
    console2.log("Gas top-up ETH wei", gasTopUp);
  }

  /// @notice Deposit the configured exact WETH amount from one new LP (index 1 or 2).
  /// @dev Keys stay in env. Existing WETH is used first; only the shortfall is
  /// wrapped. Checkpoint/approval/deposit are separate EOA transactions: if a
  /// later call fails, earlier calls remain mined. Inspect receipts before resuming.
  function fundLP(uint256 index) public returns (uint256 shares) {
    _bindings();
    if (index != 1 && index != 2) revert InvalidFunding();
    string memory prefix = index == 1 ? "HOODI_LP1_" : "HOODI_LP2_";
    uint256 key = vm.envUint(string.concat(prefix, "PRIVATE_KEY"));
    address lp = vm.addr(key);
    if (lp != vm.envAddress(string.concat(prefix, "ADDRESS"))) revert InvalidFunding();
    uint256 assets = vm.envUint(string.concat(prefix, "ASSETS_WEI"));
    if (assets == 0 || lp == BOOK.GOVERNOR() || lp == TRADER) revert InvalidFunding();
    if (VAULT.balanceOf(lp) != 0) revert NotNewLP();
    if (VAULT.totalSupply() == 0 && assets < VAULT.MIN_INITIAL_ASSETS()) revert InvalidFunding();
    uint256 balance = IERC20(WETH).balanceOf(lp);
    uint256 wrap = assets > balance ? assets - balance : 0;
    if (lp.balance <= wrap) revert InvalidFunding(); // Gas is paid separately.
    uint256 beforeCash = IERC20(WETH).balanceOf(address(VAULT));
    console2.log("LP", lp);
    console2.log("Deposit WETH wei", assets);
    console2.log("Wrap ETH wei", wrap);
    vm.startBroadcast(key);
    // Permissionless observation refresh, not a publisher estimate or NAV override.
    VAULT.checkpointValuation();
    if (assets > VAULT.maxDeposit(lp)) revert InvalidFunding();
    if (wrap != 0) IWethDeposit(WETH).deposit{value: wrap}();
    if (IERC20(WETH).allowance(lp, address(VAULT)) < assets) {
      if (!IERC20(WETH).approve(address(VAULT), assets)) revert VerificationFailed();
    }
    shares = VAULT.deposit(assets, lp);
    vm.stopBroadcast();
    if (shares == 0 || VAULT.balanceOf(lp) != shares || IERC20(WETH).balanceOf(address(VAULT)) != beforeCash + assets) {
      revert VerificationFailed();
    }
    console2.log("LP shares raw (24 decimals)", shares);
  }

  /// @dev Separate entrypoints preserve distinct Foundry broadcast records per LP.
  function fundLP1() external returns (uint256) {
    return fundLP(1);
  }

  function fundLP2() external returns (uint256) {
    return fundLP(2);
  }

  /// @notice Complete only LP_A's unsent deposit; wrapper verifies receipts and nonce.
  /// @dev A fresh checkpoint and full approval must already exist. No wrapping,
  /// approval, gas transfer or publication is repeated. Private key stays in env.
  function resumeLP1() external returns (uint256 shares) {
    _bindings();
    uint256 key = vm.envUint("HOODI_LP1_PRIVATE_KEY");
    address lp = vm.addr(key);
    uint256 assets = vm.envUint("HOODI_LP1_ASSETS_WEI");
    if (lp != vm.envAddress("HOODI_LP1_ADDRESS") || assets == 0) revert InvalidFunding();
    if (VAULT.balanceOf(lp) != 0) revert NotNewLP();
    if (
      IERC20(WETH).balanceOf(lp) < assets || IERC20(WETH).allowance(lp, address(VAULT)) < assets
        || VAULT.maxDeposit(lp) < assets
    ) revert InvalidFunding();
    uint256 beforeCash = IERC20(WETH).balanceOf(address(VAULT));
    vm.startBroadcast(key);
    shares = VAULT.deposit(assets, lp);
    vm.stopBroadcast();
    if (shares == 0 || VAULT.balanceOf(lp) != shares || IERC20(WETH).balanceOf(address(VAULT)) != beforeCash + assets) {
      revert VerificationFailed();
    }
  }

  /// @notice Governor ships the actual Vault maker order through official Aqua.
  /// @dev Repeating publication replaces its allocation/version, never deposits LP
  /// funds again. Pending exits, budgets, prices and live issuer checks still apply.
  function publish() external returns (bytes32 hash) {
    _bindings();
    uint256 key = vm.envUint("HOODI_PRIVATE_KEY");
    if (vm.addr(key) != BOOK.GOVERNOR()) revert WrongDeployment();
    if (VAULT.totalSupply() == 0 || VAULT.tradingCash(BOOK.CASH_BUFFER()) == 0) revert InvalidFunding();
    vm.startBroadcast(key);
    VAULT.checkpointValuation();
    hash = VAULT.refreshStrategy(0);
    vm.stopBroadcast();
    _allocation(hash);
    console2.log("Aqua strategy version", BOOK.strategyVersion(0));
    console2.logBytes32(hash);
  }

  /// @notice Read-only quote proof for both cash-funded buying modes. No trader key.
  /// @dev An ask needs managed wstETH bought through Harbor; donations do not count.
  function verify(uint256 baseIn, uint256 cashOut) external view {
    _bindings();
    _allocation(BOOK.strategyHash(0));
    if (baseIn == 0 || cashOut == 0) revert InvalidFunding();
    Trade memory t = Trade({
      trader: TRADER,
      receiver: TRADER,
      tokenIn: WSTETH,
      tokenOut: WETH,
      route: 0,
      side: Side.BUY_BASE,
      mode: AmountMode.EXACT_IN,
      amountSpecified: baseIn,
      limitAmount: 0,
      deadline: block.timestamp + 5 minutes,
      pricingVersion: BOOK.pricingParameters(0).version,
      configVersion: BOOK.configVersion(),
      strategyVersion: BOOK.strategyVersion(0)
    });
    (uint256 input, uint256 output, bytes32 hash) = EXECUTOR.quoteSwap(address(BOOK), t);
    if (input != baseIn || output == 0 || hash != BOOK.strategyHash(0)) revert VerificationFailed();
    console2.log("Exact-input bid: WETH out", output);
    t.mode = AmountMode.EXACT_OUT;
    t.amountSpecified = cashOut;
    t.limitAmount = type(uint256).max;
    (input, output, hash) = EXECUTOR.quoteSwap(address(BOOK), t);
    if (input == 0 || output != cashOut || hash != BOOK.strategyHash(0)) revert VerificationFailed();
    console2.log("Exact-output bid: wstETH in", input);
  }

  function _allocation(bytes32 hash) private view {
    if (hash == 0 || BOOK.strategyVersion(0) == 0) revert VerificationFailed();
    (uint248 cash, uint8 cashCount) = IAqua(AQUA).rawBalances(address(VAULT), ROUTER, hash, WETH);
    (, uint8 baseCount) = IAqua(AQUA).rawBalances(address(VAULT), ROUTER, hash, WSTETH);
    if (cash == 0 || cashCount != 2 || baseCount != 2) revert VerificationFailed();
  }

  function _bindings() private view {
    if (
      block.chainid != 560048 || address(BOOK.VAULT()) != address(VAULT) || address(VAULT.BOOK()) != address(BOOK)
        || VAULT.asset() != WETH || BOOK.AQUA() != AQUA || BOOK.ROUTER() != ROUTER
        || address(BOOK.EXECUTOR()) != address(EXECUTOR) || EXECUTOR.vaultOf(address(BOOK)) != address(VAULT)
        || BOOK.route(0).base != WSTETH
    ) revert WrongDeployment();
  }
}
