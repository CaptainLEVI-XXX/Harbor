import { parseAbi } from 'viem';

export const queueAbi = parseAbi([
  'function WSTETH() view returns (address)',
  'function MIN_STETH_WITHDRAWAL_AMOUNT() view returns (uint256)',
  'function MAX_STETH_WITHDRAWAL_AMOUNT() view returns (uint256)',
  'function getWithdrawalRequests(address owner) view returns (uint256[])',
  'function getWithdrawalStatus(uint256[] ids) view returns ((uint256 amountOfStETH,uint256 amountOfShares,address owner,uint256 timestamp,bool isFinalized,bool isClaimed)[])',
  'function requestWithdrawalsWstETH(uint256[] amounts, address owner) returns (uint256[])',
  'event WithdrawalRequested(uint256 indexed requestId, address indexed requestor, address indexed owner, uint256 amountOfStETH, uint256 amountOfShares)',
]);
export const conversionAbi = parseAbi(['function getStETHByWstETH(uint256) view returns (uint256)']);
