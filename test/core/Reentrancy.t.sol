// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {IssuerFixture} from "test/base/IssuerFixture.sol";
import {TokenMock} from "@1inch/solidity-utils/contracts/mocks/TokenMock.sol";
import {ISwapVM} from "@1inch/swap-vm/src/interfaces/ISwapVM.sol";
import {HarborVault} from "src/vault/HarborVault.sol";
import {HarborBook} from "src/book/HarborBook.sol";
import {HarborExecutor} from "src/execution/HarborExecutor.sol";
import {Trade, FillTerms, Side, AmountMode} from "src/types/HarborTypes.sol";
import {TradingFixture} from "test/base/TradingFixture.sol";
import {VaultState} from "src/vault/base/VaultState.sol";
import {Test} from "forge-std/Test.sol";
import {ERC20} from "solady/tokens/ERC20.sol";
import {MockVaultBook} from "test/base/VaultFixture.sol";

contract IssuerReentrancyTest is IssuerFixture {
  uint256 private checks;
  uint256 private navBefore;
  uint256 private supplyBefore;

  function test_IssuerCallbackCannotCrossBookOrVaultDomains() public {
    _buy(0, 1 ether);
    uint256 id = _request(1 ether);
    vault.checkpointValuation();
    navBefore = vault.totalAssets();
    supplyBefore = vault.totalSupply();
    queue.setFinalized(id, 1.2 ether);
    queue.setCallback(address(this));
    _claim(id);
    assertEq(checks, 6);
    assertTrue(queue.callbackSucceeded()); // Probe returned normally; nested calls failed.
    assertTrue(book.getClaim(address(adapter), id).closed);
  }

  function reenter() external {
    assertEq(vault.totalAssets(), navBefore);
    assertEq(vault.totalSupply(), supplyBefore);
    assertEq(vault.maxDeposit(alice), 0);
    bytes[] memory calls = new bytes[](4);
    calls[0] = abi.encodeCall(vault.checkpointValuation, ());
    calls[1] = abi.encodeWithSignature("deposit(uint256,address)", 1 ether, alice);
    calls[2] = abi.encodeCall(vault.fulfillWithdrawals, (1));
    calls[3] = abi.encodeWithSignature("transfer(address,uint256)", alice, 0);
    for (uint256 i; i < calls.length; ++i) {
      (bool entered,) = address(vault).call(calls[i]);
      assertFalse(entered);
      ++checks;
    }
    (bool ok,) = address(book).call(abi.encodeCall(book.stopTrading, ()));
    assertFalse(ok);
    ++checks;
    (ok,) = address(book).call(abi.encodeCall(book.revokeKeeper, ()));
    assertFalse(ok);
    ++checks;
  }
}

/// @notice Deliberately adversarial test token, not production WETH behavior.
contract TradingCallbackToken is TokenMock {
  HarborVault private vault;
  HarborBook private book;
  address private executor;
  bytes private executeData;
  uint256 private nav;
  uint256 private supply;
  uint256 public rejected;
  constructor() TokenMock("Adversarial WETH", "BADWETH") {}

  function arm(HarborVault v, HarborBook b, address e, bytes calldata data) external onlyOwner {
    vault = v;
    book = b;
    executor = e;
    executeData = data;
    nav = v.totalAssets();
    supply = v.totalSupply();
  }

  function _update(address from, address to, uint256 amount) internal override {
    super._update(from, to, amount);
    if (executor == address(0)) return;
    _reject(address(vault), abi.encodeWithSignature("deposit(uint256,address)", 1, address(this)));
    _reject(address(vault), abi.encodeWithSignature("transfer(address,uint256)", address(1), 0));
    _reject(
      address(vault), abi.encodeWithSignature("requestRedeem(uint256,address,address)", 1, address(this), address(this))
    );
    _reject(address(vault), abi.encodeWithSignature("fulfillWithdrawals(uint256)", 1));
    _reject(address(vault), abi.encodeWithSignature("checkpointValuation()"));
    _reject(address(book), abi.encodeWithSignature("beginTrade(bytes32)", bytes32(uint256(1))));
    _reject(executor, executeData);
    require(vault.totalAssets() == nav && vault.totalSupply() == supply, "incoherent trade snapshot");
  }

  function _reject(address target, bytes memory data) private {
    (bool ok,) = target.call(data);
    require(!ok, "cross-domain reentry succeeded");
    ++rejected;
  }
}

/// @title TradingReentrancyTest
/// @notice Guards remain active through router output, fee and final trader payout.
contract TradingReentrancyTest is TradingFixture {
  function _deployWeth() internal override returns (TokenMock) {
    return new TradingCallbackToken();
  }

  function test_RouterFeeAndTraderCallbacksRemainLocked() public {
    (Trade memory t, FillTerms memory f, bytes memory sig, ISwapVM.Order memory order) =
      _quote(0, Side.BUY_BASE, AmountMode.EXACT_IN, 1 ether);
    TradingCallbackToken(address(weth))
      .arm(vault, book, address(executor), abi.encodeCall(executor.execute, (t, f, sig, order)));
    vm.prank(trader);
    executor.execute(t, f, sig, order);
    assertEq(TradingCallbackToken(address(weth)).rejected(), 21);
    vault.checkpointValuation();
    assertEq(vault.totalAssets(), 20.01 ether);
  }
}

/// @notice Deliberately adversarial token; not an approved production WETH.
contract CallbackAsset is ERC20 {
  HarborVault private target;
  bool private armed;
  uint256 private expectedNAV;
  uint256 private expectedSupply;
  uint256 public rejected;

  function name() public pure override returns (string memory) {
    return "Callback asset";
  }

  function symbol() public pure override returns (string memory) {
    return "CB";
  }

  function mint(address to, uint256 amount) external {
    _mint(to, amount);
  }

  function arm(HarborVault vault) external {
    target = vault;
    expectedNAV = vault.totalAssets();
    expectedSupply = vault.totalSupply();
    armed = true;
  }

  function _afterTokenTransfer(address, address, uint256) internal override {
    if (!armed) return;
    bytes[] memory attacks = new bytes[](8);
    attacks[0] = abi.encodeWithSignature("deposit(uint256,address)", 1, address(this));
    attacks[1] = abi.encodeWithSignature("mint(uint256,address)", 1, address(this));
    attacks[2] = abi.encodeWithSignature("transfer(address,uint256)", address(1), 0);
    attacks[3] = abi.encodeWithSignature("requestRedeem(uint256,address,address)", 1, address(this), address(this));
    attacks[4] = abi.encodeWithSignature("fulfillWithdrawals(uint256)", 1);
    attacks[5] = abi.encodeWithSignature("redeem(uint256,address,address)", 1, address(this), address(this));
    attacks[6] = abi.encodeWithSignature("checkpointValuation()");
    attacks[7] = abi.encodeWithSignature("setOperator(address,bool)", address(1), true);
    for (uint256 i; i < attacks.length; ++i) {
      (bool success, bytes memory result) = address(target).call(attacks[i]);
      require(!success && bytes4(result) == VaultState.Busy.selector, "reentry not blocked");
      ++rejected;
    }
    require(target.totalAssets() == expectedNAV && target.totalSupply() == expectedSupply, "incoherent snapshot");
    require(target.convertToAssets(1e6) == (expectedNAV + 1) * 1e6 / (expectedSupply + 1e6), "incoherent conversion");
  }
}

/// @title VaultReentrancyTest
/// @notice Shared locks survive begin callbacks; transfer callbacks see coherent views.
contract VaultReentrancyTest is Test {
  CallbackAsset internal token;
  MockVaultBook internal book;
  HarborVault internal vault;

  function setUp() public {
    vm.warp(1000);
    token = new CallbackAsset();
    book = new MockVaultBook(address(token));
    vault = book.VAULT();
    book.setMark(0, 0, 1000, true);
    vault.checkpointValuation();
    token.mint(address(this), 10 ether);
    token.approve(address(vault), 10 ether);
  }

  function test_InputAndClaimCallbacksCannotEnterAnyLPFlow() public {
    token.arm(vault);
    uint256 shares = vault.deposit(10 ether, address(this));
    assertEq(token.rejected(), 8);
    vault.requestRedeem(shares, address(this), address(this));
    vault.fulfillWithdrawals(1);
    token.arm(vault);
    vault.redeem(shares, address(this), address(this));
    assertEq(token.rejected(), 16);
  }
}
