// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {TokenMock} from "@1inch/solidity-utils/contracts/mocks/TokenMock.sol";
import {Operation} from "src/types/HarborTypes.sol";
import {HarborVault} from "src/vault/HarborVault.sol";

/// @notice Test-only coordinator and synthetic mark provider; not a production Book.
contract MockVaultBook {
  function receiptState() external pure returns (bytes32) {
    return bytes32(0);
  }

  function hasManagedPositions() external pure returns (bool) {
    return false;
  }
  HarborVault public immutable VAULT;
  uint256 public inventory;
  uint256 public claims;
  uint256 public observedAt;
  bool public valid = true;
  bool public failFinish;
  bytes32 private transient context;

  constructor(address weth) {
    VAULT = new HarborVault(weth, address(this), 60, 1e12, 1e6);
  }

  function setMark(uint256 w, uint256 p, uint256 t, bool v) external {
    inventory = w;
    claims = p;
    observedAt = t;
    valid = v;
  }

  function setFailFinish(bool fail) external {
    failFinish = fail;
  }

  function valuation() external view returns (uint256, uint256, uint256, bytes32, bool) {
    return (inventory, claims, observedAt, keccak256(abi.encode(inventory, claims, observedAt)), valid);
  }

  function beginVaultOperation(bytes32 c) external {
    require(msg.sender == address(VAULT) && context == 0, "book lock");
    context = c;
    VAULT.beginBookOperation(c, Operation.VAULT);
  }

  function finishVaultOperation(bytes32 c) external {
    require(!failFinish && msg.sender == address(VAULT) && context == c, "book finish");
    VAULT.finishBookOperation(c);
    context = 0;
  }
}

abstract contract VaultFixture is Test {
  TokenMock internal weth;
  MockVaultBook internal book;
  HarborVault internal vault;
  address internal alice = address(0xa11ce);
  address internal bob = address(0xb0b);
  address internal operator = address(0xcafe);

  function setUp() public virtual {
    vm.warp(1000);
    weth = new TokenMock("Synthetic ASSET", "ASSET");
    book = new MockVaultBook(address(weth));
    vault = book.VAULT();
    book.setMark(0, 0, 1000, true);
    vault.checkpointValuation();
    weth.mint(alice, 100 ether);
    weth.mint(bob, 100 ether);
    vm.prank(alice);
    weth.approve(address(vault), type(uint256).max);
    vm.prank(bob);
    weth.approve(address(vault), type(uint256).max);
  }

  function _deposit(address user, uint256 amount) internal returns (uint256 shares) {
    vm.prank(user);
    return vault.deposit(amount, user);
  }

  function _request(address user, uint256 shares) internal {
    vm.prank(user);
    assertEq(vault.requestRedeem(shares, user, user), 0);
  }
}
