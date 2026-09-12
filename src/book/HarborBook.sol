// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {RouteConfig} from "src/types/HarborTypes.sol";
import {BookState} from "src/book/base/BookState.sol";
import {BookViews} from "src/book/base/BookViews.sol";
import {BookGovernance} from "src/book/base/BookGovernance.sol";
import {BookRedemptions} from "src/book/base/BookRedemptions.sol";
import {BookSettlement} from "src/book/base/BookSettlement.sol";
import {BookClaims} from "src/book/base/BookClaims.sol";
import {BookNfts} from "src/book/base/BookNfts.sol";

/// @notice One portfolio and treasury mandate for fungible tokens and issuer NFTs.
contract HarborBook is BookGovernance, BookRedemptions, BookSettlement, BookClaims, BookNfts, BookViews {
  constructor(Config memory c, RouteConfig[] memory routes) BookState(c, routes) {}
}
