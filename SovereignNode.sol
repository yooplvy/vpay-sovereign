// SPDX-License-Identifier: VPAY-1.0
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import "./interfaces/ICircuitBreaker.sol";

error VPAY__InvalidSignature();
error VPAY__NodeAlreadyRegistered();
error VPAY__Unauthorized();
error VPAY__Paused();
error VPAY__InvalidPurity();
error VPAY__NodeNotRegistered();

/**
 * @title SovereignNode (v2 — Integrated)
 * @author ANO-YOOFI-AGYEI
 * @notice Handles node registration and full physics attestation for VPAY Genesis.
 *         v2 adds: XRF purity data, GPS coordinates, CircuitBreaker integration,
 *         attestation counters, and an event hook for the AttestationBridge
 *         to trigger $SOV minting on confirmed attestations.
 *
 *         Core principle: No verification, no token.
 */
contract SovereignNode is AccessControl {
    using ECDSA for bytes32;

    string public constant ARCHITECT = "ANO-YOOFI-AGYEI";
    string public constant PROTOCOL_ID = "VPAY-GENESIS-v2.0";

    bytes32 public constant NODE_ROLE = keccak256("NODE_ROLE");
    bytes32 public constant GOVERNANCE_ROLE = keccak256("GOVERNANCE_ROLE");

    // ════════════════════════════════════════
    // DATA STRUCTURES
    // ════════════════════════════════════════

    struct NodeIdentity {
        bytes32 nodeId;
        address tpmAkPub;       // Ethereum address derived from TPM attestation key
        uint8 tier;             // 1 = Mine Site, 2 = Refinery, 3 = Reserve Vault
        int32 gpsLatE6;         // GPS latitude × 1e6 (e.g., 5603700 = 5.6037°)
        int32 gpsLonE6;         // GPS longitude × 1e6 (e.g., -187000 = -0.1870°)
        bool isVerified;
        uint64 registeredAt;
    }

    struct PhysicsAttestation {
        // Mass & Purity (XRF)
        uint256 massGrams;      // Weight in grams (1e3 precision)
        uint256 purityBps;      // XRF purity in basis points (9972 = 99.72%)
        uint256 karatE2;        // Karat × 100 (2393 = 23.93K)
        // Environment
        uint256 tempCE2;        // Temperature × 100 in Celsius
        bool sealIntact;
        // Location
        int32 gpsLatE6;         // GPS at time of reading
        int32 gpsLonE6;
        uint16 gpsAccuracyDm;   // GPS accuracy in decimeters (21 = 2.1m)
        // Cryptographic
        bytes32 spectrumHash;   // SHA-256 of raw XRF spectrum data
        bytes signature;        // ECDSA from TPM secure element
        // Metadata
        uint64 timestamp;
        uint64 blockNumber;
    }

    // ════════════════════════════════════════
    // STATE
    // ════════════════════════════════════════

    ICircuitBreaker public circuitBreaker;

    mapping(bytes32 => NodeIdentity) public nodes;
    mapping(bytes32 => PhysicsAttestation) public latestAttestation;
    mapping(bytes32 => uint256) public attestationCount; // Total attestations per node

    uint256 public nodeCount;
    uint256 public totalAttestations;

    // ════════════════════════════════════════
    // EVENTS
    // ════════════════════════════════════════

    event NodeRegistered(bytes32 indexed nodeId, address indexed tpmAkPub, uint8 tier);
    event NodeDeactivated(bytes32 indexed nodeId);

    /// @notice Emitted on every confirmed attestation — this is the hook that
    ///         the AttestationBridge listens to for triggering $SOV mints.
    event AttestationConfirmed(
        bytes32 indexed nodeId,
        uint256 indexed attestationIndex,
        uint256 massGrams,
        uint256 purityBps,
        bytes32 spectrumHash,
        uint64 timestamp
    );

    event SealStatusChanged(bytes32 indexed nodeId, bool isIntact);

    // ════════════════════════════════════════
    // CONSTRUCTOR
    // ════════════════════════════════════════

    /**
     * @notice Initialize SovereignNode v2 with CircuitBreaker reference.
     * @param _circuitBreaker Address of the deployed CircuitBreaker contract.
     */
    constructor(address _circuitBreaker) {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(GOVERNANCE_ROLE, msg.sender);
        circuitBreaker = ICircuitBreaker(_circuitBreaker);
    }

    // ════════════════════════════════════════
    // MODIFIERS
    // ════════════════════════════════════════

    modifier whenNotPaused(bytes32 _nodeId) {
        if (circuitBreaker.globalPaused()) revert VPAY__Paused();
        if (circuitBreaker.nodePaused(_nodeId)) revert VPAY__Paused();
        _;
    }

    // ════════════════════════════════════════
    // NODE MANAGEMENT
    // ════════════════════════════════════════

    /**
     * @notice Register a new GSU node with its TPM public key and location.
     * @param _nodeId Unique identifier for the node (e.g., keccak256 of serial number).
     * @param _tpmAkPub Ethereum address derived from TPM attestation key public key.
     * @param _tier GSU tier: 1 = Mine Site, 2 = Refinery, 3 = Reserve Vault.
     * @param _gpsLatE6 GPS latitude × 1e6.
     * @param _gpsLonE6 GPS longitude × 1e6.
     */
    function registerNode(
        bytes32 _nodeId,
        address _tpmAkPub,
        uint8 _tier,
        int32 _gpsLatE6,
        int32 _gpsLonE6
    ) external onlyRole(GOVERNANCE_ROLE) {
        if (nodes[_nodeId].isVerified) revert VPAY__NodeAlreadyRegistered();
        require(_tier >= 1 && _tier <= 3, "Invalid tier");

        nodes[_nodeId] = NodeIdentity({
            nodeId: _nodeId,
            tpmAkPub: _tpmAkPub,
            tier: _tier,
            gpsLatE6: _gpsLatE6,
            gpsLonE6: _gpsLonE6,
            isVerified: true,
            registeredAt: uint64(block.timestamp)
        });

        nodeCount++;
        emit NodeRegistered(_nodeId, _tpmAkPub, _tier);
    }

    /**
     * @notice Deactivate a node (e.g., decommissioned, compromised).
     * @param _nodeId The node to deactivate.
     */
    function deactivateNode(bytes32 _nodeId) external onlyRole(GOVERNANCE_ROLE) {
        if (!nodes[_nodeId].isVerified) revert VPAY__NodeNotRegistered();
        nodes[_nodeId].isVerified = false;
        emit NodeDeactivated(_nodeId);
    }

    // ════════════════════════════════════════
    // ATTESTATION SUBMISSION
    // ════════════════════════════════════════

    /**
     * @notice Submit a cryptographically signed physics attestation from a GSU device.
     *         This is the core function: the GSU measures gold, signs the data with its
     *         TPM secure element, and submits it here. On success, emits AttestationConfirmed
     *         which the AttestationBridge watches to trigger $SOV minting.
     *
     * @param _nodeId The node submitting the attestation.
     * @param _massGrams Weight of gold in grams.
     * @param _purityBps XRF purity in basis points (9972 = 99.72%).
     * @param _karatE2 Karat × 100 (2393 = 23.93K).
     * @param _tempCE2 Temperature × 100 in Celsius.
     * @param _sealIntact Physical seal status.
     * @param _gpsLatE6 GPS latitude × 1e6 at time of measurement.
     * @param _gpsLonE6 GPS longitude × 1e6 at time of measurement.
     * @param _gpsAccuracyDm GPS accuracy in decimeters.
     * @param _spectrumHash SHA-256 hash of raw XRF spectrum data.
     * @param _signature ECDSA signature from node's TPM secure element.
     */
    function submitAttestation(
        bytes32 _nodeId,
        uint256 _massGrams,
        uint256 _purityBps,
        uint256 _karatE2,
        uint256 _tempCE2,
        bool _sealIntact,
        int32 _gpsLatE6,
        int32 _gpsLonE6,
        uint16 _gpsAccuracyDm,
        bytes32 _spectrumHash,
        bytes calldata _signature
    ) external onlyRole(NODE_ROLE) whenNotPaused(_nodeId) {
        NodeIdentity storage node = nodes[_nodeId];
        if (!node.isVerified) revert VPAY__Unauthorized();
        if (_purityBps == 0 || _purityBps > 10000) revert VPAY__InvalidPurity();

        // ── 1. Verify TPM Signature (ECDSA) ──
        bytes32 structHash = keccak256(abi.encode(
            keccak256("Attestation(bytes32 nodeId,uint256 massGrams,uint256 purityBps,uint256 karatE2,uint256 tempCE2,bool sealIntact,int32 gpsLatE6,int32 gpsLonE6,bytes32 spectrumHash)"),
            _nodeId, _massGrams, _purityBps, _karatE2, _tempCE2, _sealIntact, _gpsLatE6, _gpsLonE6, _spectrumHash
        ));
        bytes32 ethHash = MessageHashUtils.toEthSignedMessageHash(structHash);

        address signer = ethHash.recover(_signature);
        if (signer != node.tpmAkPub) revert VPAY__InvalidSignature();

        // ── 2. Store attestation ──
        bool wasIntact = latestAttestation[_nodeId].sealIntact;

        latestAttestation[_nodeId] = PhysicsAttestation({
            massGrams: _massGrams,
            purityBps: _purityBps,
            karatE2: _karatE2,
            tempCE2: _tempCE2,
            sealIntact: _sealIntact,
            gpsLatE6: _gpsLatE6,
            gpsLonE6: _gpsLonE6,
            gpsAccuracyDm: _gpsAccuracyDm,
            spectrumHash: _spectrumHash,
            signature: _signature,
            timestamp: uint64(block.timestamp),
            blockNumber: uint64(block.number)
        });

        // ── 3. Update counters ──
        uint256 attIndex = attestationCount[_nodeId];
        attestationCount[_nodeId] = attIndex + 1;
        totalAttestations++;

        // ── 4. Emit events ──
        emit AttestationConfirmed(
            _nodeId,
            attIndex,
            _massGrams,
            _purityBps,
            _spectrumHash,
            uint64(block.timestamp)
        );

        if (wasIntact != _sealIntact) {
            emit SealStatusChanged(_nodeId, _sealIntact);
        }
    }

    // ════════════════════════════════════════
    // VIEW FUNCTIONS
    // ════════════════════════════════════════

    /**
     * @notice Check if a node is verified and active.
     */
    function isNodeActive(bytes32 _nodeId) external view returns (bool) {
        return nodes[_nodeId].isVerified;
    }

    /**
     * @notice Get the latest attestation purity for a node.
     */
    function getLatestPurity(bytes32 _nodeId) external view returns (uint256) {
        return latestAttestation[_nodeId].purityBps;
    }

    /**
     * @notice Get the latest attestation mass for a node.
     */
    function getLatestMass(bytes32 _nodeId) external view returns (uint256) {
        return latestAttestation[_nodeId].massGrams;
    }

    /**
     * @notice Update the CircuitBreaker reference (admin only).
     */
    function setCircuitBreaker(address _newBreaker) external onlyRole(DEFAULT_ADMIN_ROLE) {
        circuitBreaker = ICircuitBreaker(_newBreaker);
    }
}
