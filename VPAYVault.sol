// SPDX-License-Identifier: VPAY-1.0
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./SovereignNode.sol";
import "./interfaces/ISovereignToken.sol";
import "./interfaces/ICircuitBreaker.sol";

error VAULT__LoanActive();
error VAULT__NoActiveLoan();
error VAULT__InsufficientCollateral();
error VAULT__TransferFailed();
error VAULT__InvalidAmount();
error VAULT__TermExceeded();
error VAULT__SealCompromised();
error VAULT__LoanExpired();
error VAULT__Paused();
error VAULT__StaleAttestation();

/**
 * @title VPAYVault (v2 — Integrated)
 * @author ANO-YOOFI-AGYEI
 * @notice Gold-collateralized lending vault for VPAY Genesis.
 *
 *         v2 adds: ISovereignToken ($SOV) integration for interest payments,
 *         CircuitBreaker pause checks, attestation staleness validation,
 *         and improved collateral calculation with configurable parameters.
 *
 *         Follows Checks-Effects-Interactions pattern throughout.
 */
contract VPAYVault is AccessControl, ReentrancyGuard {
    string public constant ARCHITECT = "ANO-YOOFI-AGYEI";
    string public constant PROTOCOL_ID = "VPAY-GENESIS-v2.0";

    bytes32 public constant ORACLE_ROLE = keccak256("ORACLE_ROLE");

    // ════════════════════════════════════════
    // EXTERNAL CONTRACTS
    // ════════════════════════════════════════

    IERC20 public immutable stablecoin;
    SovereignNode public immutable sovereignNode;
    ISovereignToken public immutable sovToken;
    ICircuitBreaker public circuitBreaker;

    // ════════════════════════════════════════
    // CONFIGURATION
    // ════════════════════════════════════════

    /// @notice Gold price in cents per kilogram ($57,000/kg = 5_700_000 cents).
    uint256 public goldPriceCents = 5_700_000;

    /// @notice Timestamp of last gold price update (for freshness validation).
    uint256 public lastPriceUpdate;

    /// @notice Loan-to-value ratio in basis points (7000 = 70%).
    uint256 public constant LTV_BPS = 7000;

    /// @notice Maximum loan term in days.
    uint256 public constant MAX_TERM_DAYS = 90;

    /// @notice Minimum collateralization ratio in bps (15000 = 150%).
    uint256 public constant MIN_COLLATERAL_BPS = 15000;

    /// @notice Liquidation threshold in bps (12000 = 120%).
    uint256 public constant LIQUIDATION_THRESHOLD_BPS = 12000;

    /// @notice Maximum attestation age before considered stale (24 hours).
    uint256 public constant MAX_ATTESTATION_AGE = 24 hours;

    /// @notice Interest rate in basis points per day (10 = 0.10%/day).
    uint256 public interestRateBpsPerDay = 10;

    // ════════════════════════════════════════
    // DATA STRUCTURES
    // ════════════════════════════════════════

    struct Loan {
        uint256 amount;         // Stablecoin borrowed (6 decimals)
        uint256 collateralGrams; // Gold collateral in grams
        uint256 purityBps;      // Purity at time of loan creation
        uint32 termDays;        // Loan term
        uint64 startTime;       // Timestamp
        bool isActive;
    }

    struct CachedAttestation {
        uint256 massGrams;
        uint256 purityBps;
        uint256 tempCE2;
        uint64 timestamp;
        bool sealIntact;
    }

    // ════════════════════════════════════════
    // STATE
    // ════════════════════════════════════════

    mapping(bytes32 => Loan) public loans;
    mapping(bytes32 => CachedAttestation) public latestAttestation;

    uint256 public totalLoansIssued;
    uint256 public totalCollateralLocked; // In grams
    uint256 public totalInterestAccrued;  // In $SOV

    // ════════════════════════════════════════
    // EVENTS
    // ════════════════════════════════════════

    event LoanCreated(bytes32 indexed nodeId, uint256 amount, uint256 collateralGrams, uint256 purityBps, uint32 termDays);
    event LoanRepaid(bytes32 indexed nodeId, uint256 amount, uint256 interestSov);
    event LoanLiquidated(bytes32 indexed nodeId, uint256 collateralSeized, uint256 reason);
    event CollateralSeized(bytes32 indexed nodeId, uint256 amount);
    event GoldPriceUpdated(uint256 newPrice);
    event AttestationUpdated(bytes32 indexed nodeId, uint256 massGrams, uint256 purityBps);

    // ════════════════════════════════════════
    // CONSTRUCTOR
    // ════════════════════════════════════════

    /**
     * @param _stablecoin Stablecoin contract (e.g., USDC on Polygon).
     * @param _sovereignNode SovereignNode v2 contract.
     * @param _sovToken SovereignToken ($SOV) at 0x5833ABF0Ecfe61e85682F3720BA4d636084e0eC0.
     * @param _circuitBreaker CircuitBreaker contract.
     */
    constructor(
        address _stablecoin,
        address _sovereignNode,
        address _sovToken,
        address _circuitBreaker
    ) {
        stablecoin = IERC20(_stablecoin);
        sovereignNode = SovereignNode(_sovereignNode);
        sovToken = ISovereignToken(_sovToken);
        circuitBreaker = ICircuitBreaker(_circuitBreaker);
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ORACLE_ROLE, msg.sender);
    }

    // ════════════════════════════════════════
    // MODIFIERS
    // ════════════════════════════════════════

    modifier whenNotPaused(bytes32 _nodeId) {
        if (circuitBreaker.globalPaused()) revert VAULT__Paused();
        if (circuitBreaker.nodePaused(_nodeId)) revert VAULT__Paused();
        _;
    }

    // ════════════════════════════════════════
    // LENDING — LOCK & BORROW
    // ════════════════════════════════════════

    /**
     * @notice Lock gold collateral verified by a GSU node and borrow stablecoin.
     *         Enforces: fresh attestation, seal integrity, 150% over-collateralization.
     *
     * @param _nodeId The GSU node holding the gold.
     * @param _amount Stablecoin amount to borrow (6 decimal precision).
     * @param _termDays Loan term (max 90 days).
     */
    function lockAndBorrow(
        bytes32 _nodeId,
        uint256 _amount,
        uint32 _termDays
    ) external nonReentrant whenNotPaused(_nodeId) {
        // ── CHECKS ──
        if (_amount == 0) revert VAULT__InvalidAmount();
        if (_termDays > MAX_TERM_DAYS) revert VAULT__TermExceeded();
        if (loans[_nodeId].isActive) revert VAULT__LoanActive();

        // Verify node is active on SovereignNode contract
        require(sovereignNode.isNodeActive(_nodeId), "Node not verified");

        // Get cached attestation — must be fresh and seal intact
        CachedAttestation storage att = latestAttestation[_nodeId];
        require(att.massGrams > 0, "No attestation available");
        if (!att.sealIntact) revert VAULT__SealCompromised();
        if (block.timestamp - att.timestamp > MAX_ATTESTATION_AGE) revert VAULT__StaleAttestation();

        // Check oracle freshness: price must be updated within 24 hours
        if (lastPriceUpdate > 0) {
            require(block.timestamp - lastPriceUpdate <= 24 hours, "Price feed stale");
        }

        // Collateral value check: 150% over-collateralization
        // Add overflow protection: ensure multiplication won't overflow
        require(goldPriceCents <= type(uint256).max / (att.massGrams * att.purityBps), "Collateral calc overflow");
        uint256 collateralValueCents = (att.massGrams * att.purityBps * goldPriceCents) / (10000 * 1000);
        // Convert collateral to stablecoin decimals (6) for comparison
        uint256 collateralValueStable = (collateralValueCents * 1e4); // cents → 6-decimal stablecoin
        uint256 minRequired = (_amount * MIN_COLLATERAL_BPS) / 10000;

        if (collateralValueStable < minRequired) revert VAULT__InsufficientCollateral();

        // ── EFFECTS ──
        loans[_nodeId] = Loan({
            amount: _amount,
            collateralGrams: att.massGrams,
            purityBps: att.purityBps,
            termDays: _termDays,
            startTime: uint64(block.timestamp),
            isActive: true
        });

        totalLoansIssued++;
        totalCollateralLocked += att.massGrams;

        // ── INTERACTIONS ──
        bool success = stablecoin.transfer(msg.sender, _amount);
        if (!success) revert VAULT__TransferFailed();

        emit LoanCreated(_nodeId, _amount, att.massGrams, att.purityBps, _termDays);
    }

    /**
     * @notice Repay loan + interest (interest paid in $SOV) and unlock collateral.
     * @param _nodeId The node whose loan is being repaid.
     */
    function repay(bytes32 _nodeId) external nonReentrant whenNotPaused(_nodeId) {
        // ── CHECKS ──
        Loan storage loan = loans[_nodeId];
        if (!loan.isActive) revert VAULT__NoActiveLoan();

        CachedAttestation storage att = latestAttestation[_nodeId];
        if (!att.sealIntact) revert VAULT__SealCompromised();
        if (_isExpired(loan)) revert VAULT__LoanExpired();

        uint256 repayAmount = loan.amount;
        uint256 interestSov = _calculateInterestSov(loan);

        // ── EFFECTS ──
        loan.isActive = false;
        totalCollateralLocked -= loan.collateralGrams;
        totalInterestAccrued += interestSov;

        // ── INTERACTIONS ──
        // 1. Repay stablecoin principal
        bool success = stablecoin.transferFrom(msg.sender, address(this), repayAmount);
        if (!success) revert VAULT__TransferFailed();

        // 2. Pay interest in $SOV (burned — deflationary)
        if (interestSov > 0) {
            sovToken.burnFrom(msg.sender, interestSov);
        }

        emit LoanRepaid(_nodeId, repayAmount, interestSov);
    }

    /**
     * @notice Liquidate a loan — triggered by expiry, seal breach, or collateral drop.
     * @param _nodeId The node whose loan should be liquidated.
     */
    function liquidate(bytes32 _nodeId) external nonReentrant {
        Loan storage loan = loans[_nodeId];
        if (!loan.isActive) revert VAULT__NoActiveLoan();

        CachedAttestation storage att = latestAttestation[_nodeId];

        // Check oracle freshness for price-based liquidation
        if (lastPriceUpdate > 0) {
            require(block.timestamp - lastPriceUpdate <= 24 hours, "Price feed stale");
        }

        // Check liquidation triggers
        bool expired = _isExpired(loan);
        bool sealBreach = !att.sealIntact;
        bool underCollateralized = false;

        if (att.massGrams > 0) {
            uint256 collateralValueCents = (att.massGrams * att.purityBps * goldPriceCents) / (10000 * 1000);
            uint256 collateralValueStable = collateralValueCents * 1e4;
            uint256 threshold = (loan.amount * LIQUIDATION_THRESHOLD_BPS) / 10000;
            underCollateralized = collateralValueStable < threshold;
        }

        require(expired || sealBreach || underCollateralized, "No liquidation trigger");

        uint256 collateralSeized = loan.collateralGrams;
        uint256 reason = expired ? 1 : (sealBreach ? 2 : 3);

        // ── EFFECTS ──
        loan.isActive = false;
        totalCollateralLocked -= collateralSeized;

        emit LoanLiquidated(_nodeId, collateralSeized, reason);
        emit CollateralSeized(_nodeId, collateralSeized);
    }

    // ════════════════════════════════════════
    // ORACLE FUNCTIONS
    // ════════════════════════════════════════

    /**
     * @notice Update cached attestation data for a node.
     *         Called by the oracle service that reads from SovereignNode events.
     */
    function updateAttestation(
        bytes32 _nodeId,
        uint256 _massGrams,
        uint256 _purityBps,
        uint256 _tempCE2,
        bool _sealIntact
    ) external onlyRole(ORACLE_ROLE) {
        require(_massGrams > 0, "Invalid mass");
        require(_purityBps > 0 && _purityBps <= 10000, "Invalid purity");

        latestAttestation[_nodeId] = CachedAttestation({
            massGrams: _massGrams,
            purityBps: _purityBps,
            tempCE2: _tempCE2,
            timestamp: uint64(block.timestamp),
            sealIntact: _sealIntact
        });

        emit AttestationUpdated(_nodeId, _massGrams, _purityBps);
    }

    /**
     * @notice Update gold price (oracle).
     */
    function updateGoldPrice(uint256 _newPrice) external onlyRole(ORACLE_ROLE) {
        require(_newPrice > 0, "Invalid price");
        goldPriceCents = _newPrice;
        lastPriceUpdate = block.timestamp;
        emit GoldPriceUpdated(_newPrice);
    }

    /**
     * @notice Update interest rate (admin).
     */
    function setInterestRate(uint256 _bpsPerDay) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_bpsPerDay <= 100, "Rate too high"); // Max 1%/day
        interestRateBpsPerDay = _bpsPerDay;
    }

    // ════════════════════════════════════════
    // VIEW FUNCTIONS
    // ════════════════════════════════════════

    function isExpired(bytes32 _nodeId) public view returns (bool) {
        return _isExpired(loans[_nodeId]);
    }

    function getAccruedInterest(bytes32 _nodeId) external view returns (uint256) {
        return _calculateInterestSov(loans[_nodeId]);
    }

    // ════════════════════════════════════════
    // INTERNAL
    // ════════════════════════════════════════

    function _isExpired(Loan storage loan) internal view returns (bool) {
        if (!loan.isActive) return false;
        return block.timestamp > loan.startTime + (uint256(loan.termDays) * 1 days);
    }

    /**
     * @notice Calculate interest owed in $SOV tokens.
     *         Interest = principal × rate × days elapsed.
     *         Returned in 18-decimal $SOV units.
     */
    function _calculateInterestSov(Loan storage loan) internal view returns (uint256) {
        if (!loan.isActive) return 0;
        uint256 daysElapsed = (block.timestamp - loan.startTime) / 1 days;
        if (daysElapsed == 0) daysElapsed = 1; // Minimum 1 day
        // interest = amount * rate * days / 10000 (bps)
        // Scale to 18 decimals ($SOV) from 6 decimals (stablecoin)
        return (loan.amount * interestRateBpsPerDay * daysElapsed * 1e12) / 10000;
    }
}
