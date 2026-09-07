// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {ERC20} from "solady/tokens/ERC20.sol";
import {HarborVault} from "src/vault/HarborVault.sol";
import {MockVaultBook} from "test/helpers/VaultFixture.sol";

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
      require(!success && bytes4(result) == HarborVault.Busy.selector, "reentry not blocked");
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

  function test_ExplicitContextSurvivesBeginReturnAndRejectsWrongFinish() public {
    vm.prank(address(book));
    vault.beginBookOperation(bytes32(uint256(1)));
    vm.expectRevert(HarborVault.Busy.selector);
    vault.deposit(1 ether, address(this));
    vm.expectRevert(HarborVault.InvalidContext.selector);
    vm.prank(address(book));
    vault.finishBookOperation(bytes32(uint256(2)));
    vm.prank(address(book));
    vault.finishBookOperation(bytes32(uint256(1)));
    vault.deposit(1 ether, address(this));
  }

  function test_OnlyImmutableBookCanAcquireOrRelease() public {
    vm.expectRevert(HarborVault.Unauthorized.selector);
    vault.beginBookOperation(bytes32(uint256(1)));
    vm.expectRevert(HarborVault.Unauthorized.selector);
    vault.finishBookOperation(bytes32(uint256(1)));
  }

  function test_TransientInstructionsExecuteOnLocalAndMainnetChainIds() public {
    _trace(31337);
    _trace(1);
  }

  function _trace(uint256 chain) private {
    vm.chainId(chain);
    vm.startDebugTraceRecording();
    vault.deposit(1 ether, address(this));
    Vm.DebugStep[] memory steps = vm.stopAndReturnDebugTraceRecording();
    bool read;
    bool write;
    for (uint256 i; i < steps.length; ++i) {
      if (steps[i].contractAddr != address(vault)) continue;
      if (steps[i].opcode == 0x5c) read = true;
      if (steps[i].opcode == 0x5d) write = true;
    }
    assertTrue(read, "missing TLOAD");
    assertTrue(write, "missing TSTORE");
  }
}
