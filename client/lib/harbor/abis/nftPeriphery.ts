import { parseAbi } from 'viem';

// Selected deployed interfaces. Tuple order, units and event indexes are ABI-critical.
export const nftPeripheryAbi = parseAbi([
  "function executeNft(address book, (address trader, address receiver, uint256 route, uint256 tokenId, uint8 side, uint8 mode, uint256 amountSpecified, uint256 limitAmount, uint256 deadline, uint256 pricingVersion, uint256 configVersion, uint256 generation) trade) payable returns (uint256 input, uint256 output)",
  "event NativeNftTrade(address indexed caller, address indexed book, uint256 indexed tokenId, uint256 route, bool buyBase, uint256 input, uint256 output, uint256 fee, uint256 refund)"
]);
