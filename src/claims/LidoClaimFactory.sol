// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {ReentrancyGuardTransient} from "solady/utils/ReentrancyGuardTransient.sol";
import {LidoClaimReceipt} from "src/claims/LidoClaimReceipt.sol";
import {IHarborClaimFactory} from "src/interfaces/IHarborClaim.sol";
import {LibClone} from "solady/utils/LibClone.sol";

/// @title LidoClaimFactory
/// @notice Canonical imports for one immutable issuer and recovery token.
/// @dev A market must independently admit this factory. Retirement is irreversible
/// and affects new exposure only; receipts never consult it to recover or redeem.
contract LidoClaimFactory is IHarborClaimFactory, ReentrancyGuardTransient {
  address public immutable ISSUER;
  address public immutable WETH;
  address public immutable GOVERNOR;
  /// @notice Fixed receipt logic. Clones have no upgrade/admin selector or implementation setter.
  address public immutable IMPLEMENTATION;
  bool public active = true;
  uint256 public version = 1;
  mapping(uint256 => address) public receiptOf;
  mapping(address => bool) public isReceipt;

  error InvalidConfiguration();
  error Unauthorized();
  error InvalidImport();
  error UnsupportedOperation();

  event ClaimWrapped(uint256 indexed requestId, address indexed receipt, address indexed owner);
  event Retired(uint256 version);

  constructor(address issuer, address weth, address governor) {
    if (issuer.code.length == 0 || weth.code.length == 0 || issuer == weth || governor == address(0)) {
      revert InvalidConfiguration();
    }
    ISSUER = issuer;
    WETH = weth;
    GOVERNOR = governor;
    IMPLEMENTATION = address(new LidoClaimReceipt(issuer, weth));
  }

  /// @inheritdoc IHarborClaimFactory
  function wrap(uint256 id) external nonReentrant returns (address receipt) {
    if (!active || id == 0 || receiptOf[id] != address(0) || IERC721(ISSUER).ownerOf(id) != msg.sender) {
      revert InvalidImport();
    }
    receipt = LibClone.cloneDeterministic(IMPLEMENTATION, bytes32(id));
    LidoClaimReceipt created = LidoClaimReceipt(payable(receipt));
    created.initialize(id, msg.sender);
    receiptOf[id] = receipt;
    isReceipt[receipt] = true;
    IERC721(ISSUER).safeTransferFrom(msg.sender, receipt, id);
    created.activate();
    emit ClaimWrapped(id, receipt, msg.sender);
  }

  /// @inheritdoc IHarborClaimFactory
  function originate(uint256) external pure returns (address) {
    revert UnsupportedOperation();
  }

  /// @notice Stop new imports and advance the version without touching existing custody.
  function retire() external {
    if (msg.sender != GOVERNOR) revert Unauthorized();
    if (!active) revert InvalidImport();
    active = false;
    ++version;
    emit Retired(version);
  }

  function _useTransientReentrancyGuardOnlyOnMainnet() internal pure override returns (bool) {
    return false;
  }
}
