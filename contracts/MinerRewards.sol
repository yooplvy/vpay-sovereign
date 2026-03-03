// SPDX-License-Identifier: VPAY-1.0
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "./VPAYToken.sol";

contract MinerRewards is AccessControl {
    VPAYToken public immutable token;
    uint256 public constant REWARD_PER_BLOCK = 10 * 1e18; // 10 VPAY per block
    
    mapping(bytes32 => uint256) public lastRewardBlock;

    event RewardsClaimed(bytes32 indexed nodeId, uint256 amount);

    constructor(address _token) {
        token = VPAYToken(_token);
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    // Called by Vault when a loan starts
    function updateReward(bytes32 _nodeId) external onlyRole(DEFAULT_ADMIN_ROLE) {
        lastRewardBlock[_nodeId] = block.number;
    }

    // User claims their earnings
    function claimRewards(bytes32 _nodeId) external {
        uint256 blocksPassed = block.number - lastRewardBlock[_nodeId];
        uint256 reward = blocksPassed * REWARD_PER_BLOCK;
        
        lastRewardBlock[_nodeId] = block.number;
        
        token.mint(msg.sender, reward);
        emit RewardsClaimed(_nodeId, reward);
    }
}
