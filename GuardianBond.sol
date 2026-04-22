// SPDX-License-Identifier: VPAY-1.0
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./interfaces/ISovereignToken.sol";

interface IArbitrationChamber {
    function isResolutionValid(uint256 _disputeId) external view returns (bool, address);
}

/**
 * @title GuardianBond (v2 — $SOV + Partial Slashing)
 * @author ANO-YOOFI-AGYEI
 * @notice Bond deposit system for Guardians in VPAY Genesis.
 *
 *         v2 adds: $SOV bond deposits (in addition to ETH), partial slashing,
 *         timelock withdrawal, and ReentrancyGuard protection.
 *
 *         Guardians must bond to participate in network governance.
 *         Bonds can be slashed by the Arbitration Chamber for misbehavior.
 */
contract GuardianBond is AccessControl, ReentrancyGuard {
    bytes32 public constant ARBITRATOR_ROLE = keccak256("ARBITRATOR_ROLE");

    ISovereignToken public immutable sovToken;
    IArbitrationChamber public immutable chamber;

    /// @notice Minimum bond in $SOV (18 decimals). Default: 1000 SOV.
    uint256 public minBondSov = 1000e18;

    /// @notice Withdrawal timelock period.
    uint256 public constant WITHDRAWAL_DELAY = 7 days;

    // ════════════════════════════════════════
    // STATE
    // ════════════════════════════════════════

    struct Bond {
        uint256 ethAmount;
        uint256 sovAmount;
        uint256 withdrawRequestTime; // 0 = no pending withdrawal
        bool isActive;
    }

    mapping(address => Bond) public bonds;
    uint256 public totalBondedEth;
    uint256 public totalBondedSov;
    uint256 public activeGuardians;

    // ════════════════════════════════════════
    // EVENTS
    // ════════════════════════════════════════

    event BondDeposited(address indexed guardian, uint256 ethAmount, uint256 sovAmount);
    event WithdrawalRequested(address indexed guardian, uint256 unlockTime);
    event BondWithdrawn(address indexed guardian, uint256 ethAmount, uint256 sovAmount);
    event BondSlashed(address indexed guardian, address indexed recipient, uint256 ethSlashed, uint256 sovSlashed, uint256 slashBps);

    // ════════════════════════════════════════
    // CONSTRUCTOR
    // ════════════════════════════════════════

    /**
     * @param _sovToken SovereignToken ($SOV) contract.
     * @param _chamber Arbitration Chamber contract.
     */
    constructor(address _sovToken, address _chamber) {
        sovToken = ISovereignToken(_sovToken);
        chamber = IArbitrationChamber(_chamber);
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ARBITRATOR_ROLE, _chamber);
    }

    // ════════════════════════════════════════
    // DEPOSIT
    // ════════════════════════════════════════

    /**
     * @notice Deposit ETH and/or $SOV as guardian bond.
     * @param _sovAmount Amount of $SOV to bond (must have approved this contract).
     */
    function depositBond(uint256 _sovAmount) external payable nonReentrant {
        require(msg.value > 0 || _sovAmount > 0, "Zero deposit");
        require(_sovAmount >= minBondSov, "Below minimum bond");

        Bond storage bond = bonds[msg.sender];

        if (!bond.isActive) {
            bond.isActive = true;
            activeGuardians++;
        }

        // Reset any pending withdrawal
        bond.withdrawRequestTime = 0;

        if (msg.value > 0) {
            bond.ethAmount += msg.value;
            totalBondedEth += msg.value;
        }

        if (_sovAmount > 0) {
            bond.sovAmount += _sovAmount;
            totalBondedSov += _sovAmount;
            bool success = sovToken.transferFrom(msg.sender, address(this), _sovAmount);
            require(success, "SOV transfer failed");
        }

        emit BondDeposited(msg.sender, msg.value, _sovAmount);
    }

    // ════════════════════════════════════════
    // WITHDRAWAL (Timelocked)
    // ════════════════════════════════════════

    /**
     * @notice Request withdrawal — starts the timelock.
     */
    function requestWithdrawal() external {
        Bond storage bond = bonds[msg.sender];
        require(bond.isActive, "No active bond");
        bond.withdrawRequestTime = block.timestamp;
        emit WithdrawalRequested(msg.sender, block.timestamp + WITHDRAWAL_DELAY);
    }

    /**
     * @notice Complete withdrawal after timelock expires.
     */
    function withdraw() external nonReentrant {
        Bond storage bond = bonds[msg.sender];
        require(bond.isActive, "No active bond");
        require(bond.withdrawRequestTime > 0, "No withdrawal requested");
        require(block.timestamp >= bond.withdrawRequestTime + WITHDRAWAL_DELAY, "Timelock active");

        uint256 ethAmount = bond.ethAmount;
        uint256 sovAmount = bond.sovAmount;

        // Effects
        bond.ethAmount = 0;
        bond.sovAmount = 0;
        bond.isActive = false;
        bond.withdrawRequestTime = 0;
        totalBondedEth -= ethAmount;
        totalBondedSov -= sovAmount;
        activeGuardians--;

        // Interactions
        if (ethAmount > 0) {
            (bool success, ) = payable(msg.sender).call{value: ethAmount}("");
            require(success, "ETH transfer failed");
        }
        if (sovAmount > 0) {
            bool success = sovToken.transfer(msg.sender, sovAmount);
            require(success, "SOV transfer failed");
        }

        emit BondWithdrawn(msg.sender, ethAmount, sovAmount);
    }

    // ════════════════════════════════════════
    // SLASHING
    // ════════════════════════════════════════

    /**
     * @notice Slash a guardian's bond (partial or full).
     *         Only callable by the Arbitration Chamber.
     *
     * @param _guardian Guardian to slash.
     * @param _recipient Recipient of slashed funds.
     * @param _slashBps Percentage to slash in basis points (10000 = 100%).
     */
    function slash(
        address _guardian,
        address _recipient,
        uint256 _slashBps
    ) external onlyRole(ARBITRATOR_ROLE) nonReentrant {
        require(_slashBps > 0 && _slashBps <= 10000, "Invalid slash bps");
        Bond storage bond = bonds[_guardian];
        require(bond.isActive, "No active bond");

        uint256 ethSlash = (bond.ethAmount * _slashBps) / 10000;
        uint256 sovSlash = (bond.sovAmount * _slashBps) / 10000;

        // Effects
        bond.ethAmount -= ethSlash;
        bond.sovAmount -= sovSlash;
        totalBondedEth -= ethSlash;
        totalBondedSov -= sovSlash;

        // Cancel any pending withdrawal
        bond.withdrawRequestTime = 0;

        // If fully slashed, deactivate
        if (bond.ethAmount == 0 && bond.sovAmount == 0) {
            bond.isActive = false;
            activeGuardians--;
        }

        // Interactions
        if (ethSlash > 0) {
            (bool success, ) = payable(_recipient).call{value: ethSlash}("");
            require(success, "ETH transfer failed");
        }
        if (sovSlash > 0) {
            // Burn slashed $SOV (deflationary) rather than transfer
            sovToken.burn(sovSlash);
        }

        emit BondSlashed(_guardian, _recipient, ethSlash, sovSlash, _slashBps);
    }

    // ════════════════════════════════════════
    // ADMIN
    // ════════════════════════════════════════

    function setMinBondSov(uint256 _amount) external onlyRole(DEFAULT_ADMIN_ROLE) {
        minBondSov = _amount;
    }

    // ════════════════════════════════════════
    // VIEW
    // ════════════════════════════════════════

    function getBond(address _guardian) external view returns (
        uint256 ethAmount,
        uint256 sovAmount,
        bool isActive,
        uint256 withdrawUnlockTime
    ) {
        Bond storage bond = bonds[_guardian];
        ethAmount = bond.ethAmount;
        sovAmount = bond.sovAmount;
        isActive = bond.isActive;
        withdrawUnlockTime = bond.withdrawRequestTime > 0
            ? bond.withdrawRequestTime + WITHDRAWAL_DELAY
            : 0;
    }

    function meetsMinBond(address _guardian) external view returns (bool) {
        return bonds[_guardian].sovAmount >= minBondSov;
    }
}
