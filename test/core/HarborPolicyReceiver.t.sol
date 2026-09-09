// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {HarborPolicyReceiver as Receiver} from "src/HarborPolicyReceiver.sol";
import {IReceiver} from "@chainlink/evm/contracts/cre/src/v1/interfaces/IReceiver.sol";

/// @notice Local authentication boundary fixture; not a DON or CRE signature verifier.
contract MockCREForwarder {
  function deliver(IReceiver receiver, bytes memory metadata, bytes memory report) external {
    receiver.onReport(metadata, report);
  }
}

contract HarborPolicyReceiverTest is Test {
  Receiver private receiver;
  MockCREForwarder private forwarder;
  Receiver.Config private config;

  function setUp() public {
    vm.warp(1000);
    forwarder = new MockCREForwarder();
    config = Receiver.Config(
      address(forwarder),
      address(1),
      address(2),
      address(this),
      address(3),
      keccak256("synthetic-workflow"),
      bytes10(keccak256("synthetic-name")),
      address(4),
      5009297550715157269,
      1,
      keccak256("public-model-build"),
      60
    );
    receiver = new Receiver(config);
  }

  function _report(uint256 nonce) private view returns (Receiver.Report memory) {
    return Receiver.Report(
      1,
      block.chainid,
      config.chainSelector,
      address(receiver),
      config.book,
      config.vault,
      keccak256(abi.encode("synthetic-digest", nonce)),
      0,
      nonce,
      1,
      config.modelHash,
      keccak256("public-observation"),
      1000,
      1060,
      1
    );
  }

  function _metadata() private view returns (bytes memory) {
    return abi.encodePacked(config.workflowId, config.workflowName, config.workflowOwner, bytes2(0x0123));
  }

  function _deliver(Receiver.Report memory r) private {
    forwarder.deliver(receiver, _metadata(), abi.encode(r));
  }

  function test_OnlyForwarderAndAllWorkflowIdentityFields() public {
    bytes memory encoded = abi.encode(_report(1));
    bytes memory metadata = _metadata();
    vm.expectRevert(Receiver.Unauthorized.selector);
    receiver.onReport(metadata, encoded);
    for (uint256 i; i < 3; ++i) {
      metadata = _metadata();
      metadata[i == 0 ? 0 : i == 1 ? 32 : 42] ^= 0x01;
      vm.expectRevert(Receiver.InvalidMetadata.selector);
      forwarder.deliver(receiver, metadata, encoded);
    }
  }

  function test_DuplicateDeliveryIsIdempotentAndDoesNotExtendExpiry() public {
    Receiver.Report memory r = _report(1);
    _deliver(r);
    vm.recordLogs();
    _deliver(r);
    assertEq(vm.getRecordedLogs().length, 0);
    (, uint256 epoch, uint256 until) = receiver.permits(r.finalFillDigest);
    assertEq(epoch, 0);
    assertEq(until, 1060);
    r.observedAt = 1001;
    r.validUntil = 1061;
    vm.warp(1001);
    vm.expectRevert(Receiver.ConflictingReport.selector);
    _deliver(r);
    r.authorizationNonce = 2;
    vm.expectRevert(Receiver.ConflictingReport.selector);
    _deliver(r);
  }

  function test_CancellationDoesNotReviveOldDigests() public {
    Receiver.Report memory r = _report(1);
    _deliver(r);
    receiver.cancelPermits();
    assertFalse(receiver.isApproved(r.finalFillDigest));
    vm.expectRevert(Receiver.InvalidReport.selector);
    _deliver(r);
    r.authorizationEpoch = 1;
    vm.expectRevert(Receiver.ConflictingReport.selector);
    _deliver(r);
    r.finalFillDigest = keccak256("fresh-fill");
    _deliver(r);
    assertTrue(receiver.isApproved(r.finalFillDigest));
  }
}
