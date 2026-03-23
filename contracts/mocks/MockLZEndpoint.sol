// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @dev Minimal LayerZero V2 endpoint mock for local testing.
/// Only implements functions called during OFT deployment (setDelegate).
/// Cross-chain operations are not supported — bridge activates in Phase 3.
contract MockLZEndpoint {
    uint32 public immutable eid;

    mapping(address => address) public delegates;

    event DelegateSet(address sender, address delegate);

    constructor(uint32 _eid) {
        eid = _eid;
    }

    function setDelegate(address _delegate) external {
        delegates[msg.sender] = _delegate;
        emit DelegateSet(msg.sender, _delegate);
    }
}
