// SPDX-License-Identifier: VPAY-1.0
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./SovereignNode.sol";
import "./interfaces/ISovereignToken.sol";
import "./interfaces/ICircuitBreaker.sol";
import "./MinerRewards.sol";

error BRIDGE__Paused();
error BRIDGE__InvalidAttestation();
error BRIDGE__AlreadyProcessed();
error BRIDGE__BelowMinPurity();
error BRIDGE__SupplyCapReached();
error BRIDGE__SealBroken();

/**
 * @title AttestationBridge
 * @author ANO-YOOFI-AGYEI
 * @notice The "No Verification, No Token" enforcer.
 *
 *         This contract bridges the physical world (GSU attestations on SovereignNode)
 *         to the token world ($SOV minting). When a GSU submits a confirmed attestation,
 *         an authorized relayer calls confirmAndMint() here, which:
 *
 *         1. Reads the attestation from SovereignNode
 *         2. Validates purity, seal, and freshness
 *         3. Calculates the $SOV mint amount based on weight × purity
 *         4. Mints $SOV to the designated recipient
 *         5. Records the attestation as processed (no double-mint)
 *
 *         The bridge holds MINTER_ROLE on the $SOV contract.
 *         No attestation = no mint. Physics gates the token supply.
 */
contract AttestationBridge is AccessControl, ReentrancyGuard {
    string public constant ARCHITECT = "ANO-YOOFI-AGYEI";
    string public constant PROTOCOL_ID = "VPAY-GENESIS-v2.0";

    bytes32 public constant RELAYER_ROLE = keccak256("RELAYER_ROLE");

    // ════════════════════════════════════════
    // EXTERNAL CONTRACTS
    // ════════════════════════════════════════

    SovereignNode public immutable sovereignNode;
    ISovereignToken public immutable sovToken;
    ICircuitBreaker public circuitBreaker;

    // ════════════════════════════════════════
    // CONFIGURATION
    // ════════════════════════════════════════

    /// @notice Minimum purity in bps to qualify for $SOV minting (9150 = 91.50%).
    uint256 public minPurityBps = 9150;

    /// @notice Maximum attestation age to process (1 hour).
    uint256 public maxAttestationAge = 1 hours;

    /// @notice $SOV per gram of pure gold (18 decimals).
    ///         Default: 1 SOV per gram of pure gold = 1e18.
    uint256 public sovPerPureGram = 1e18;

    /// @notice Miner reward share in bps (500 = 5% of minted goes to node operator).
    uint256 public minerRewardBps = 500;

    /// @notice MinerRewards contract that receives and accounts for miner rewards.
    MinerRewards public minerRewardsContract;

    /// @notice Address that receives miner rewards (for backward compat views).
    address public minerRewardsPool;

    /// @notice Total $SOV minted through this bridge.
    uint256 public totalMinted;

    // ════════════════════════════════════════
    // STATE
    // ════════════════════════════════════════

    /// @notice Track processed attestations to prevent double-minting.
    ///         Key: keccak256(spectrumHash, timestamp, nodeId)
    mapping(bytes32 => bool) public processedAttestations;

    /// @notice Per-node mint history.
    mapping(bytes32 => uint256) public nodeMintCount;
    mapping(bytes32 => uint256) public nodeTotalMinted;

    // ════════════════════════════════════════
    // EVENTS
    // ════════════════════════════════════════

    event AttestationProcessed(
        bytes32 indexed nodeId,
        uint256 indexed attestationIndex,
        uint256 massGrams,
        uint256 purityBps,
        uint256 sovMinted,
        uint256 minerReward,
        address recipient
    );

    event MintRejected(
        bytes32 indexed nodeId,
        uint256 indexed attestationIndex,
        string reason
    );

    event ConfigUpdated(string param, uint256 value);

    // ════════════════════════════════════════
    // CONSTRUCTOR
    // ════════════════════════════════════════

    /**
     * @param _sovereignNode SovereignNode v2 contract address.
     * @param _sovToken SovereignToken ($SOV) at 0x5833ABF0E...
     * @param _circuitBreaker CircuitBreaker contract address.
     * @param _minerRewardsPool MinerRewards contract or pool address.
     */
    constructor(
        address _sovereignNode,
        address _sovToken,
        address _circuitBreaker,
        address _minerRewardsPool
    ) {
        sovereignNode = SovereignNode(_sovereignNode);
        sovToken = ISovereignToken(_sovToken);
        circuitBreaker = ICircuitBreaker(_circuitBreaker);
        minerRewardsPool = _minerRewardsPool;
        minerRewardsContract = MinerRewards(_minerRewardsPool);
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(RELAYER_ROLE, msg.sender);
    }

    // ════════════════════════════════════════
    // CORE — CONFIRM AND MINT
    // ════════════════════════════════════════

    /**
     * @notice Process a confirmed attestation and mint $SOV.
     *         This is the core "no verification, no token" function.
     *
     *         Called by an authorized relayer after observing an
     *         AttestationConfirmed event from SovereignNode.
     *
     * @param _nodeId The GSU node that submitted the attestation.
     * @param _attestationIndex The attestation index (from event).
     * @param _recipient Address to receive the minted $SOV.
     */
    function confirmAndMint(
        bytes32 _nodeId,
        uint256 _attestationIndex,
        address _recipient
    ) external onlyRole(RELAYER_ROLE) nonReentrant {
        // ── Pause check ──
        if (circuitBreaker.globalPaused()) revert BRIDGE__Paused();
        if (circuitBreaker.nodePaused(_nodeId)) revert BRIDGE__Paused();

        // ── Read attestation from SovereignNode ──
        (
            uint256 massGrams,
            uint256 purityBps,
            ,    // karatE2
            ,    // tempCE2
            bool sealIntact,
            ,    // gpsLatE6
            ,    // gpsLonE6
            ,    // gpsAccuracyDm
            bytes32 spectrumHash,
            ,    // signature
            uint64 timestamp,
            // blockNumber
        ) = sovereignNode.latestAttestation(_nodeId);

        // ── Double-mint prevention using attestation hash ──
        // Hash includes spectrumHash + timestamp + nodeId to uniquely identify the attestation
        bytes32 attestationHash = keccak256(abi.encode(spectrumHash, timestamp, _nodeId));
        if (processedAttestations[attestationHash]) revert BRIDGE__AlreadyProcessed();

        // ── Validate attestation ──
        if (massGrams == 0 || purityBps == 0) revert BRIDGE__InvalidAttestation();
        if (!sealIntact) revert BRIDGE__SealBroken();
        if (purityBps < minPurityBps) revert BRIDGE__BelowMinPurity();
        if (block.timestamp - timestamp > maxAttestationAge) revert BRIDGE__InvalidAttestation();

        // ── Calculate mint amount ──
        // SOV = (massGrams × purityBps / 10000) × sovPerPureGram / 1000
        // Dividing by 1000 to convert grams to kg-equivalent rate
        uint256 pureGoldGrams = (massGrams * purityBps) / 10000;
        uint256 sovAmount = (pureGoldGrams * sovPerPureGram) / 1000;

        // Check supply cap
        if (sovToken.totalSupply() + sovAmount > sovToken.MAX_SUPPLY()) revert BRIDGE__SupplyCapReached();

        // Calculate miner reward split
        uint256 minerReward = (sovAmount * minerRewardBps) / 10000;
        uint256 recipientAmount = sovAmount - minerReward;

        // ── Record as processed ──
        processedAttestations[attestationHash] = true;
        nodeMintCount[_nodeId]++;
        nodeTotalMinted[_nodeId] += sovAmount;
        totalMinted += sovAmount;

        // ── Mint $SOV ──
        sovToken.mint(_recipient, recipientAmount);
        if (minerReward > 0 && minerRewardsPool != address(0)) {
            sovToken.mint(minerRewardsPool, minerReward);
            // Auto-credit the operator so they can claim immediately
            // (Bridge holds DISTRIBUTOR_ROLE on MinerRewards)
            minerRewardsContract.creditReward(_nodeId, minerReward);
        }

        emit AttestationProcessed(
            _nodeId,
            _attestationIndex,
            massGrams,
            purityBps,
            sovAmount,
            minerReward,
            _recipient
        );
    }

    // ════════════════════════════════════════
    // ADMIN CONFIG
    // ════════════════════════════════════════

    function setMinPurity(uint256 _bps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_bps >= 5000 && _bps <= 10000, "Invalid range");
        minPurityBps = _bps;
        emit ConfigUpdated("minPurityBps", _bps);
    }

    function setMaxAttestationAge(uint256 _seconds) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_seconds >= 300 && _seconds <= 86400, "5min-24hr range");
        maxAttestationAge = _seconds;
        emit ConfigUpdated("maxAttestationAge", _seconds);
    }

    function setSovPerPureGram(uint256 _rate) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_rate > 0, "Invalid rate");
        sovPerPureGram = _rate;
        emit ConfigUpdated("sovPerPureGram", _rate);
    }

    function setMinerRewardBps(uint256 _bps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_bps <= 2000, "Max 20%");
        minerRewardBps = _bps;
        emit ConfigUpdated("minerRewardBps", _bps);
    }

    function setMinerRewardsPool(address _pool) external onlyRole(DEFAULT_ADMIN_ROLE) {
        minerRewardsPool = _pool;
        minerRewardsContract = MinerRewards(_pool);
    }

    function setCircuitBreaker(address _breaker) external onlyRole(DEFAULT_ADMIN_ROLE) {
        circuitBreaker = ICircuitBreaker(_breaker);
    }

    // ════════════════════════════════════════
    // VIEW
    // ════════════════════════════════════════

    /**
     * @notice Preview how much $SOV would be minted for a given mass and purity.
     */
    function previewMint(uint256 _massGrams, uint256 _purityBps) external view returns (uint256) {
        uint256 pureGoldGrams = (_massGrams * _purityBps) / 10000;
        return (pureGoldGrams * sovPerPureGram) / 1000;
    }

    /**
     * @notice Check if an attestation has been processed.
     *         Uses the same hash formula as confirmAndMint: keccak256(spectrumHash, timestamp, nodeId).
     */
    function isProcessed(bytes32 _spectrumHash, uint64 _timestamp, bytes32 _nodeId) external view returns (bool) {
        return processedAttestations[keccak256(abi.encode(_spectrumHash, _timestamp, _nodeId))];
    }
}
