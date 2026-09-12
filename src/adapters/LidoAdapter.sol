// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {SafeTransferLib as SafeTransfer} from "solady/utils/SafeTransferLib.sol";
import {LidoViews} from "src/adapters/lido/LidoViews.sol";
import {LidoClaims} from "src/adapters/lido/LidoClaims.sol";
import {IssuerClaimLedger} from "src/libraries/IssuerClaimLedger.sol";
import {ClaimImport, ClaimDomain, ClaimStage, CollateralKind} from "src/types/ClaimTypes.sol";
import {IHarborClaim} from "src/interfaces/IHarborClaim.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {IWETH} from "@1inch/solidity-utils/contracts/interfaces/IWETH.sol";
import {ILidoWithdrawalQueue as Queue, IWstETHConversion} from "src/interfaces/ILidoWithdrawalQueue.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IHarborClaimFactory} from "src/interfaces/IHarborClaimFactory.sol";
import {NftObservation} from "src/types/NftTypes.sol";
import {FixedPointMathLib as Math} from "solady/utils/FixedPointMathLib.sol";

/// @notice Pool-bound Lido custody, valuation and claim-attributed ASSET recovery.
/// @dev Native claims pay the fixed Vault; tokenized claims pay their receipt holder.
/// NFT callbacks are accepted only during a factory-authenticated import. Unsolicited
/// safe transfers fail; unsafe transfers never become tracked obligations.
contract LidoAdapter is LidoViews, IERC721Receiver {
  uint256 private transient _importId;
  address private transient _importOwner;
  bool private transient _importAccepted;

  event Requested(uint256 indexed id, uint256 wrappedAmount, uint256 entitlement);
  event Recovered(uint256 indexed id, uint256 wethAmount);
  event ClaimExported(uint256 indexed id, address indexed receipt);
  event ClaimImported(
    bytes32 indexed claimId, uint256 indexed issuerId, address indexed receipt, address owner, uint256 nominal
  );
  event ClaimCashCollected(bytes32 indexed claimId, uint256 cash);
  event ClaimPaid(bytes32 indexed claimId, address indexed receiver, uint256 cash);
  event RawNftCustody(uint256 indexed id, address indexed owner, bool acquired);

  constructor(address book, address vault, address wsteth, address weth, address queue, Config memory c)
    LidoViews(book, vault, wsteth, weth, queue, c)
  {}

  function nativeClaimId(uint256 id) public view returns (bytes32) {
    return LidoClaims.identity(ISSUER, id);
  }

  /// @notice Permanent recognition of a requested or imported issuer right, including after payout.
  function accepted(uint256 id) external view returns (bool) {
    return _claims.claims[nativeClaimId(id)].domain != ClaimDomain.NONE;
  }

  /// @notice Whether the native payout path is retired by settlement or tokenization.
  /// @dev Tokenization does not settle the holder's right; use claimState for that lifecycle.
  function closed(uint256 id) external view returns (bool) {
    IssuerClaimLedger.Claim storage c = _claims.claims[nativeClaimId(id)];
    return c.stage == ClaimStage.CLOSED || c.domain == ClaimDomain.TOKENIZED;
  }

  function request(uint256[] calldata amounts, uint256 previousBalance)
    external
    onlyBook
    nonReentrant
    returns (Request[] memory requests)
  {
    if (amounts.length == 0 || amounts.length > 8) revert InvalidRequest();
    uint256 total;
    uint256 minimum = Queue(ISSUER).MIN_STETH_WITHDRAWAL_AMOUNT();
    uint256 maximum = Queue(ISSUER).MAX_STETH_WITHDRAWAL_AMOUNT();
    for (uint256 i; i < amounts.length; ++i) {
      uint256 underlying = IWstETHConversion(BASE).getStETHByWstETH(amounts[i]);
      if (amounts[i] == 0 || underlying < minimum || underlying > maximum) revert InvalidRequest();
      total += amounts[i];
    }
    if (SafeTransfer.balanceOf(BASE, address(this)) != previousBalance + total) revert ReceiptMismatch();
    SafeTransfer.safeApprove(BASE, ISSUER, total);
    uint256[] memory ids = Queue(ISSUER).requestWithdrawalsWstETH(amounts, address(this));
    SafeTransfer.safeApprove(BASE, ISSUER, 0);
    if (ids.length != amounts.length || SafeTransfer.balanceOf(BASE, address(this)) != previousBalance) {
      revert ReceiptMismatch();
    }
    Queue.WithdrawalRequestStatus[] memory statuses = Queue(ISSUER).getWithdrawalStatus(ids);
    if (statuses.length != ids.length) revert ReceiptMismatch();
    requests = new Request[](ids.length);
    for (uint256 i; i < ids.length; ++i) {
      Queue.WithdrawalRequestStatus memory s = statuses[i];
      bytes32 key = nativeClaimId(ids[i]);
      if (
        ids[i] == 0 || _claims.claims[key].stage != ClaimStage.NONE || s.owner != address(this) || s.isClaimed
          || s.isFinalized || s.timestamp != block.timestamp || s.amountOfStETH == 0 || s.amountOfShares == 0
          || s.amountOfStETH != IWstETHConversion(BASE).getStETHByWstETH(amounts[i])
          || Queue(ISSUER).ownerOf(ids[i]) != address(this)
      ) revert InvalidRequest();
      _claims.claims[key] =
        IssuerClaimLedger.Claim(ids[i], s.amountOfStETH, 0, address(0), ClaimDomain.NATIVE_VAULT, ClaimStage.PENDING);
      requests[i] = Request(ids[i], amounts[i], s.amountOfStETH);
      emit Requested(ids[i], amounts[i], s.amountOfStETH);
    }
  }

  /// @notice Native recovery is Book-only and always pays the fixed Vault.
  function claim(uint256 id, uint256 hint) external onlyBook nonReentrant returns (uint256 cash, uint256 remaining) {
    bytes32 key = nativeClaimId(id);
    IssuerClaimLedger.Claim storage c = _claims.claims[key];
    if ((c.domain != ClaimDomain.NATIVE_VAULT && c.domain != ClaimDomain.RAW_VAULT) || c.stage != ClaimStage.PENDING) {
      revert InvalidRequest();
    }
    _busyClaim = key;
    cash = _collect(c, hint);
    c.stage = ClaimStage.CLOSED;
    _transferCash(VAULT, cash);
    _busyClaim = bytes32(0);
    emit Recovered(id, cash);
    return (cash, 0);
  }

  /// @notice Export changes representation, never custody, face, basis or beneficiary.
  function exportClaim(uint256 id, address factory) external onlyBook nonReentrant returns (address receipt) {
    bytes32 key = nativeClaimId(id);
    IssuerClaimLedger.Claim storage c = _claims.claims[key];
    if (
      factory != FACTORY || c.domain != ClaimDomain.NATIVE_VAULT || c.stage != ClaimStage.PENDING
        || claimState(key).status != IHarborClaim.Status.PENDING
    ) revert InvalidRequest();
    c.domain = ClaimDomain.TOKENIZED;
    receipt = IHarborClaimFactory(FACTORY).exportClaim(key, VAULT);
    c.receipt = receipt;
    if (SafeTransfer.balanceOf(receipt, VAULT) != 1) revert ReceiptMismatch();
    emit ClaimExported(id, receipt);
  }

  /// @notice Identity preview only. Import independently verifies exact collateral.
  function claimId(ClaimImport calldata input) public view returns (bytes32) {
    if (
      input.kind != CollateralKind.ERC721 || input.asset != ISSUER || input.tokenId == 0 || input.amount != 1
        || input.data.length != 0
    ) revert InvalidRequest();
    return nativeClaimId(input.tokenId);
  }

  function importClaim(address owner, ClaimImport calldata input, address receipt)
    external
    nonReentrant
    returns (bytes32 key, uint256 nominal)
  {
    if (msg.sender != FACTORY) revert Unauthorized();
    _idle();
    key = claimId(input);
    if (
      IHarborClaimFactory(FACTORY).receiptOf(address(this), key) != receipt
        || _claims.claims[key].stage != ClaimStage.NONE || owner == address(0)
        || Queue(ISSUER).ownerOf(input.tokenId) != owner
    ) revert InvalidRequest();
    _importId = input.tokenId;
    _importOwner = owner;
    IERC721(ISSUER).safeTransferFrom(owner, address(this), input.tokenId);
    if (!_importAccepted || Queue(ISSUER).ownerOf(input.tokenId) != address(this)) revert ReceiptMismatch();
    uint256[] memory ids = new uint256[](1);
    ids[0] = input.tokenId;
    Queue.WithdrawalRequestStatus[] memory s = Queue(ISSUER).getWithdrawalStatus(ids);
    if (
      s.length != 1 || s[0].isFinalized || s[0].isClaimed || s[0].owner != address(this) || s[0].amountOfStETH == 0
        || s[0].amountOfShares == 0
    ) revert InvalidRequest();
    nominal = s[0].amountOfStETH;
    _claims.claims[key] =
      IssuerClaimLedger.Claim(input.tokenId, nominal, 0, receipt, ClaimDomain.TOKENIZED, ClaimStage.PENDING);
    _importId = 0;
    _importOwner = address(0);
    _importAccepted = false;
    emit ClaimImported(key, input.tokenId, receipt, owner, nominal);
  }

  function onERC721Received(address operator, address from, uint256 id, bytes calldata data) external returns (bytes4) {
    if (
      msg.sender != ISSUER || operator != address(this) || from != _importOwner || id == 0 || id != _importId
        || data.length != 0 || _importAccepted
    ) revert Unauthorized();
    _importAccepted = true;
    return IERC721Receiver.onERC721Received.selector;
  }

  /// @notice Quote any pending issuer ID before custody; finalized/claimed or other-domain rights are ineligible.
  function nftObservation(uint256 id) public view returns (NftObservation memory o) {
    uint256[] memory ids = new uint256[](1);
    ids[0] = id;
    Queue.WithdrawalRequestStatus memory s = Queue(ISSUER).getWithdrawalStatus(ids)[0];
    IssuerClaimLedger.Claim storage c = _claims.claims[nativeClaimId(id)];
    o.owner = Queue(ISSUER).ownerOf(id);
    o.nominal = s.amountOfStETH;
    o.mark = Math.fullMulDiv(o.nominal, claimFactor, 1e18);
    o.observedAt = observedAt;
    o.valid = id != 0 && !s.isFinalized && !s.isClaimed && s.owner == o.owner && s.amountOfShares != 0 && o.nominal != 0
      && _fresh()
      && (c.domain == ClaimDomain.NONE || (c.domain == ClaimDomain.RAW_VAULT && c.stage == ClaimStage.PENDING))
      && (o.owner != address(this) || (c.domain == ClaimDomain.RAW_VAULT && c.nominal == o.nominal));
  }

  /// @notice Book-only purchase into pooled custody. No factory, clone or ID-specific admission.
  function acquireNft(address owner, uint256 id) external onlyBook nonReentrant returns (uint256 nominal) {
    NftObservation memory o = nftObservation(id);
    bytes32 key = nativeClaimId(id);
    if (!o.valid || o.owner != owner || _claims.claims[key].domain != ClaimDomain.NONE) revert InvalidRequest();
    _importId = id;
    _importOwner = owner;
    IERC721(ISSUER).safeTransferFrom(owner, address(this), id);
    if (!_importAccepted || Queue(ISSUER).ownerOf(id) != address(this)) revert ReceiptMismatch();
    _claims.claims[key] =
      IssuerClaimLedger.Claim(id, o.nominal, 0, address(0), ClaimDomain.RAW_VAULT, ClaimStage.PENDING);
    _importId = 0;
    _importOwner = address(0);
    _importAccepted = false;
    emit RawNftCustody(id, owner, true);
    return o.nominal;
  }

  /// @notice Return the original NFT; the buyer, not Harbor, then owns its recovery.
  /// @dev Sale clears only raw custody, allowing a fresh acquisition later. Recovery keeps a CLOSED tombstone.
  function releaseNft(address receiver, uint256 id) external onlyBook nonReentrant {
    bytes32 key = nativeClaimId(id);
    NftObservation memory o = nftObservation(id);
    if (!o.valid || o.owner != address(this) || receiver == address(this) || receiver == address(0)) {
      revert InvalidRequest();
    }
    delete _claims.claims[key];
    IERC721(ISSUER).safeTransferFrom(address(this), receiver, id);
    if (Queue(ISSUER).ownerOf(id) != receiver) revert ReceiptMismatch();
    emit RawNftCustody(id, receiver, false);
  }

  /// @notice Anyone may collect cash; the recovery caller cannot select its owner.
  function recoverTokenized(bytes32 id, bytes calldata data) external nonReentrant returns (uint256 cash) {
    _claimOperation(id);
    IssuerClaimLedger.Claim storage c = _claims.claims[id];
    if (c.domain != ClaimDomain.TOKENIZED || c.stage != ClaimStage.PENDING || data.length != 32) {
      revert InvalidRequest();
    }
    _busyClaim = id;
    cash = _collect(c, abi.decode(data, (uint256)));
    c.cash = cash;
    c.stage = ClaimStage.CASH_READY;
    _claims.totalCash += cash;
    _busyClaim = bytes32(0);
    emit ClaimCashCollected(id, cash);
  }

  /// @notice Canonical receipt only, after its holder's atomic burn.
  function redeemTokenized(bytes32 id, address receiver) external nonReentrant returns (uint256 cash) {
    _claimOperation(id);
    IssuerClaimLedger.Claim storage c = _claims.claims[id];
    if (
      c.domain != ClaimDomain.TOKENIZED || c.stage != ClaimStage.CASH_READY || msg.sender != c.receipt
        || IHarborClaimFactory(FACTORY).receiptOf(address(this), id) != msg.sender
    ) revert Unauthorized();
    if (receiver == address(0) || receiver == address(this)) revert InvalidRequest();
    _busyClaim = id;
    cash = c.cash;
    c.cash = 0;
    c.stage = ClaimStage.CLOSED;
    _claims.totalCash -= cash;
    // No external call intervenes: _transferCash checks remaining credits + this
    // payout against physical cash, exactly the aggregate before this debit.
    _transferCash(receiver, cash);
    _busyClaim = bytes32(0);
    emit ClaimPaid(id, receiver, cash);
  }

  /// @dev One call per right makes ETH attribution unambiguous. Donations stay excluded.
  function _collect(IssuerClaimLedger.Claim storage c, uint256 hint) private returns (uint256 cash) {
    uint256[] memory ids = new uint256[](1);
    uint256[] memory hints = new uint256[](1);
    ids[0] = c.issuerId;
    hints[0] = hint;
    Queue.WithdrawalRequestStatus[] memory s = Queue(ISSUER).getWithdrawalStatus(ids);
    if (
      s.length != 1 || !s[0].isFinalized || s[0].isClaimed || s[0].owner != address(this)
        || s[0].amountOfStETH != c.nominal || Queue(ISSUER).ownerOf(c.issuerId) != address(this)
    ) revert InvalidRequest();
    uint256[] memory amounts = Queue(ISSUER).getClaimableEther(ids, hints);
    if (amounts.length != 1 || amounts[0] > c.nominal) revert ReceiptMismatch();
    _receiving = true;
    Queue(ISSUER).claimWithdrawals(ids, hints);
    _receiving = false;
    cash = _received;
    _received = 0;
    s = Queue(ISSUER).getWithdrawalStatus(ids);
    if (cash != amounts[0] || s.length != 1 || !s[0].isClaimed) revert ReceiptMismatch();
    uint256 beforeBalance = SafeTransfer.balanceOf(ASSET, address(this));
    if (cash != 0) IWETH(ASSET).deposit{value: cash}();
    if (SafeTransfer.balanceOf(ASSET, address(this)) != beforeBalance + cash) revert ReceiptMismatch();
  }

  /// @dev Tokenized callers debit totalCash first; native cash was never in that total.
  /// Preserve every other unpaid credit and exclude donations from the measured payout.
  function _transferCash(address receiver, uint256 cash) private {
    uint256 beforeSelf = SafeTransfer.balanceOf(ASSET, address(this));
    if (beforeSelf < _claims.totalCash + cash) revert ReceiptMismatch();
    uint256 beforeReceiver = SafeTransfer.balanceOf(ASSET, receiver);
    if (cash != 0) SafeTransfer.safeTransfer(ASSET, receiver, cash);
    if (
      SafeTransfer.balanceOf(ASSET, address(this)) != beforeSelf - cash
        || SafeTransfer.balanceOf(ASSET, receiver) != beforeReceiver + cash
    ) revert ReceiptMismatch();
  }
}
