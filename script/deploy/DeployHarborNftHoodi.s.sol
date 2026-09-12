// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {DeployHarborHoodi} from "script/deploy/DeployHarborHoodi.s.sol";
import {HarborBook} from "src/book/HarborBook.sol";
import {HarborVault} from "src/vault/HarborVault.sol";
import {LidoAdapter} from "src/adapters/LidoAdapter.sol";
import {Periphery} from "src/Periphery.sol";
import {IAqua} from "@1inch/aqua/src/interfaces/IAqua.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {NftTrade} from "src/types/NftTypes.sol";
import {Trade, Side, AmountMode, FillAmounts} from "src/types/HarborTypes.sol";
import {PricingPolicy, PricingParameters} from "src/types/PricingTypes.sol";
import {console2} from "forge-std/console2.sol";

/// @notice New single-Book NFT demo. Inherited run() reuses existing WETH/Aqua/Router.
/// @dev Commands are separately reviewed Foundry broadcasts. They are NOT atomic
/// across EOAs. Never rerun funding after a partial broadcast; inspect receipts
/// and resume the original record. Existing deployment records remain untouched.
contract DeployHarborNftHoodi is DeployHarborHoodi {
  uint256 internal constant GAS_FLOOR = 0.002 ether;

  /// @notice Configure both markets once and deploy the native wrapper for this pool.
  /// @dev No factory admission or per-ID markets are needed for original NFTs.
  /// Policy configuration precedes version-bound publications. Zero protocol fees,
  /// 100-day prices/marks and illustrative spreads are controlled-testnet settings.
  function setup(address target) external returns (Periphery periphery) {
    (uint256 key, address deployer) = _signer();
    (HarborBook book, HarborVault vault, LidoAdapter adapter) = _pool(target, deployer);
    if (book.nftParameters(0).version != 0 || book.pricingParameters(0).version != 0) {
      revert InvalidDemoConfiguration();
    }
    vm.startBroadcast(key);
    book.configurePricing(0, PricingPolicy(1e18, 1e18, 0.01e18, 0.01e18, 0, 0));
    book.configureNfts(0, PricingPolicy(0.975e18, 0.975e18, 0.005e18, 0.005e18, 0, 0));
    adapter.publish(1e18, 1e18, block.timestamp, block.timestamp + LIFETIME, adapter.version() + 1);
    book.publishPricing(
      0, PricingParameters(1e18, block.timestamp, block.timestamp + LIFETIME, 1, book.configVersion())
    );
    book.publishNfts(
      0, PricingParameters(0.975e18, block.timestamp, block.timestamp + LIFETIME, 1, book.configVersion())
    );
    vault.checkpointValuation();
    periphery = new Periphery(WETH, address(book.EXECUTOR()));
    vm.stopBroadcast();
    console2.log("Book", target);
    console2.log("Vault", address(vault));
    console2.log("Adapter", address(adapter));
    console2.log("Periphery", address(periphery));
  }

  /// @notice Fund LP_A and LP_B with $500-equivalent native principal EACH, then deposit.
  /// @param ethUsd6 Reviewed mainnet ETH/USD observation, six decimals; not an oracle input.
  /// @param observedAt Observation time in Unix seconds. Refresh if older than one hour.
  /// @dev Floor principal to wei. Gas top-ups are separate, not LP capital. The
  /// wrapper converts native ETH using the existing WETH and mints to each LP.
  /// The price/amount must be frozen in the operator's run record before broadcast.
  function seed(address target, address wrapper, uint256 ethUsd6, uint256 observedAt) external {
    (uint256 governorKey, address governor) = _signer();
    (HarborBook book, HarborVault vault,) = _pool(target, governor);
    Periphery periphery = Periphery(payable(wrapper));
    if (
      ethUsd6 == 0 || observedAt > block.timestamp || block.timestamp - observedAt > 1 hours || vault.totalSupply() != 0
        || book.nftParameters(0).version == 0 || periphery.WETH() != WETH
        || address(periphery.EXECUTOR()) != address(book.EXECUTOR())
    ) revert InvalidDemoConfiguration();
    uint256 assets = 500e6 * 1 ether / ethUsd6;
    uint256[2] memory keys = [vm.envUint("LP_A"), vm.envUint("LP_B")];
    address[2] memory lps = [vm.addr(keys[0]), vm.addr(keys[1])];
    if (lps[0] == lps[1] || lps[0] == governor || lps[1] == governor || assets < vault.MIN_INITIAL_ASSETS()) {
      revert InvalidDemoConfiguration();
    }
    if (governor.balance <= assets * 2 + GAS_FLOOR * 2) revert InvalidDemoConfiguration();
    uint256 beforeCash = IERC20(WETH).balanceOf(address(vault));
    for (uint256 i; i < 2; ++i) {
      uint256 gasTopUp = lps[i].balance < GAS_FLOOR ? GAS_FLOOR - lps[i].balance : 0;
      vm.startBroadcast(governorKey);
      (bool ok,) = lps[i].call{value: assets + gasTopUp}("");
      if (!ok) revert InvalidDemoConfiguration();
      vm.stopBroadcast();
      vm.startBroadcast(keys[i]);
      uint256 shares = periphery.deposit{value: assets}(target, 1);
      vm.stopBroadcast();
      if (shares == 0 || vault.balanceOf(lps[i]) != shares) revert InvalidDemoConfiguration();
      console2.log("LP", lps[i]);
      console2.log("Deposit wei", assets);
      console2.log("Shares raw", shares);
      console2.log("Gas top-up wei", gasTopUp);
    }
    if (IERC20(WETH).balanceOf(address(vault)) != beforeCash + assets * 2) revert InvalidDemoConfiguration();
    vm.startBroadcast(governorKey);
    vault.checkpointValuation();
    vault.refreshStrategy(0);
    vm.stopBroadcast();
    _allocation(book, vault);
  }

  /// @notice Read-only live readiness plus both token-bid modes. No trader key or trade.
  function verify(address target, address wrapper, address trader) external view {
    (, address governor) = _signer();
    (HarborBook book, HarborVault vault,) = _pool(target, governor);
    Periphery periphery = Periphery(payable(wrapper));
    if (periphery.WETH() != WETH || address(periphery.EXECUTOR()) != address(book.EXECUTOR())) {
      revert InvalidDemoConfiguration();
    }
    _allocation(book, vault);
    if (book.nftParameters(0).validUntil <= block.timestamp || vault.totalAssets() == 0) {
      revert InvalidDemoConfiguration();
    }
    Trade memory t = Trade(
      trader,
      trader,
      WSTETH,
      WETH,
      0,
      Side.BUY_BASE,
      AmountMode.EXACT_IN,
      1e12,
      0,
      block.timestamp + 5 minutes,
      book.pricingParameters(0).version,
      book.configVersion(),
      book.strategyVersion(0)
    );
    (uint256 input, uint256 output,) = book.EXECUTOR().quoteSwap(target, t);
    if (input != 1e12 || output == 0) revert InvalidDemoConfiguration();
    console2.log("Token bid WETH", output);
    t.mode = AmountMode.EXACT_OUT;
    t.amountSpecified = output;
    t.limitAmount = type(uint256).max;
    (input, output,) = book.EXECUTOR().quoteSwap(target, t);
    if (input == 0 || output != t.amountSpecified) revert InvalidDemoConfiguration();
  }

  /// @notice Verify both whole-ID quote modes for an actual pending NFT in its current custody.
  /// @dev acquired=true means the wallet sells to the Vault. false requires the
  /// Vault to already own the ID. This reads only; approval is needed at execution.
  function verifyNft(address target, address trader, uint256 id, bool acquired) external view {
    (, address governor) = _signer();
    (HarborBook book,,) = _pool(target, governor);
    NftTrade memory t = NftTrade(
      trader,
      trader,
      0,
      id,
      acquired ? Side.BUY_BASE : Side.SELL_BASE,
      acquired ? AmountMode.EXACT_IN : AmountMode.EXACT_OUT,
      1,
      acquired ? 0 : type(uint256).max,
      block.timestamp + 5 minutes,
      book.nftParameters(0).version,
      book.configVersion(),
      book.nftGeneration(0, id)
    );
    FillAmounts memory a = book.quoteNft(t);
    uint256 cash = acquired ? a.traderOut : a.traderIn;
    if (cash == 0 || (acquired ? a.traderIn : a.traderOut) != 1) revert InvalidDemoConfiguration();
    t.mode = acquired ? AmountMode.EXACT_OUT : AmountMode.EXACT_IN;
    t.amountSpecified = cash;
    t.limitAmount = 1;
    FillAmounts memory b = book.quoteNft(t);
    if (a.traderIn != b.traderIn || a.traderOut != b.traderOut || a.fee != b.fee) revert InvalidDemoConfiguration();
    console2.log("NFT ID", id);
    console2.log("NFT cash quote wei", cash);
  }

  function _allocation(HarborBook book, HarborVault vault) private view {
    bytes32 hash = book.strategyHash(0);
    (uint248 cash, uint8 count) = IAqua(AQUA).rawBalances(address(vault), ROUTER, hash, WETH);
    (, uint8 baseCount) = IAqua(AQUA).rawBalances(address(vault), ROUTER, hash, WSTETH);
    if (hash == 0 || book.strategyVersion(0) == 0 || cash == 0 || count != 2 || baseCount != 2) {
      revert InvalidDemoConfiguration();
    }
  }
}
