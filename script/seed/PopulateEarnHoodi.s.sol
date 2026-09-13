// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {SeedInventoryHoodi} from "script/seed/SeedInventoryHoodi.s.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {ILidoWithdrawalQueue as Queue, ILidoCheckpoints} from "src/interfaces/ILidoWithdrawalQueue.sol";
import {IHarborAdapter} from "src/interfaces/IHarborAdapter.sol";
import {Trade, Side, AmountMode, FillAmounts, RedeemIntent} from "src/types/HarborTypes.sol";
import {NftTrade} from "src/types/NftTypes.sol";
import {console2} from "forge-std/console2.sol";

/// @notice Explicit stages for real, labeled Hoodi demo activity against the indexed pool.
/// @dev Run one signature at a time. This is a Foundry script, not a deployed helper.
/// Reuses fund/stake/requestNfts/sellToken/sellNfts/publish from the adjacent inventory script.
/// Script-side checks only protect simulation; encoded limits and Harbor protect mined trades.
/// No fabricated history, automatic pricing changes, wallet generation or balance sweeps.
contract PopulateEarnHoodi is SeedInventoryHoodi {
  /// @notice Top up one existing LP/trader to a chosen native balance, without depositing it.
  /// @dev Native transfer to the derived, configured account only; failure aborts this stage.
  function topUp(bool lp, bool first, uint256 targetBalance) external {
    Context memory c = _context();
    address recipient = vm.addr(_key(c, lp, first));
    if (targetBalance == 0 || recipient == vm.addr(c.governorKey)) revert InvalidSeed();
    if (recipient.balance >= targetBalance) return;
    uint256 amount = targetBalance - recipient.balance;
    if (vm.addr(c.governorKey).balance <= amount) revert InvalidSeed();
    vm.startBroadcast(c.governorKey);
    (bool ok,) = recipient.call{value: amount}("");
    require(ok, "Native funding failed");
    vm.stopBroadcast();
  }

  /// @notice Deposit an explicit LP amount through native Periphery; never count deposits as profit.
  function depositLp(bool first, uint256 ethWei, uint256 minShares) external {
    Context memory c = _context();
    uint256 key = _key(c, true, first);
    if (ethWei == 0 || minShares == 0 || vm.addr(key).balance <= ethWei) revert InvalidSeed();
    vm.startBroadcast(key);
    c.periphery.deposit{value: ethWei}(address(c.book), minShares);
    vm.stopBroadcast();
  }

  /// @notice All four ordinary modes. sell is from the trader's perspective; amounts are raw units.
  /// @param limit Minimum output (exact input) or maximum input (exact output), encoded onchain.
  /// @param cashFloor Simulation-only minimum remaining spendable pool WETH after a sale.
  /// @param inventoryFloor Simulation-only minimum remaining wstETH after a purchase.
  function tradeToken(
    bool first,
    bool sell,
    bool exactIn,
    uint256 amount,
    uint256 limit,
    uint256 cashFloor,
    uint256 inventoryFloor
  ) external {
    Context memory c = _context();
    uint256 key = _key(c, false, first);
    address user = vm.addr(key);
    if (amount == 0 || limit == 0 || cashFloor == 0 || inventoryFloor == 0) revert InvalidSeed();
    Trade memory t = Trade(
      address(c.periphery),
      user,
      sell ? WSTETH : WETH,
      sell ? WETH : WSTETH,
      0,
      sell ? Side.BUY_BASE : Side.SELL_BASE,
      exactIn ? AmountMode.EXACT_IN : AmountMode.EXACT_OUT,
      amount,
      limit,
      block.timestamp + 5 minutes,
      c.book.pricingParameters(0).version,
      c.book.configVersion(),
      c.book.strategyVersion(0)
    );
    (uint256 input, uint256 output,) = c.book.EXECUTOR().quoteSwap(address(c.book), t);
    uint256 budget = exactIn ? amount : limit;
    if (sell) {
      _cashFloor(c, output, cashFloor);
    } else {
      uint256 inventory = c.book.getPosition(0).shares;
      if (inventory < inventoryFloor || output > inventory - inventoryFloor || user.balance <= budget) {
        revert InvalidSeed();
      }
    }
    console2.log("Token input / output", input, output);
    vm.startBroadcast(key);
    if (sell) IERC20(WSTETH).approve(address(c.periphery), budget);
    c.periphery.execute{value: sell ? 0 : budget}(address(c.book), t);
    vm.stopBroadcast();
  }

  /// @notice Whole-ID quote in the canonical mode: sell exact NFT input / buy exact NFT output.
  function quoteNft(bool first, bool sell, uint256 id) external view returns (FillAmounts memory) {
    Context memory c = _context();
    return c.book.quoteNft(_nft(c, vm.addr(_key(c, false, first)), sell, id));
  }

  /// @notice All four NFT modes; never round a fractional NFT or predict a newly minted ID.
  /// @param cashLimit Positive min ETH received for a sale, max ETH paid for a purchase.
  /// @dev Cash-exact modes use the canonical one-NFT quote as the exact amount. A price move
  /// may revert rather than partially fill; cashLimit remains independently enforced.
  function tradeNft(bool first, bool sell, bool exactIn, uint256 id, uint256 cashLimit, uint256 cashFloor) external {
    Context memory c = _context();
    uint256 key = _key(c, false, first);
    address user = vm.addr(key);
    if (cashLimit == 0 || cashFloor == 0) revert InvalidSeed();
    NftTrade memory t = _nft(c, user, sell, id);
    FillAmounts memory a = c.book.quoteNft(t);
    if (sell) {
      if (a.traderOut < cashLimit) revert InvalidSeed();
      _cashFloor(c, a.traderOut, cashFloor);
      t.amountSpecified = exactIn ? 1 : a.traderOut;
      t.limitAmount = exactIn ? cashLimit : 1;
    } else {
      if (a.traderIn > cashLimit || user.balance <= cashLimit) revert InvalidSeed();
      t.amountSpecified = exactIn ? a.traderIn : 1;
      t.limitAmount = exactIn ? 1 : cashLimit;
    }
    t.mode = exactIn ? AmountMode.EXACT_IN : AmountMode.EXACT_OUT;
    c.book.quoteNft(t); // Validate the selected mode, not just the canonical observation.
    console2.log("NFT input / output", a.traderIn, a.traderOut);
    vm.startBroadcast(key);
    if (sell) IERC721(QUEUE).approve(address(c.periphery), id);
    c.periphery.executeNft{value: sell ? 0 : exactIn ? a.traderIn : cashLimit}(address(c.book), t);
    vm.stopBroadcast();
  }

  /// @notice Queue a partial LP exit only; retain both seeded LPs for subsequent demo stages.
  /// @dev Existing pending requests must be reconciled, not repeated by rerunning this stage.
  function requestExit(bool first, uint256 shares) external {
    Context memory c = _context();
    uint256 key = _key(c, true, first);
    address user = vm.addr(key);
    if (shares == 0 || shares >= c.vault.balanceOf(user) || c.vault.pendingRedeemRequest(0, user) != 0) {
      revert InvalidSeed();
    }
    vm.startBroadcast(key);
    c.vault.requestRedeem(shares, user, user);
    vm.stopBroadcast();
  }

  /// @notice Permissionless FIFO funding. Does not choose a beneficiary or claim anyone's cash.
  function fundExits() external {
    Context memory c = _context();
    vm.startBroadcast(c.governorKey);
    c.vault.fulfillWithdrawals(8);
    vm.stopBroadcast();
  }

  /// @notice Claim an explicit funded WETH amount as native ETH, separately from request/funding.
  /// @dev Grant Periphery operator permission only if needed. The user can revoke it in the Vault.
  function claimExit(bool first, uint256 assets) external {
    Context memory c = _context();
    uint256 key = _key(c, true, first);
    address user = vm.addr(key);
    if (assets == 0 || assets > c.vault.maxWithdraw(user)) revert InvalidSeed();
    vm.startBroadcast(key);
    if (!c.vault.isOperator(user, address(c.periphery))) c.vault.setOperator(address(c.periphery), true);
    c.periphery.withdraw(address(c.book), assets);
    vm.stopBroadcast();
  }

  /// @notice Observe backing after each session. No new price, expiry extension or fake NAV.
  function checkpoint() external {
    Context memory c = _context();
    vm.startBroadcast(c.governorKey);
    c.vault.checkpointValuation();
    vm.stopBroadcast();
  }

  /// @notice Keeper converts an explicit inventory lot into one native issuer claim.
  /// @param nonce Operator-chosen unused redemption nonce; reuse reverts onchain.
  /// @dev Pending claims are not cash. Use mined RedemptionRequested IDs in later recovery stages.
  function requestIssuer(uint256 shares, uint256 minUnderlying, uint256 nonce, uint256 inventoryFloor) external {
    Context memory c = _context();
    if (c.book.KEEPER() != vm.addr(c.governorKey) || shares == 0 || minUnderlying == 0 || inventoryFloor == 0) {
      revert InvalidSeed();
    }
    uint256 inventory = c.book.getPosition(0).shares;
    if (inventory < inventoryFloor || shares > inventory - inventoryFloor) revert InvalidSeed();
    uint256[] memory amounts = new uint256[](1);
    amounts[0] = shares;
    RedeemIntent memory intent = RedeemIntent(
      block.chainid,
      address(c.vault),
      address(c.book),
      0,
      c.book.route(0).adapter,
      1,
      shares,
      minUnderlying,
      1,
      c.book.getPosition(0).version,
      c.book.redemptionEpoch(),
      nonce,
      block.timestamp + 5 minutes,
      keccak256(abi.encode(amounts))
    );
    vm.startBroadcast(c.governorKey);
    IHarborAdapter.Request[] memory requests = c.book.requestRedemption(intent, amounts);
    vm.stopBroadcast();
    console2.log("Predicted issuer ID; use mined logs", requests[0].id);
  }

  /// @notice Recover 1..8 sorted finalized, vault-owned IDs. Works for native and raw-NFT holdings.
  /// @dev Hints come from Lido. Pending IDs fail before broadcast; nobody can accelerate finalization.
  function recoverIssuer(uint256[] calldata ids) external {
    Context memory c = _context();
    if (ids.length == 0 || ids.length > 8) revert InvalidSeed();
    Queue.WithdrawalRequestStatus[] memory states = Queue(QUEUE).getWithdrawalStatus(ids);
    for (uint256 i; i < ids.length; ++i) {
      if (
        (i != 0 && ids[i] <= ids[i - 1]) || !states[i].isFinalized || states[i].isClaimed
          || states[i].owner != c.book.route(0).adapter
      ) revert InvalidSeed();
    }
    ILidoCheckpoints queue = ILidoCheckpoints(QUEUE);
    uint256[] memory hints = queue.findCheckpointHints(ids, 1, queue.getLastCheckpointIndex());
    vm.startBroadcast(c.governorKey);
    c.book.claimRedemptions(0, ids, hints);
    vm.stopBroadcast();
  }

  function _nft(Context memory c, address user, bool sell, uint256 id) private view returns (NftTrade memory) {
    return NftTrade(
      user,
      user,
      0,
      id,
      sell ? Side.BUY_BASE : Side.SELL_BASE,
      sell ? AmountMode.EXACT_IN : AmountMode.EXACT_OUT,
      1,
      sell ? 0 : type(uint256).max,
      block.timestamp + 5 minutes,
      c.book.nftParameters(0).version,
      c.book.configVersion(),
      c.book.nftGeneration(0, id)
    );
  }

  function _key(Context memory c, bool lp, bool first) private view returns (uint256) {
    return lp ? vm.envUint(first ? "LP_A" : "LP_B") : first ? c.aKey : c.bKey;
  }

  /// @dev Existing context pins zero protocol fees. This is not an atomic reservation against competitors.
  function _cashFloor(Context memory c, uint256 debit, uint256 floor) private view {
    uint256 available = c.vault.tradingCash(0);
    if (available < floor || debit > available - floor) revert InvalidSeed();
  }
}
