// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Aqua} from "@1inch/aqua/src/Aqua.sol";
import {ISwapVM} from "@1inch/swap-vm/src/interfaces/ISwapVM.sol";
import {IMakerHooks} from "@1inch/swap-vm/src/interfaces/IMakerHooks.sol";
import {IHarborFill} from "src/interfaces/IHarborFill.sol";
import {SwapQuery} from "@1inch/swap-vm/src/libs/VM.sol";

/// @notice Test-only contract maker. No LP shares or production treasury API.
contract ContractMakerFixture {
  function ship(
    Aqua aqua,
    address router,
    ISwapVM.Order calldata order,
    address[] calldata tokens,
    uint256[] calldata amounts
  ) external returns (bytes32) {
    for (uint256 i; i < tokens.length; ++i) {
      IERC20(tokens[i]).approve(address(aqua), amounts[i]);
    }
    return aqua.ship(router, abi.encode(order), tokens, amounts);
  }
}

/// @notice Synthetic exact-pair Book for upstream integration tests only.
/// @dev Quotes are deliberately test-configured, not signed financial approvals.
contract BookHookFixture is IHarborFill, IMakerHooks {
  address public immutable router;
  address public immutable maker;
  address public immutable taker;
  bytes32 public orderHash;
  uint256 public amountIn;
  uint256 public amountOut;
  uint256 public settlements;
  bool public rejectPayout;
  uint256 private transient phase;
  bytes32 private transient activeHook;
  uint256 private transient beforeIn;
  uint256 private transient beforeOut;

  constructor(address router_, address maker_, address taker_) {
    router = router_;
    maker = maker_;
    taker = taker_;
  }

  function configure(bytes32 hash_, uint256 in_, uint256 out_, bool reject_) external {
    require(msg.sender == taker && phase == 0, "fixture authority");
    orderHash = hash_;
    amountIn = in_;
    amountOut = out_;
    rejectPayout = reject_;
  }

  function authorizeFill(
    bool isStaticContext,
    SwapQuery calldata query,
    uint256 route,
    uint256 version,
    bytes calldata payload
  ) external returns (uint256, uint256) {
    require(
      msg.sender == router && query.maker == maker && query.taker == taker && query.orderHash == orderHash, "identity"
    );
    require(route == 0 && version == 1 && payload.length == 0, "payload");
    if (!isStaticContext) {
      require(phase == 0, "busy");
      phase = 1;
      activeHook =
        keccak256(abi.encode(query.maker, query.taker, query.tokenIn, query.tokenOut, amountIn, amountOut, orderHash));
      beforeIn = IERC20(query.tokenIn).balanceOf(maker);
      beforeOut = IERC20(query.tokenOut).balanceOf(maker);
    }
    return (amountIn, amountOut);
  }

  function preTransferIn(address, address, address, address, uint256, uint256, bytes32, bytes calldata, bytes calldata)
    external
    pure
  {
    revert("disabled hook");
  }

  function postTransferIn(
    address m,
    address t,
    address ti,
    address to,
    uint256 ai,
    uint256 ao,
    uint256 fee,
    bytes32 hash,
    bytes calldata md,
    bytes calldata td
  ) external {
    _authenticate(m, t, ti, to, ai, ao, hash, md, td, 1);
    require(fee == 0 && IERC20(ti).balanceOf(maker) == beforeIn + ai, "input delta");
    phase = 2;
  }

  function preTransferOut(
    address m,
    address t,
    address ti,
    address to,
    uint256 ai,
    uint256 ao,
    bytes32 hash,
    bytes calldata md,
    bytes calldata td
  ) external {
    _authenticate(m, t, ti, to, ai, ao, hash, md, td, 2);
    phase = 3;
  }

  function postTransferOut(
    address m,
    address t,
    address ti,
    address to,
    uint256 ai,
    uint256 ao,
    uint256 fee,
    bytes32 hash,
    bytes calldata md,
    bytes calldata td
  ) external {
    _authenticate(m, t, ti, to, ai, ao, hash, md, td, 3);
    require(!rejectPayout && fee == 0 && IERC20(to).balanceOf(maker) == beforeOut - ao, "output delta");
    ++settlements;
    phase = 0;
    activeHook = 0;
    beforeIn = 0;
    beforeOut = 0;
  }

  function _authenticate(
    address m,
    address t,
    address ti,
    address to,
    uint256 ai,
    uint256 ao,
    bytes32 hash,
    bytes calldata md,
    bytes calldata td,
    uint256 expected
  ) private view {
    require(msg.sender == router && phase == expected && md.length == 0 && td.length == 0, "hook phase");
    require(keccak256(abi.encode(m, t, ti, to, ai, ao, hash)) == activeHook, "hook identity");
  }
}
