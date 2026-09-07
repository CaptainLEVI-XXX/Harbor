// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TokenMock} from "@1inch/solidity-utils/contracts/mocks/TokenMock.sol";
import {Aqua} from "@1inch/aqua/src/Aqua.sol";
import {HarborSwapVMRouter} from "src/swapvm/HarborSwapVMRouter.sol";
import {ISwapVM} from "@1inch/swap-vm/src/interfaces/ISwapVM.sol";
import {IMakerHooks} from "@1inch/swap-vm/src/interfaces/IMakerHooks.sol";
import {IHarborFill} from "src/interfaces/IHarborFill.sol";
import {SwapQuery} from "@1inch/swap-vm/src/libs/VM.sol";
import {TakerTraitsLib} from "@1inch/swap-vm/src/libs/TakerTraits.sol";
import {HarborProgram} from "src/swapvm/HarborProgram.sol";

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

/// @notice Official Aqua and Harbor's derived router with synthetic tokens and maker.
abstract contract HarborAquaFixture is Test {
  Aqua internal aqua;
  HarborSwapVMRouter internal router;
  ContractMakerFixture internal maker;
  BookHookFixture internal book;
  TokenMock internal weth;
  TokenMock internal base;
  ISwapVM.Order internal order;

  function setUp() public virtual {
    aqua = new Aqua();
    weth = new TokenMock("Wrapped Ether fixture", "WETH");
    base = new TokenMock("Wrapped stake fixture", "BASE");
    router = new HarborSwapVMRouter(address(aqua), address(weth), address(this), "Harbor", "1");
    maker = new ContractMakerFixture();
    book = new BookHookFixture(address(router), address(maker), address(this));
    order = HarborProgram.build(address(maker), address(book), address(weth), address(base), 0, 1, 1);
    weth.mint(address(maker), 100 ether);
    base.mint(address(maker), 100 ether);
    weth.mint(address(this), 100 ether);
    base.mint(address(this), 100 ether);
    weth.approve(address(router), type(uint256).max);
    base.approve(address(router), type(uint256).max);
    _ship(order, maker);
  }

  function _ship(ISwapVM.Order memory selected, ContractMakerFixture publisher) internal returns (bytes32) {
    address[] memory tokens = new address[](2);
    tokens[0] = address(weth);
    tokens[1] = address(base);
    uint256[] memory amounts = new uint256[](2);
    amounts[0] = 100 ether;
    amounts[1] = 100 ether;
    return publisher.ship(aqua, address(router), selected, tokens, amounts);
  }

  function _traits(bool baseIn, bool exactIn, uint256 threshold, bool inputFirst) internal view returns (bytes memory) {
    TakerTraitsLib.Args memory args;
    args.taker = address(this);
    args.isExactIn = exactIn;
    args.isAToB = baseIn ? address(base) < address(weth) : address(weth) < address(base);
    args.isFirstTransferFromTaker = inputFirst;
    args.useTransferFromAndAquaPush = true;
    args.isStrictThresholdAmount = true;
    args.threshold = abi.encode(threshold);
    return TakerTraitsLib.build(args);
  }
}
