// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./VPAYToken.sol";

/**
 * @title StakingModule V2.4
 * @notice Production Staking with Fee Processor Role.
 */
contract StakingModule is AccessControl, ReentrancyGuard {
    IERC20 public immutable usdc;
    VPAYToken public immutable vpay;

    bytes32 public constant FEE_PROCESSOR_ROLE = keccak256("FEE_PROCESSOR_ROLE");

    uint256 public constant REWARD_PERCENT = 20;
    uint256 public constant BUYBACK_PERCENT = 80;
    uint256 public constant MIN_LOCK_DAYS = 30;
    uint256 public constant PENALTY_PERCENT = 10; 
    uint256 public constant MIN_STAKE_FOR_REWARDS = 1 days; 

    struct StakeInfo {
        uint256 amount;
        uint256 lockEnd;
        uint256 startTime;
    }

    mapping(address => StakeInfo) public stakes;
    uint256 public totalStaked;
    
    event Staked(address indexed user, uint256 amount, uint256 lockEnd);
    event Withdrawn(address indexed user, uint256 amount, uint256 penalty);
    event FeesProcessed(uint256 stakerShare, uint256 buybackShare);

    constructor(address _usdc, address _vpay) {
        usdc = IERC20(_usdc);
        vpay = VPAYToken(_vpay);
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(FEE_PROCESSOR_ROLE, msg.sender); // Grant to deployer initially
    }

    function stake(uint256 amount, uint256 lockDays) external nonReentrant {
        require(lockDays >= MIN_LOCK_DAYS, "Lock duration too short");
        require(stakes[msg.sender].amount == 0, "Unstake first");
        
        vpay.transferFrom(msg.sender, address(this), amount);
        
        uint256 lockEnd = block.timestamp + (lockDays * 1 days);
        stakes[msg.sender] = StakeInfo({
            amount: amount,
            lockEnd: lockEnd,
            startTime: block.timestamp
        });
        
        totalStaked += amount;
        emit Staked(msg.sender, amount, lockEnd);
    }

    function withdraw() external nonReentrant {
        StakeInfo storage userStake = stakes[msg.sender];
        require(userStake.amount > 0, "No stake found");
        
        uint256 amount = userStake.amount;
        uint256 penalty = 0;

        if (block.timestamp < userStake.lockEnd) {
            penalty = (amount * PENALTY_PERCENT) / 100;
            vpay.burn(penalty);
        }

        uint256 returnAmount = amount - penalty;
        delete stakes[msg.sender];
        totalStaked -= amount;
        vpay.transfer(msg.sender, returnAmount);
        
        emit Withdrawn(msg.sender, returnAmount, penalty);
    }

    /// @notice Processes fees from Vault. Only callable by FEE_PROCESSOR_ROLE.
    function processFees(uint256 amount) external onlyRole(FEE_PROCESSOR_ROLE) nonReentrant {
        require(usdc.transferFrom(msg.sender, address(this), amount), "Transfer failed");
        uint256 stakerShare = (amount * REWARD_PERCENT) / 100;
        emit FeesProcessed(stakerShare, amount - stakerShare);
    }
}
