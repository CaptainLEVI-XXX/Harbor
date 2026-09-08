// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {ERC20} from "solady/tokens/ERC20.sol";
import {ReentrancyGuardTransient} from "solady/utils/ReentrancyGuardTransient.sol";
import {SafeTransferLib as SafeTransfer} from "solady/utils/SafeTransferLib.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {IWETH} from "@1inch/solidity-utils/contracts/interfaces/IWETH.sol";
import {ILidoWithdrawalQueue as Queue} from "src/interfaces/ILidoWithdrawalQueue.sol";
import {IHarborClaim} from "src/interfaces/IHarborClaim.sol";

/// @title LidoClaimReceipt
/// @notice One zero-decimal unit owns one escrowed unstETH right and its recovery.
/// @dev No administrator, underlying approval, arbitrary calls or beneficiary override.
contract LidoClaimReceipt is ERC20, ReentrancyGuardTransient, IERC721Receiver, IHarborClaim {
  address public immutable FACTORY;
  address public immutable ISSUER;
  address public immutable WETH;
  uint256 public immutable REQUEST_ID;
  uint256 public immutable CHAIN_ID;
  address private immutable _importer;

  /// @notice Requested ETH wei; an upper bound, not a recovery guarantee.
  uint256 public entitlement;
  /// @notice Attributable WETH wei held until the holder burns its receipt.
  uint256 public recovered;
  Status private _state;
  bool private _acceptedNFT;
  bool private transient _receiving;
  uint256 private transient _received;

  error InvalidCustody();
  error InvalidState();
  error Unauthorized();
  error ReceiptMismatch();
  error InvalidRecipient();

  event Activated(uint256 indexed requestId, address indexed owner, uint256 entitlement);
  event RecoveryCollected(uint256 indexed requestId, uint256 cash);
  event Redeemed(address indexed holder, address indexed recipient, uint256 cash);

  constructor(address issuer, address weth, uint256 id, address importer) {
    FACTORY = msg.sender;
    ISSUER = issuer;
    WETH = weth;
    REQUEST_ID = id;
    CHAIN_ID = block.chainid;
    _importer = importer;
  }

  function name() public pure override returns (string memory) { return "Harbor Lido Withdrawal"; }
  function symbol() public pure override returns (string memory) { return "hLIDO-CLAIM"; }
  function decimals() public pure override returns (uint8) { return 0; }

  /// @notice Accept only the factory's exact authenticated NFT handoff.
  function onERC721Received(address operator, address from, uint256 id, bytes calldata data)
    external returns (bytes4)
  {
    if (msg.sender != ISSUER || operator != FACTORY || from != _importer || id != REQUEST_ID
      || data.length != 0 || _acceptedNFT || _state != Status.UNINITIALIZED) revert InvalidCustody();
    _acceptedNFT = true;
    return IERC721Receiver.onERC721Received.selector;
  }

  /// @notice Factory-only one-time mint after the issuer confirms exact custody.
  function activate() external {
    if (msg.sender != FACTORY) revert Unauthorized();
    if (_state != Status.UNINITIALIZED || !_acceptedNFT) revert InvalidState();
    Queue.WithdrawalRequestStatus memory s = _request();
    if (s.isFinalized || s.isClaimed || s.amountOfStETH == 0 || s.amountOfShares == 0) revert InvalidState();
    _checkOwner(s.owner);
    entitlement = s.amountOfStETH;
    _state = Status.PENDING;
    _mint(_importer, 1);
    emit Activated(REQUEST_ID, _importer, entitlement);
  }

  /// @inheritdoc IHarborClaim
  function status() public view returns (Status) {
    if (_state != Status.PENDING) return _state;
    Queue.WithdrawalRequestStatus memory s = _request();
    if (s.isClaimed || s.amountOfStETH != entitlement) revert InvalidCustody();
    _checkOwner(s.owner);
    return s.isFinalized ? Status.FINALIZED : Status.PENDING;
  }

  /// @inheritdoc IHarborClaim
  function recover(uint256 hint) external nonReentrant returns (uint256 cash) {
    if (status() != Status.FINALIZED) revert InvalidState();
    uint256[] memory ids = new uint256[](1);
    uint256[] memory hints = new uint256[](1);
    ids[0] = REQUEST_ID;
    hints[0] = hint;
    uint256[] memory amounts = Queue(ISSUER).getClaimableEther(ids, hints);
    if (amounts.length != 1 || amounts[0] > entitlement) revert ReceiptMismatch();
    _receiving = true;
    Queue(ISSUER).claimWithdrawals(ids, hints);
    _receiving = false;
    cash = _received;
    _received = 0;
    if (cash != amounts[0] || !_request().isClaimed) revert ReceiptMismatch();
    uint256 beforeBalance = SafeTransfer.balanceOf(WETH, address(this));
    IWETH(WETH).deposit{value: cash}();
    if (SafeTransfer.balanceOf(WETH, address(this)) != beforeBalance + cash) revert ReceiptMismatch();
    recovered = cash;
    _state = Status.CASH_READY;
    emit RecoveryCollected(REQUEST_ID, cash);
  }

  /// @inheritdoc IHarborClaim
  function redeem(address recipient) external nonReentrant returns (uint256 cash) {
    if (_state != Status.CASH_READY || balanceOf(msg.sender) != 1) revert InvalidState();
    if (recipient == address(0) || recipient == address(this)) revert InvalidRecipient();
    cash = recovered;
    recovered = 0;
    _state = Status.CLOSED;
    _burn(msg.sender, 1);
    uint256 beforeBalance = SafeTransfer.balanceOf(WETH, recipient);
    SafeTransfer.safeTransfer(WETH, recipient, cash);
    if (SafeTransfer.balanceOf(WETH, recipient) != beforeBalance + cash) revert ReceiptMismatch();
    emit Redeemed(msg.sender, recipient, cash);
  }

  /// @dev Forced ETH bypasses receive and remains uncredited; no sweep authority exists.
  receive() external payable {
    if (!_receiving || msg.sender != ISSUER) revert Unauthorized();
    _received += msg.value;
  }

  function _request() private view returns (Queue.WithdrawalRequestStatus memory s) {
    uint256[] memory ids = new uint256[](1);
    ids[0] = REQUEST_ID;
    Queue.WithdrawalRequestStatus[] memory results = Queue(ISSUER).getWithdrawalStatus(ids);
    if (results.length != 1) revert ReceiptMismatch();
    return results[0];
  }

  function _checkOwner(address owner) private view {
    if (owner != address(this) || Queue(ISSUER).ownerOf(REQUEST_ID) != address(this)) revert InvalidCustody();
  }

  /// @dev Do not let issuer callbacks move ownership while recovery is being measured.
  function _beforeTokenTransfer(address, address, uint256) internal view override {
    if (_receiving) revert InvalidState();
  }

  function _useTransientReentrancyGuardOnlyOnMainnet() internal pure override returns (bool) { return false; }
}
