// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Vm} from "forge-std/Vm.sol";
import {BookAccounting} from "src/libraries/BookAccounting.sol";

/// @notice Independent event projection used instead of a production gain-history counter.
library RealizationLogs {
  bytes32 internal constant TOPIC = keccak256("PositionRealized(uint256,bytes32,uint8,uint256,uint256,uint256)");

  function totals(Vm.Log[] memory logs, address emitter, uint256 route)
    internal
    pure
    returns (uint256 gains, uint256 losses, uint256 count)
  {
    for (uint256 i; i < logs.length; ++i) {
      Vm.Log memory log = logs[i];
      if (log.emitter != emitter || log.topics.length != 3 || log.topics[0] != TOPIC) continue;
      if (uint256(log.topics[1]) != route) continue;
      (, uint256 basis, uint256 cash,) =
        abi.decode(log.data, (BookAccounting.RealizationKind, uint256, uint256, uint256));
      if (cash >= basis) gains += cash - basis;
      else losses += basis - cash;
      ++count;
    }
  }
}
