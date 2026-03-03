// SPDX-License-Identifier: VPAY-1.0
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./SovereignNode.sol";
import "./StakingModule.sol";
import "./OracleTriad.sol";

error VAULT__NotOwner();
error VAULT__NotSealed();
error VAULT__StaleAttestation();
error VAULT__InsufficientCollateral();
error VAULT__LoanActive();
error VAULT__TransferFailed();
error VAULT__LoanNotExpired();

contract VPAYVault is AccessControl, ReentrancyGuard {
    
    SovereignNode public immutable node;
    IERC20 public immutable stablecoin;
    OracleTriad public goldOracle;
    StakingModule public stakingModule; 
    
    uint256 public constant MAX_LTV = 60; 
    uint256 public constant ATTESTATION_TTL = 1 hours;
    uint256 public constant LIQUIDATION_PENALTY = 5;
    
    address public treasury;
    uint256 public originationFee = 50;

    struct Loan {
        uint256 amount;
        uint256 collateralMass;
        uint256 startTime;
        uint256 expiry;
        bool isActive;
        bytes32 nodeId;
    }

    mapping(bytes32 => Loan) public loans;

    event LoanIssued(bytes32 indexed nodeId, address indexed borrower, uint256 amount, uint256 fee);
    event LoanRepaid(bytes32 indexed nodeId);
    event LiquidationExecuted(bytes32 indexed nodeId, address indexed liquidator, uint256 seizedAmount);

    constructor(address _node, address _stablecoin, address _treasury, address _oracleTriad) {
        node = SovereignNode(_node);
        stablecoin = IERC20(_stablecoin);
        treasury = _treasury;
        goldOracle = OracleTriad(_oracleTriad);
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    function setStakingModule(address _module) external onlyRole(DEFAULT_ADMIN_ROLE) {
        stakingModule = StakingModule(_module);
    }

    function getGoldPrice() public view returns (uint256) {
        return goldOracle.getSafePrice();
    }

    function lockAndBorrow(bytes32 _nodeId, uint256 _amount, uint256 _durationDays) external nonReentrant {
        if (node.nodeOwners(_nodeId) != msg.sender) revert VAULT__NotOwner();
        if (loans[_nodeId].isActive) revert VAULT__LoanActive();

        SovereignNode.Attestation memory att = node.getAttestation(_nodeId);
        if (block.timestamp - att.timestamp > ATTESTATION_TTL) revert VAULT__StaleAttestation();
        if (!att.isSealed) revert VAULT__NotSealed();
        
        uint256 goldPrice = getGoldPrice();
        uint256 collateralValue = (uint256(att.massKg) * goldPrice) / 1e18;
        uint256 maxBorrow = (collateralValue * MAX_LTV) / 100;
        if (_amount > maxBorrow) revert VAULT__InsufficientCollateral();

        loans[_nodeId] = Loan({
            amount: _amount,
            collateralMass: att.massKg,
            startTime: block.timestamp,
            expiry: block.timestamp + (_durationDays * 1 days),
            isActive: true,
            nodeId: _nodeId
        });

        uint256 fee = (_amount * originationFee) / 10000;
        uint256 payout = _amount - fee;

        bool successUser = stablecoin.transfer(msg.sender, payout);
        if (!successUser) revert VAULT__TransferFailed();
        
        if (fee > 0) {
            if (address(stakingModule) != address(0)) {
                bool successFee = stablecoin.transfer(address(stakingModule), fee);
                if (!successFee) revert VAULT__TransferFailed();
                stakingModule.processFees(fee);
            } else {
                stablecoin.transfer(treasury, fee);
            }
        }

        emit LoanIssued(_nodeId, msg.sender, payout, fee);
    }

    function repayLoan(bytes32 _nodeId) external nonReentrant {
        if (node.nodeOwners(_nodeId) != msg.sender) revert VAULT__NotOwner();
        require(loans[_nodeId].isActive, "No loan");

        Loan storage loan = loans[_nodeId];
        loan.isActive = false;
        
        bool success = stablecoin.transferFrom(msg.sender, address(this), loan.amount);
        if (!success) revert VAULT__TransferFailed();

        emit LoanRepaid(_nodeId);
    }

    // FIXED: Added Liquidation
    function liquidateExpired(bytes32 _nodeId) external nonReentrant {
        Loan storage loan = loans[_nodeId];
        require(loan.isActive, "No active loan");
        if (block.timestamp <= loan.expiry) revert VAULT__LoanNotExpired();

        uint256 payoff = (loan.amount * (100 + LIQUIDATION_PENALTY)) / 100;
        bool success = stablecoin.transferFrom(msg.sender, address(this), payoff);
        if (!success) revert VAULT__TransferFailed();

        loan.isActive = false;
        emit LiquidationExecuted(_nodeId, msg.sender, loan.collateralMass);
    }
}
