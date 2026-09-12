// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {HarborBook} from "src/book/HarborBook.sol";
import {HarborVault} from "src/vault/HarborVault.sol";
import {Periphery} from "src/Periphery.sol";
import {ILidoWithdrawalQueue as Queue, IWstETHConversion} from "src/interfaces/ILidoWithdrawalQueue.sol";
import {NftTrade} from "src/types/NftTypes.sol";
import {Trade, Side, AmountMode} from "src/types/HarborTypes.sol";

/// @notice Populate an already-funded demo pool. No LP deposits, buyer, donations or new deployments.
/// @dev Separate broadcasts are NOT atomic. Record receipts between stages; never blindly rerun funding/staking.
contract SeedInventoryHoodi is Script {
  address internal constant WETH = 0xE0decAa66aED871ac9eb924443D1Bf333Fdb062E;
  address internal constant WSTETH = 0x7E99eE3C66636DE415D2d7C880938F2f40f94De4;
  address internal constant QUEUE = 0xfe56573178f1bcdf53F01A6E9977670dcBBD9186;

  error InvalidSeed();

  struct Context {
    HarborBook book;
    HarborVault vault;
    Periphery periphery;
    uint256 governorKey;
    uint256 aKey;
    uint256 bKey;
    address a;
    address b;
  }

  /// @notice Deployer sends explicit new principal plus a bounded gas top-up to each trader.
  /// @dev LP_A/LP_B are checked, never used to sign or fund anything. Amounts are native wei, not USD.
  function fund(uint256 principalA, uint256 principalB, uint256 gasFloor) external {
    Context memory c = _context();
    if (principalA == 0 || principalB == 0 || gasFloor == 0 || gasFloor > 0.02 ether) revert InvalidSeed();
    uint256 a = principalA + (c.a.balance < gasFloor ? gasFloor - c.a.balance : 0);
    uint256 b = principalB + (c.b.balance < gasFloor ? gasFloor - c.b.balance : 0);
    vm.startBroadcast(c.governorKey);
    _send(c.a, a);
    _send(c.b, b);
    vm.stopBroadcast();
    console2.log("Trader A funded wei", a);
    console2.log("Trader B funded wei", b);
  }

  /// @notice Acquire only the requested amount; existing wallet assets are not swept.
  /// @dev Lido's wstETH receive function stakes native ETH and wraps stETH. Check minted balance delta.
  function stake(bool traderA, uint256 ethWei, uint256 minWsteth) external {
    Context memory c = _context();
    address owner = traderA ? c.a : c.b;
    if (ethWei == 0 || minWsteth == 0 || owner.balance <= ethWei) revert InvalidSeed();
    uint256 beforeBalance = IERC20(WSTETH).balanceOf(owner);
    vm.startBroadcast(traderA ? c.aKey : c.bKey);
    _send(WSTETH, ethWei);
    vm.stopBroadcast();
    uint256 minted = IERC20(WSTETH).balanceOf(owner) - beforeBalance;
    if (minted < minWsteth) revert InvalidSeed();
    console2.log("Minted wstETH raw", minted);
  }

  /// @notice Trader B requests 1..8 whole NFTs, with independently chosen wstETH amounts.
  /// @dev Printed IDs are simulation results. After broadcast use WithdrawalRequested receipt logs, not these predictions.
  function requestNfts(uint256[] calldata amounts) external returns (uint256[] memory ids) {
    Context memory c = _context();
    if (amounts.length == 0 || amounts.length > 8) revert InvalidSeed();
    uint256 total;
    uint256 minimum = Queue(QUEUE).MIN_STETH_WITHDRAWAL_AMOUNT();
    uint256 maximum = Queue(QUEUE).MAX_STETH_WITHDRAWAL_AMOUNT();
    for (uint256 i; i < amounts.length; ++i) {
      uint256 nominal = IWstETHConversion(WSTETH).getStETHByWstETH(amounts[i]);
      if (nominal < minimum || nominal > maximum) revert InvalidSeed();
      total += amounts[i];
    }
    if (IERC20(WSTETH).balanceOf(c.b) < total) revert InvalidSeed();
    vm.startBroadcast(c.bKey);
    IERC20(WSTETH).approve(QUEUE, total);
    ids = Queue(QUEUE).requestWithdrawalsWstETH(amounts, c.b);
    vm.stopBroadcast();
    for (uint256 i; i < ids.length; ++i) {
      console2.log("Predicted NFT ID; confirm receipt", ids[i]);
    }
  }

  /// @notice Trader A sells an explicit wstETH lot through the ordinary Aqua/SwapVM path.
  function sellToken(uint256 amount, uint256 minEthOut, uint256 cashFloor) external {
    Context memory c = _context();
    if (amount == 0 || minEthOut == 0) revert InvalidSeed();
    Trade memory t = Trade(
      address(c.periphery),
      c.a,
      WSTETH,
      WETH,
      0,
      Side.BUY_BASE,
      AmountMode.EXACT_IN,
      amount,
      minEthOut,
      block.timestamp + 1 hours,
      c.book.pricingParameters(0).version,
      c.book.configVersion(),
      c.book.strategyVersion(0)
    );
    (uint256 input, uint256 output,) = c.book.EXECUTOR().quoteSwap(address(c.book), t);
    if (input != amount || output < minEthOut) revert InvalidSeed();
    _cash(c, output, cashFloor);
    uint256 beforePosition = c.book.getPosition(0).shares;
    vm.startBroadcast(c.aKey);
    IERC20(WSTETH).approve(address(c.periphery), amount);
    c.periphery.execute(address(c.book), t);
    vm.stopBroadcast();
    if (c.book.getPosition(0).shares != beforePosition + amount) revert InvalidSeed();
  }

  /// @notice Sell confirmed, caller-owned pending IDs; never import, wrap, or approve IDs through governance.
  /// @dev Each transaction enforces its minOut. Quotes, ownership and generation are recomputed in execution.
  function sellNfts(uint256[] calldata ids, uint256[] calldata minEthOut, uint256 cashFloor) external {
    Context memory c = _context();
    if (ids.length == 0 || ids.length > 8 || ids.length != minEthOut.length) revert InvalidSeed();
    for (uint256 i; i < ids.length; ++i) {
      if (minEthOut[i] == 0) revert InvalidSeed();
      NftTrade memory t = NftTrade(
        c.b,
        c.b,
        0,
        ids[i],
        Side.BUY_BASE,
        AmountMode.EXACT_IN,
        1,
        minEthOut[i],
        block.timestamp + 1 hours,
        c.book.nftParameters(0).version,
        c.book.configVersion(),
        c.book.nftGeneration(0, ids[i])
      );
      uint256 output = c.book.quoteNft(t).traderOut;
      if (output < minEthOut[i]) revert InvalidSeed();
      _cash(c, output, cashFloor);
      vm.startBroadcast(c.bKey);
      IERC721(QUEUE).approve(address(c.periphery), ids[i]);
      c.periphery.executeNft(address(c.book), t);
      vm.stopBroadcast();
      if (IERC721(QUEUE).ownerOf(ids[i]) != c.book.route(0).adapter) revert InvalidSeed();
    }
  }

  /// @notice Reconcile public NAV and republish both cash and base Aqua allocation after inventory acquisition.
  function publish() external {
    Context memory c = _context();
    vm.startBroadcast(c.governorKey);
    c.vault.checkpointValuation();
    c.vault.refreshStrategy(0);
    vm.stopBroadcast();
  }

  function _context() private view returns (Context memory c) {
    if (block.chainid != 560048) revert InvalidSeed();
    c.book = HarborBook(vm.envOr("INVENTORY_BOOK", address(0x5FB29F20ed466840Bd2416F15f7B5312089b8d6E)));
    c.vault = c.book.VAULT();
    c.periphery =
      Periphery(payable(vm.envOr("INVENTORY_PERIPHERY", address(0x7f66f42dff023f5BDb6F12E471F9Ac90c0011FB8))));
    c.governorKey = vm.envUint("HOODI_PRIVATE_KEY");
    c.aKey = vm.envUint("TRADER_A");
    c.bKey = vm.envUint("TRADER_B");
    c.a = vm.addr(c.aKey);
    c.b = vm.addr(c.bKey);
    address lpA = vm.addr(vm.envUint("LP_A"));
    address lpB = vm.addr(vm.envUint("LP_B"));
    address governor = vm.addr(c.governorKey);
    if (
      c.a == c.b || c.a == governor || c.b == governor || c.a == lpA || c.a == lpB || c.b == lpA || c.b == lpB
        || lpA == lpB || c.vault.balanceOf(lpA) == 0 || c.vault.balanceOf(lpB) == 0 || c.book.GOVERNOR() != governor
        || c.book.ASSET() != WETH || c.book.FEE_BPS() != 0 || c.book.route(0).base != WSTETH
        || Queue(QUEUE).WSTETH() != WSTETH || c.periphery.WETH() != WETH
        || address(c.periphery.EXECUTOR()) != address(c.book.EXECUTOR())
        || c.book.EXECUTOR().vaultOf(address(c.book)) != address(c.vault)
    ) revert InvalidSeed();
  }

  /// @dev Testnet zero-fee sizing guard, not an atomic reserve against other transactions during broadcast.
  function _cash(Context memory c, uint256 debit, uint256 floor) private view {
    uint256 cash = c.vault.tradingCash(0);
    if (floor == 0 || cash < floor || debit > cash - floor) revert InvalidSeed();
  }

  /// @dev Explicit native funding or the pinned wstETH receive entrypoint; no arbitrary calldata execution.
  function _send(address recipient, uint256 value) private {
    (bool ok,) = recipient.call{value: value}("");
    if (!ok) revert InvalidSeed();
  }
}
