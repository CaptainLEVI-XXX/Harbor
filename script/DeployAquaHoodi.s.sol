// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Script} from "forge-std/Script.sol";
import {Aqua} from "@1inch/aqua/src/Aqua.sol";
import {AquaSwapVMRouter} from "@1inch/swap-vm/src/routers/AquaSwapVMRouter.sol";
import {IWETH} from "@1inch/solidity-utils/contracts/interfaces/IWETH.sol";

/// @notice Deploy only the pinned upstream Aqua or AquaSwapVMRouter on Hoodi.
/// @dev No Harbor contracts, libraries, tokens, approvals or strategy publication.
/// Run each entrypoint separately; rerunning creates another instance. Review the
/// recorded receipt before retrying any broadcast. Never log the signing key.
contract DeployAquaHoodi is Script {
  error WrongChain();
  error MissingDependency();
  error IncorrectBinding();
  error IncorrectWrapping();

  /// @notice Fork-only wrap/transfer/allowance/unwrap check; never starts broadcast.
  function checkWeth(address wrappedNative) external {
    _hoodi();
    if (wrappedNative.code.length == 0) revert MissingDependency();
    IWETH token = IWETH(wrappedNative);
    address alice = address(0xBEEF);
    address bob = address(0xCAFE);
    uint256 beforeAlice = token.balanceOf(alice);
    uint256 beforeBob = token.balanceOf(bob);
    uint256 backing = wrappedNative.balance;
    vm.deal(alice, 1 ether);
    vm.startPrank(alice);
    token.deposit{value: 1 ether}();
    if (token.balanceOf(alice) != beforeAlice + 1 ether || wrappedNative.balance != backing + 1 ether) {
      revert IncorrectWrapping();
    }
    if (!token.approve(bob, 0.25 ether)) revert IncorrectWrapping();
    vm.stopPrank();
    vm.startPrank(bob);
    if (!token.transferFrom(alice, bob, 0.25 ether)) revert IncorrectWrapping();
    if (token.balanceOf(bob) != beforeBob + 0.25 ether || token.balanceOf(alice) != beforeAlice + 0.75 ether) {
      revert IncorrectWrapping();
    }
    if (!token.transfer(alice, 0.25 ether)) revert IncorrectWrapping();
    vm.stopPrank();
    vm.startPrank(alice);
    token.withdraw(1 ether);
    vm.stopPrank();
    if (
      alice.balance != 1 ether || wrappedNative.balance != backing || token.balanceOf(alice) != beforeAlice
        || token.balanceOf(bob) != beforeBob
    ) revert IncorrectWrapping();
  }

  function runAqua() external returns (Aqua aqua) {
    _hoodi();
    uint256 key = vm.envUint("HOODI_PRIVATE_KEY");
    vm.startBroadcast(key);
    aqua = new Aqua();
    vm.stopBroadcast();
  }

  /// @notice The signer owns the router's upstream rescue permission.
  /// @dev Supplied dependencies require independent code/semantics verification;
  /// code existence and getter agreement alone are not authenticity proofs.
  function runRouter(address aqua, address wrappedNative) external returns (AquaSwapVMRouter router) {
    _hoodi();
    if (aqua.code.length == 0 || wrappedNative.code.length == 0) revert MissingDependency();
    uint256 key = vm.envUint("HOODI_PRIVATE_KEY");
    address owner = vm.addr(key);
    vm.startBroadcast(key);
    router = new AquaSwapVMRouter(aqua, wrappedNative, owner, "Harbor", "2");
    vm.stopBroadcast();
    if (address(router.AQUA()) != aqua || address(router.WETH()) != wrappedNative || router.owner() != owner) {
      revert IncorrectBinding();
    }
  }

  function _hoodi() private view {
    if (block.chainid != 560048) revert WrongChain();
  }
}
