// SPDX-License-Identifier: VPAY-1.0
// @title VPAYVault (Production v5.1)
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./SovereignNode.sol";
import "./StakingModule.sol";
import "./OracleTriad.sol";

error VAULT__NotOwner();
error VAULT__NotSealed();
error VAULT__StaleAttestation();
error VAULT__InsufficientCollateral();
error VAULT__LoanActive();
error VAULT__NoActiveLoan();
error VAULT__LoanNotExpired();
error VAULT__LoanStillHealthy();

/// @notice IMPORTANT: DEFAULT_ADMIN_ROLE must be transferred to a Gnosis Safe
/// multi-sig immediately after deployment. Single-EOA admin is not acceptable
/// for mainnet. Use: _grantRole(DEFAULT_ADMIN_ROLE, gnosisSafe);
///                    _revokeRole(DEFAULT_ADMIN_ROLE, deployerEOA);
contract VPAYVault is AccessControl, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    SovereignNode public immutable node;
    IERC20        public immutable stablecoin;
    OracleTriad   public goldOracle;
    StakingModule public stakingModule;

    uint256 public constant MAX_LTV              = 60;  // 60% — must match contracts.js
    uint256 public constant LIQUIDATION_THRESHOLD = 75; // 75% LTV — position is liquidatable
    uint256 public constant ATTESTATION_TTL       = 1 hours;
    uint256 public constant LIQUIDATION_PENALTY   = 8;  // 8% penalty on liquidation

    address public treasury;
    uint256 public originationFee = 50; // bps (0.50%)

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
    event LiquidationExecuted(bytes32 indexed nodeId, address indexed liquidator, uint256 seizedCollateralMass, string reason);
    event TreasuryUpdated(address indexed newTreasury);
    event OracleUpdated(address indexed newOracle);

    constructor(address _node, address _stablecoin, address _treasury, address _oracleTriad) {
        node       = SovereignNode(_node);
        stablecoin = IERC20(_stablecoin);
        treasury   = _treasury;
        goldOracle = OracleTriad(_oracleTriad);
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        // TODO (mainnet): immediately transfer DEFAULT_ADMIN_ROLE to Gnosis Safe
    }

    // ── Admin ──────────────────────────────────────────────────────────────────

    function pause()   external onlyRole(DEFAULT_ADMIN_ROLE) { _pause(); }
    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) { _unpause(); }

    function setStakingModule(address _module) external onlyRole(DEFAULT_ADMIN_ROLE) {
        stakingModule = StakingModule(_module);
    }

    function setTreasury(address _treasury) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_treasury != address(0), "Zero address");
        treasury = _treasury;
        emit TreasuryUpdated(_treasury);
    }

    function setOracle(address _oracle) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_oracle != address(0), "Zero address");
        goldOracle = OracleTriad(_oracle);
        emit OracleUpdated(_oracle);
    }

    // ── Views ──────────────────────────────────────────────────────────────────

    function getGoldPrice() public view returns (uint256) {
        return goldOracle.getSafePrice();
    }

    function repaymentDue(bytes32 _nodeId) external view returns (uint256) {
        return loans[_nodeId].amount;
    }

    /// @notice Health factor in 1e4 precision. < 10000 = liquidatable.
    /// Example: 13000 = 1.30x (healthy), 9500 = 0.95x (liquidatable).
    function getHealthFactor(bytes32 _nodeId) public view returns (uint256) {
        Loan storage loan = loans[_nodeId];
        if (!loan.isActive || loan.amount == 0) return type(uint256).max;
        uint256 collateralValueUSDC = (uint256(loan.collateralMass) * getGoldPrice()) / 1e12;
        // health = (collateralValue * liquidationThreshold / 100) / debt  expressed in 1e4
        return (collateralValueUSDC * LIQUIDATION_THRESHOLD * 1e4) / (100 * loan.amount);
    }

    // ── Core Protocol ──────────────────────────────────────────────────────────

    function lockAndBorrow(
        bytes32 _nodeId,
        uint256 _amount,
        uint256 _durationDays
    ) external nonReentrant whenNotPaused {
        if (node.nodeOwners(_nodeId) != msg.sender) revert VAULT__NotOwner();
        if (loans[_nodeId].isActive)                revert VAULT__LoanActive();

        SovereignNode.Attestation memory att = node.getAttestation(_nodeId);
        if (block.timestamp - att.timestamp > ATTESTATION_TTL) revert VAULT__StaleAttestation();
        if (!att.isSealed)                                       revert VAULT__NotSealed();

        uint256 goldPrice = getGoldPrice();
        // Oracle: 18-decimal $/kg. Stablecoin: 6-decimal USDC. Divide by 1e12.
        uint256 collateralValue = (uint256(att.massKg) * goldPrice) / 1e12;
        uint256 maxBorrow = (collateralValue * MAX_LTV) / 100;
        if (_amount > maxBorrow) revert VAULT__InsufficientCollateral();

        loans[_nodeId] = Loan({
            amount:        _amount,
            collateralMass: att.massKg,
            startTime:     block.timestamp,
            expiry:        block.timestamp + (_durationDays * 1 days),
            isActive:      true,
            nodeId:        _nodeId
        });

        uint256 fee    = (_amount * originationFee) / 10000;
        uint256 payout = _amount - fee;

        // Checks-Effects-Interactions: state already written above — safe to call out
        stablecoin.safeTransfer(msg.sender, payout);
        if (fee > 0) {
            if (address(stakingModule) != address(0)) {
                // Push fee to StakingModule then notify (no second pull needed)
                stablecoin.safeTransfer(address(stakingModule), fee);
                stakingModule.notifyFees(fee);
            } else {
                stablecoin.safeTransfer(treasury, fee);
            }
        }

        emit LoanIssued(_nodeId, msg.sender, payout, fee);
    }

    function repayLoan(bytes32 _nodeId) external nonReentrant whenNotPaused {
        if (node.nodeOwners(_nodeId) != msg.sender) revert VAULT__NotOwner();
        if (!loans[_nodeId].isActive)               revert VAULT__NoActiveLoan();

        Loan storage loan = loans[_nodeId];
        uint256 repayAmount = loan.amount;
        loan.isActive = false; // effect before interaction

        stablecoin.safeTransferFrom(msg.sender, address(this), repayAmount);
        emit LoanRepaid(_nodeId);
    }

    /// @notice Liquidate an expired loan (past due date).
    function liquidateExpired(bytes32 _nodeId) external nonReentrant whenNotPaused {
        Loan storage loan = loans[_nodeId];
        if (!loan.isActive)                    revert VAULT__NoActiveLoan();
        if (block.timestamp <= loan.expiry)    revert VAULT__LoanNotExpired();

        uint256 payoff = (loan.amount * (100 + LIQUIDATION_PENALTY)) / 100;
        uint256 mass   = loan.collateralMass;
        loan.isActive  = false; // effect before interaction

        stablecoin.safeTransferFrom(msg.sender, address(this), payoff);
        node.transferNode(_nodeId, msg.sender);
        emit LiquidationExecuted(_nodeId, msg.sender, mass, "EXPIRED");
    }

    /// @notice Liquidate an undercollateralized loan (health factor < 1.0).
    /// Anyone can call this to keep the protocol solvent.
    function liquidateUndercollateralized(bytes32 _nodeId) external nonReentrant whenNotPaused {
        Loan storage loan = loans[_nodeId];
        if (!loan.isActive) revert VAULT__NoActiveLoan();
        // Health factor < 10000 means collateral value has fallen below liquidation threshold
        if (getHealthFactor(_nodeId) >= 10000) revert VAULT__LoanStillHealthy();

        uint256 payoff = (loan.amount * (100 + LIQUIDATION_PENALTY)) / 100;
        uint256 mass   = loan.collateralMass;
        loan.isActive  = false; // effect before interaction

        stablecoin.safeTransferFrom(msg.sender, address(this), payoff);
        node.transferNode(_nodeId, msg.sender);
        emit LiquidationExecuted(_nodeId, msg.sender, mass, "UNDERCOLLATERALIZED");
    }
}
