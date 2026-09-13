import { parseAbi } from 'viem';

// Selected deployed interfaces. Tuple order, units and event indexes are ABI-critical.
export const peripheryAbi = parseAbi([
  "function execute(address book, (address trader, address receiver, address tokenIn, address tokenOut, uint256 route, uint8 side, uint8 mode, uint256 amountSpecified, uint256 limitAmount, uint256 deadline, uint256 pricingVersion, uint256 configVersion, uint256 strategyVersion) trade) payable returns (uint256 input, uint256 output)",
  "function deposit(address book, uint256 minShares) payable returns (uint256 shares)",
  "function mint(address book, uint256 shares) payable returns (uint256 assets)",
  "function withdraw(address book, uint256 assets) returns (uint256 shares)",
  "function redeem(address book, uint256 shares, uint256 minAssets) returns (uint256 assets)",
  "event NativeTrade(address indexed caller, address indexed book, uint256 input, uint256 output, uint256 refund)",
  "event NativeWithdrawal(address indexed caller, address indexed book, uint256 assets, uint256 shares)"
]);
