import { parseAbi } from 'viem';

// Selected deployed interfaces. Tuple order, units and event indexes are ABI-critical.
export const bookAbi = parseAbi([
  "function FEE_BPS() view returns (uint256)",
  "function claimMarket(uint256 route) view returns ((address factory, address receipt, uint256 sourceRoute, address adapter, bytes32 claimId, uint256 nominal))",
  "function configVersion() view returns (uint256)",
  "function pricingParameters(uint256 route) view returns ((uint256 discount, uint256 observedAt, uint256 validUntil, uint256 version, uint256 configVersion))",
  "function registerClaimMarket(address factory, address receipt) returns (uint256 route)",
  "function route(uint256 id) view returns ((address base, address adapter, uint256 bid, uint256 ask, uint256 buyBuffer, uint256 sellBuffer, uint256 maxExposure, uint256 maxPurchases, uint256 lossBudget, uint256 maxDailyRedemption))",
  "function stopped() view returns (bool)",
  "function strategyVersion(uint256) view returns (uint256)",
  "error Busy()",
  "error CapacityExceeded()",
  "error InvalidCallback()",
  "error InvalidConfiguration()",
  "error InvalidDecimals()",
  "error InvalidIntent()",
  "error InvalidPricingDomain()",
  "error InvalidQuote()",
  "error SettlementMismatch()",
  "error Unauthorized()"
]);
