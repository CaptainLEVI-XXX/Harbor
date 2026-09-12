// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;
import {NftObservation} from "src/types/NftTypes.sol";

interface IHarborNftAdapter {
  function ISSUER() external view returns (address);
  function nftObservation(uint256 id) external view returns (NftObservation memory);
  function acquireNft(address owner, uint256 id) external returns (uint256 nominal);
  function releaseNft(address receiver, uint256 id) external;
}
