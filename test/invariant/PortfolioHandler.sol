// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ISwapVM} from "@1inch/swap-vm/src/interfaces/ISwapVM.sol";
import {HarborBook} from "src/book/HarborBook.sol";
import {HarborVault} from "src/vault/HarborVault.sol";
import {HarborExecutor} from "src/execution/HarborExecutor.sol";
import {Trade, FillTerms, Side, AmountMode} from "src/types/HarborTypes.sol";
import {MockLidoQueue} from "test/helpers/LidoFixture.sol";
import {RealizationLogs} from "test/helpers/RealizationLogs.sol";

interface IPortfolioRelay {
  function prepareQuote(uint256 route, Side side, AmountMode mode, uint256 quantity)
    external
    returns (Trade memory, FillTerms memory, bytes memory, ISwapVM.Order memory);
  function requestIssuer(uint256 amount) external returns (uint256 id);
  function refresh(uint256 route) external;
}

/// @notice Independent bounded ghost accounting across real contract operations.
/// @dev Small quantities permit direct multiply/divide reference arithmetic without
/// full-width overflow. Expected state never comes from Book/Vault post-operation state.
contract PortfolioHandler is Test {
  struct Ticket {
    uint256 actor;
    uint256 shares;
  }

  struct Credit {
    uint256 units;
    uint256 assets;
  }

  struct Claim {
    uint256 id;
    uint256 basis;
    uint256 remaining;
  }

  IPortfolioRelay public immutable RELAY;
  HarborBook public immutable BOOK;
  HarborVault public immutable VAULT;
  HarborExecutor public immutable EXECUTOR;
  MockLidoQueue public immutable QUEUE;
  IERC20 public immutable WETH;
  address public immutable TRADER;
  IERC20[2] public bases;
  address[3] public actors;
  uint256 public cash;
  uint256 public supply;
  uint256 public reserved;
  uint256 public pending;
  uint256 public wethSurplus;
  uint256[2] public baseSurplus;
  uint256[2] public warehouse;
  uint256[2] public basis;
  uint256[2] public purchases;
  uint256[2] public gains;
  uint256[2] public eventGains;
  uint256[2] public losses;
  uint256 public pendingBasis;
  uint256[3] public balances;
  uint256[3] public pendingByActor;
  Credit[3] public credits;
  Ticket[] public tickets;
  Claim[] public claims;
  uint256 public head;
  uint256[4] public modeSuccesses;
  uint256 public successes;
  uint256 public bootstrapSuccesses;
  uint256 public issuerRequests;
  uint256 public issuerRecoveries;

  constructor(
    HarborBook book,
    HarborVault vault,
    HarborExecutor executor,
    MockLidoQueue queue,
    address trader,
    address[3] memory lps
  ) {
    RELAY = IPortfolioRelay(msg.sender);
    BOOK = book;
    VAULT = vault;
    EXECUTOR = executor;
    QUEUE = queue;
    WETH = IERC20(book.WETH());
    TRADER = trader;
    actors = lps;
    for (uint256 i; i < 2; ++i) {
      bases[i] = IERC20(book.route(i).base);
    }
    // Fixture starts with exactly two 10-WETH deposits, at the virtual-share rate.
    cash = 20 ether;
    supply = 20 ether * 1e6;
    balances[0] = balances[1] = 10 ether * 1e6;
  }

  function finishBootstrap() external {
    require(msg.sender == address(RELAY));
    bootstrapSuccesses = successes;
  }

  function nav() public view returns (uint256 value) {
    value = cash + warehouse[0] + warehouse[1]; // Synthetic inventory marks are 1:1.
    for (uint256 i; i < claims.length; ++i) {
      value += claims[i].remaining;
    }
    value = value > reserved ? value - reserved : 0;
  }

  function deposit(uint8 who, uint64 seed) external {
    uint256 actor = who % 3;
    uint256 amount = bound(seed, 1, 10000) * 1e14;
    if (amount > WETH.balanceOf(actors[actor]) || amount > VAULT.maxDeposit(actors[actor])) return;
    uint256 expected = amount * (supply + 1e6) / (nav() + 1);
    if (expected == 0) return;
    vm.prank(actors[actor]);
    uint256 minted = VAULT.deposit(amount, actors[actor]);
    assertEq(minted, expected);
    cash += amount;
    supply += expected;
    balances[actor] += expected;
    ++successes;
  }

  function transferShares(uint8 from, uint8 to, uint64 seed) external {
    uint256 a = from % 3;
    uint256 b = to % 3;
    if (a == b || balances[a] == 0) return;
    uint256 quantity = bound(seed, 1, balances[a]);
    vm.prank(actors[a]);
    VAULT.transfer(actors[b], quantity);
    balances[a] -= quantity;
    balances[b] += quantity;
    ++successes;
  }

  function requestExit(uint8 who, uint64 seed) external {
    uint256 a = who % 3;
    if (balances[a] == 0) return;
    // Fractional full-width LP units; avoid generating only sub-minimum dust.
    uint256 quantity = balances[a] / bound(seed, 1, 8);
    if (quantity < 1e6 && quantity != balances[a]) return;
    if (quantity == 0) return;
    vm.prank(actors[a]);
    VAULT.requestRedeem(quantity, actors[a], actors[a]);
    tickets.push(Ticket(a, quantity));
    balances[a] -= quantity;
    pending += quantity;
    pendingByActor[a] += quantity;
    ++successes;
  }

  function fulfill() external {
    if (head == tickets.length) return;
    Ticket storage t = tickets[head];
    uint256 n = nav();
    uint256 numerator = n == 0 ? 0 : n + 1;
    uint256 denominator = supply + 1e6;
    uint256 free = cash - reserved;
    // Independent binary-search reference, not WithdrawalQueue's inverse formula.
    uint256 low;
    uint256 high = t.shares + 1;
    while (high - low > 1) {
      uint256 middle = (low + high) / 2;
      if (middle * numerator / denominator <= free) low = middle;
      else high = middle;
    }
    uint256 assets = low * numerator / denominator;
    if (numerator != 0 && assets == 0) low = 0;
    VAULT.fulfillWithdrawals(1);
    if (low == 0) return;
    t.shares -= low;
    pending -= low;
    pendingByActor[t.actor] -= low;
    supply -= low;
    reserved += assets;
    credits[t.actor].units += low;
    credits[t.actor].assets += assets;
    if (t.shares == 0) ++head;
    ++successes;
  }

  function claimExit(uint8 who) external {
    uint256 a = who % 3;
    Credit memory c = credits[a];
    if (c.units == 0) return;
    uint256 beforeBalance = WETH.balanceOf(actors[a]);
    vm.prank(actors[a]);
    uint256 received = VAULT.redeem(c.units, actors[a], actors[a]);
    assertEq(received, c.assets);
    assertEq(WETH.balanceOf(actors[a]), beforeBalance + c.assets);
    cash -= c.assets;
    reserved -= c.assets;
    delete credits[a];
    ++successes;
  }

  function trade(uint8 whichRoute, bool buy, bool exactIn, uint64 seed) external {
    uint256 route = whichRoute % 2;
    uint256 quantity = bound(seed, 1, 10000) * 1e14;
    if (buy && (pending != 0 || quantity > cash - reserved || losses[route] >= 10 ether)) return;
    if (!buy && quantity > warehouse[route]) return;
    (Trade memory t, FillTerms memory f, bytes memory sig, ISwapVM.Order memory order) = RELAY.prepareQuote(
      route, buy ? Side.BUY_BASE : Side.SELL_BASE, exactIn ? AmountMode.EXACT_IN : AmountMode.EXACT_OUT, quantity
    );
    // Stale Aqua allocation is expected after non-trade cash/inventory changes.
    try EXECUTOR.quoteFill(t, f, sig, order) {}
    catch {
      return;
    }
    vm.recordLogs();
    vm.prank(TRADER);
    EXECUTOR.execute(t, f, sig, order);
    (uint256 realized,, uint256 count) = RealizationLogs.totals(vm.getRecordedLogs(), address(BOOK), route);
    assertEq(count, buy ? 0 : 1);
    eventGains[route] += realized;
    if (buy) {
      warehouse[route] += quantity;
      basis[route] += f.routerOut;
      purchases[route] += f.routerOut;
      cash -= f.routerOut;
    } else {
      uint256 removed = quantity == warehouse[route] ? basis[route] : basis[route] * quantity / warehouse[route];
      warehouse[route] -= quantity;
      basis[route] -= removed;
      cash += f.routerIn;
      if (f.routerIn >= removed) gains[route] += f.routerIn - removed;
      else losses[route] += removed - f.routerIn;
    }
    VAULT.checkpointValuation();
    ++modeSuccesses[(buy ? 0 : 2) + (exactIn ? 0 : 1)];
    ++successes;
  }

  function requestIssuer(uint64 seed) external {
    uint256 quantity = bound(seed, 1, 10000) * 1e14;
    if (quantity > warehouse[0]) return;
    uint256 removed = quantity == warehouse[0] ? basis[0] : basis[0] * quantity / warehouse[0];
    uint256 id = RELAY.requestIssuer(quantity);
    warehouse[0] -= quantity;
    basis[0] -= removed;
    pendingBasis += removed;
    claims.push(Claim(id, removed, quantity * 12 / 10));
    VAULT.checkpointValuation();
    ++issuerRequests;
    ++successes;
  }

  function recoverIssuer(uint8 which, uint16 recoveryBps) external {
    if (claims.length == 0) return;
    Claim storage c = claims[which % claims.length];
    if (c.remaining == 0) return;
    uint256 payment = c.remaining * bound(recoveryBps, 0, 10000) / 10000;
    QUEUE.setFinalized(c.id, payment); // Explicitly synthetic finalization and loss.
    uint256[] memory ids = new uint256[](1);
    uint256[] memory hints = new uint256[](1);
    ids[0] = c.id;
    hints[0] = 1;
    vm.recordLogs();
    BOOK.claimRedemptions(0, ids, hints);
    (uint256 realized,, uint256 count) = RealizationLogs.totals(vm.getRecordedLogs(), address(BOOK), 0);
    assertEq(count, 1);
    eventGains[0] += realized;
    cash += payment;
    pendingBasis -= c.basis;
    if (payment >= c.basis) gains[0] += payment - c.basis;
    else losses[0] += c.basis - payment;
    c.remaining = 0;
    VAULT.checkpointValuation();
    ++issuerRecoveries;
    ++successes;
  }

  function donate(uint8 token, uint64 seed) external {
    uint256 amount = bound(seed, 1, 1000) * 1e12;
    uint256 selected = token % 3;
    IERC20 asset = selected == 2 ? WETH : bases[selected];
    if (asset.balanceOf(TRADER) < amount) return;
    vm.prank(TRADER);
    asset.transfer(address(VAULT), amount);
    if (selected == 2) wethSurplus += amount;
    else baseSurplus[selected] += amount;
    ++successes;
  }

  function refresh(uint8 route) external {
    RELAY.refresh(route % 2);
  }

  function claimCount() external view returns (uint256) {
    return claims.length;
  }
}
