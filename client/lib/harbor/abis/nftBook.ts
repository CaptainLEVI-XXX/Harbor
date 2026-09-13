import { parseAbi } from 'viem';

// Selected deployed interfaces. Tuple order, units and event indexes are ABI-critical.
export const nftBookAbi = parseAbi([
  "function nftGeneration(uint256 route, uint256 id) view returns (uint256)",
  "function nftInventory(uint256 cursor, uint256 limit) view returns ((bytes32 key, uint256 route, address adapter, uint256 issuerId, uint256 basis, uint256 remaining, uint256 received)[] claims, uint256 next)",
  "function nftParameters(uint256 route) view returns ((uint256 discount, uint256 observedAt, uint256 validUntil, uint256 version, uint256 configVersion))",
  "function quoteNft((address trader, address receiver, uint256 route, uint256 tokenId, uint8 side, uint8 mode, uint256 amountSpecified, uint256 limitAmount, uint256 deadline, uint256 pricingVersion, uint256 configVersion, uint256 generation) trade) view returns ((uint256 traderIn, uint256 traderOut, uint256 routerIn, uint256 routerOut, uint256 fee) amounts)"
]);
