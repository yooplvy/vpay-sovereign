// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "./VPAYToken.sol";

/**
 * @title StakingModule V2.5
 * @notice Production Staking with push-based fee accounting.
 * @dev Fee flow: VPAYVault pushes USDC here via safeTransfer, then calls notifyFees().
 *      notifyFees() MUST NOT pull again — it only updates internal accounting.
 */
contract StakingModule is AccessControl, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;
    using SafeERC20 for VPAYToken;

    IERC20    public immutable usdc;
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

    /// @dev Tracks pending USDC rewards claimable by stakers (rewardPerToken pattern).
    uint256 public rewardPerTokenStored;
    uint256 public lastUpdateTime;
    uint256 public rewardRate; // USDC per second distributed to stakers
    mapping(address => uint256) public userRewardPerTokenPaid;
    mapping(address => uint256) public rewards;

    constructor(address _usdc, address _vpay) {
        usdc = IERC20(_usdc);
        vpay = VPAYToken(_vpay);
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(FEE_PROCESSOR_ROLE, msg.sender);
        // TODO (mainnet): transfer DEFAULT_ADMIN_ROLE to Gnosis Safe
    }

    // ── Admin ──────────────────────────────────────────────────────────────────

    function pause()   external onlyRole(DEFAULT_ADMIN_ROLE) { _pause(); }
    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) { _unpause(); }

    // ── Reward accounting ──────────────────────────────────────────────────────

    modifier updateReward(address account) {
        rewardPerTokenStored = rewardPerToken();
        lastUpdateTime = block.timestamp;
        if (account != address(0)) {
            rewards[account] = earned(account);
            userRewardPerTokenPaid[account] = rewardPerTokenStored;
        }
        _;
    }

    function rewardPerToken() public view returns (uint256) {
        if (totalStaked == 0) return rewardPerTokenStored;
        return rewardPerTokenStored +
            (rewardRate * (block.timestamp - lastUpdateTime) * 1e18) / totalStaked;
    }

    function earned(address account) public view returns (uint256) {
        return (stakes[account].amount *
            (rewardPerToken() - userRewardPerTokenPaid[account])) / 1e18 + rewards[account];
    }

    // ── Core ───────────────────────────────────────────────────────────────────

    function stake(uint256 amount, uint256 lockDays) external nonReentrant whenNotPaused updateReward(msg.sender) {
        require(lockDays >= MIN_LOCK_DAYS, "Lock duration too short");
        require(stakes[msg.sender].amount == 0, "Unstake first");

        vpay.safeTransferFrom(msg.sender, address(this), amount);

        uint256 lockEnd = block.timestamp + (lockDays * 1 days);
        stakes[msg.sender] = StakeInfo({ amount: amount, lockEnd: lockEnd, startTime: block.timestamp });
        totalStaked += amount;
        emit Staked(msg.sender, amount, lockEnd);
    }

    function withdraw() external nonReentrant whenNotPaused updateReward(msg.sender) {
        StakeInfo storage userStake = stakes[msg.sender];
        require(userStake.amount > 0, "No stake found");

        uint256 amount  = userStake.amount;
        uint256 penalty = 0;
        if (block.timestamp < userStake.lockEnd) {
            penalty = (amount * PENALTY_PERCENT) / 100;
            vpay.burn(penalty);
        }

        uint256 returnAmount = amount - penalty;
        delete stakes[msg.sender];
        totalStaked -= amount;

        vpay.safeTransfer(msg.sender, returnAmount);
        emit Withdrawn(msg.sender, returnAmount, penalty);
    }

    function claimRewards() external nonReentrant whenNotPaused updateReward(msg.sender) {
        uint256 reward = rewards[msg.sender];
        require(reward > 0, "Nothing to claim");
        rewards[msg.sender] = 0;
        usdc.safeTransfer(msg.sender, reward);
    }

    /// @notice Called by VPAYVault AFTER it has already pushed USDC here via safeTransfer.
    /// @dev MUST NOT pull tokens again — only updates reward rate accounting.
    ///      Bug fix v2.5: previous processFees() called transferFrom(), causing double debit.
    function notifyFees(uint256 amount) external onlyRole(FEE_PROCESSOR_ROLE) updateReward(address(0)) {
        uint256 stakerShare = (amount * REWARD_PERCENT) / 100;
        // Distribute staker share as continuous reward over 7 days
        if (totalStaked > 0) {
            rewardRate = stakerShare / 7 days;
        }
        // Remaining buyback share sits in contract — admin triggers buyback separately
        emit FeesProcessed(stakerShare, amount - stakerShare);
    }
}
