// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IWETH} from "@1inch/solidity-utils/contracts/interfaces/IWETH.sol";
import {Aqua} from "@1inch/aqua/src/Aqua.sol";
import {TakerTraitsLib} from "@1inch/swap-vm/src/libs/TakerTraits.sol";
import {ISwapVM} from "@1inch/swap-vm/src/interfaces/ISwapVM.sol";
import {HarborSwapVMRouter} from "src/swapvm/HarborSwapVMRouter.sol";
import {HarborProgram} from "src/swapvm/HarborProgram.sol";
import {LidoClaimFactory} from "src/claims/LidoClaimFactory.sol";
import {LidoClaimReceipt} from "src/claims/LidoClaimReceipt.sol";
import {ILidoWithdrawalQueue as Queue} from "src/interfaces/ILidoWithdrawalQueue.sol";
import {BookHookFixture, ContractMakerFixture} from "test/base/ForkMakerFixture.sol";
import {ILidoQueueHistory} from "test/fork/LidoAdapter.fork.t.sol";

/// @notice TEST ONLY: seed a separately mature historical right to isolate actual recovery.
/// @dev This entrypoint is absent from canonical factory receipts. It proves neither
/// maturation of the new request nor admission of finalized receipts to trading.
contract HistoricalReceiptHarness is LidoClaimReceipt {
  constructor(address issuer, address weth) LidoClaimReceipt(issuer, weth) {}

  function seed(uint256 entitlement_) external {
    require(msg.sender == FACTORY && REQUEST_ID != 0 && _state == Status.UNINITIALIZED);
    require(Queue(ISSUER).ownerOf(REQUEST_ID) == address(this));
    entitlement = entitlement_;
    _state = Status.PENDING;
    _mint(msg.sender, 1);
  }
}

/// @notice Mainnet-pinned issuer/token evidence with local official Aqua/router deployments.
/// @dev Maker/quote authority are compatibility fixtures; full LP accounting is tested locally.
contract RedemptionMarketForkTest is Test {
  uint256 internal constant FORK_BLOCK = 25_930_239;
  address internal constant WSTETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;
  address internal constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
  address internal constant QUEUE = 0x889edC2eDab5f40e902b864aD4d7AdE8E412F9B1;

  function setUp() public {
    vm.createSelectFork(vm.envOr("HARBOR_MAINNET_RPC_URL", string("https://ethereum-rpc.publicnode.com")), FORK_BLOCK);
    assertEq(block.chainid, 1);
    assertEq(ILidoQueueHistory(QUEUE).proxy__getImplementation(), 0xE42C659Dc09109566720EA8b2De186c2Be7D94D9);
  }

  function test_ForkNewLidoClaimTradesForRealWethThroughAquaSwapVM() public {
    vm.deal(address(this), 5 ether);
    (bool ok,) = WSTETH.call{value: 1 ether}("");
    assertTrue(ok);
    uint256[] memory amounts = new uint256[](1);
    amounts[0] = IERC20(WSTETH).balanceOf(address(this));
    IERC20(WSTETH).approve(QUEUE, amounts[0]);
    uint256 id = Queue(QUEUE).requestWithdrawalsWstETH(amounts, address(this))[0];
    LidoClaimFactory factory = new LidoClaimFactory(QUEUE, WETH, address(this));
    IERC721(QUEUE).approve(address(factory), id);
    address receipt = factory.wrap(id);
    assertEq(IERC721(QUEUE).ownerOf(id), receipt);
    Aqua aqua = new Aqua();
    HarborSwapVMRouter router = new HarborSwapVMRouter(address(aqua), WETH, address(this), "Harbor", "1");
    ContractMakerFixture maker = new ContractMakerFixture();
    BookHookFixture book = new BookHookFixture(address(router), address(maker), address(this));
    ISwapVM.Order memory order =
      HarborProgram.claim(address(maker), address(book), WETH, receipt, 0, 1, address(factory), 1);
    IWETH(WETH).deposit{value: 2 ether}();
    IERC20(WETH).transfer(address(maker), 1 ether);
    address[] memory tokens = new address[](2);
    tokens[0] = WETH;
    tokens[1] = receipt;
    uint256[] memory allocations = new uint256[](2);
    allocations[0] = 1 ether;
    maker.ship(aqua, address(router), order, tokens, allocations);
    book.configure(router.hash(order), 1, 0.99 ether, false);
    IERC20(receipt).approve(address(router), 1);
    TakerTraitsLib.Args memory args;
    args.taker = address(this);
    args.isExactIn = true;
    args.isAToB = receipt < WETH;
    args.isFirstTransferFromTaker = true;
    args.useTransferFromAndAquaPush = true;
    args.isStrictThresholdAmount = true;
    args.threshold = abi.encode(uint256(0.99 ether));
    uint256 before = IERC20(WETH).balanceOf(address(this));
    uint256 beforeIssuer = QUEUE.balance;
    (uint256 amountIn, uint256 amountOut,) = router.swap(order, 1, TakerTraitsLib.build(args));
    assertEq(amountIn, 1);
    assertEq(amountOut, 0.99 ether);
    assertEq(IERC20(WETH).balanceOf(address(this)), before + amountOut);
    assertEq(IERC20(receipt).balanceOf(address(maker)), 1);
    assertEq(IERC20(receipt).balanceOf(address(this)), 0);
    assertEq(IERC721(QUEUE).ownerOf(id), receipt);
    assertEq(QUEUE.balance, beforeIssuer);
    emit log_named_uint("fork_request_id", id);
    emit log_named_uint("actual_weth_payment_wei", amountOut);
  }

  function test_ForkHistoricalRecoveryPaysActualIssuerCash() public {
    uint256[] memory ids = new uint256[](1);
    ids[0] = 134_829;
    Queue.WithdrawalRequestStatus memory s = Queue(QUEUE).getWithdrawalStatus(ids)[0];
    assertTrue(s.isFinalized);
    assertFalse(s.isClaimed);
    HistoricalReceiptHarness receipt = new HistoricalReceiptHarness(QUEUE, WETH);
    receipt.initialize(ids[0], address(this));
    vm.prank(s.owner);
    IERC721(QUEUE).transferFrom(s.owner, address(receipt), ids[0]);
    receipt.seed(s.amountOfStETH);
    uint256[] memory hints =
      ILidoQueueHistory(QUEUE).findCheckpointHints(ids, 1, ILidoQueueHistory(QUEUE).getLastCheckpointIndex());
    uint256 expected = Queue(QUEUE).getClaimableEther(ids, hints)[0];
    uint256 beforeIssuer = QUEUE.balance;
    uint256 beforeOwner = IERC20(WETH).balanceOf(address(this));
    assertEq(receipt.recover(hints[0]), expected);
    assertEq(receipt.redeem(address(this)), expected);
    assertEq(QUEUE.balance, beforeIssuer - expected);
    assertEq(IERC20(WETH).balanceOf(address(this)), beforeOwner + expected);
    assertEq(receipt.totalSupply(), 0);
  }
}
