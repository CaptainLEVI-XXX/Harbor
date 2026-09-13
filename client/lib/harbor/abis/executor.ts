import { parseAbi } from 'viem';

// Selected deployed interfaces. Tuple order, units and event indexes are ABI-critical.
export const executorAbi = parseAbi([
  "function execute(address book, (address trader, address receiver, address tokenIn, address tokenOut, uint256 route, uint8 side, uint8 mode, uint256 amountSpecified, uint256 limitAmount, uint256 deadline, uint256 pricingVersion, uint256 configVersion, uint256 strategyVersion) trade) returns (uint256 actualIn, uint256 actualOut)",
  "function quote(address book, (address trader, address receiver, address tokenIn, address tokenOut, uint256 route, uint8 side, uint8 mode, uint256 amountSpecified, uint256 limitAmount, uint256 deadline, uint256 pricingVersion, uint256 configVersion, uint256 strategyVersion) trade) view returns ((uint256 traderIn, uint256 traderOut, uint256 routerIn, uint256 routerOut, uint256 fee) a)",
  "function quoteSwap(address book, (address trader, address receiver, address tokenIn, address tokenOut, uint256 route, uint8 side, uint8 mode, uint256 amountSpecified, uint256 limitAmount, uint256 deadline, uint256 pricingVersion, uint256 configVersion, uint256 strategyVersion) trade) view returns (uint256 input, uint256 output, bytes32 orderHash)",
  "function vaultOf(address) view returns (address)",
  "event TradeExecuted(address indexed book, bytes32 indexed context, address indexed trader, address receiver, uint256 route, uint256 amountIn, uint256 amountOut, uint256 fee, uint256 pricingVersion)",
  "error InvalidCallback()",
  "error InvalidFillAmounts()",
  "error InvalidPool()",
  "error LimitExceeded()",
  "error Reentrancy()",
  "error SafeCastOverflowedUintDowncast(uint8 bits, uint256 value)",
  "error SettlementMismatch()",
  "error TakerTraitsMissingHasPreTransferInFlag()",
  "error TakerTraitsMissingHasPreTransferOutFlag()",
  "error TakerTraitsThresholdLengthInvalid(bytes threshold)",
  "error Unauthorized()",
  "error UnauthorizedTrader()"
]);
