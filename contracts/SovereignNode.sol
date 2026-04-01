// SPDX-License-Identifier: VPAY-1.0
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

/**
 * @title SovereignNode v6.0
 * @notice Hardened attestation with EIP-712 domain separation & replay protection.
 *         Implements full 5-condition physics gate via attested() view function.
 * @dev Uses tryRecover for graceful error handling.
 */
contract SovereignNode is AccessControl {
    bytes32 public constant NODE_ROLE = keccak256("NODE_ROLE");
    bytes32 public constant GOVERNANCE_ROLE = keccak256("GOVERNANCE_ROLE");

    struct Attestation {
        uint128 massKg;
        int64   massDeviation_mg;  // signed: deviation from reference mass in milligrams
        uint32  r2Score;           // ×10000: 0.97 → 9700, 0.98 → 9800
        uint32  resilienceScore;   // ×10000: 0.88 → 8800
        uint64  timestamp;
        bool    isSealed;
    }

    // Physics gate thresholds (source: whitepaper + genesis-os.html audit 2026-04-01)
    int64   public constant MASS_DEV_THRESHOLD_MG  = 500;    // ±500mg
    uint32  public constant R2_THRESHOLD            = 9700;   // 0.97 × 10000
    uint32  public constant RESILIENCE_THRESHOLD    = 8800;   // 0.88 × 10000
    uint64  public constant STALENESS_THRESHOLD_S   = 120;    // 120 seconds

    mapping(bytes32 => address) public nodeOwners;
    mapping(bytes32 => Attestation) public latestAttestations;
    mapping(bytes32 => uint256) public attestationNonces;

    // EIP-712 Domain Separator
    bytes32 public immutable DOMAIN_SEPARATOR;
    bytes32 public constant ATTESTATION_TYPEHASH = keccak256(
        "Attestation(bytes32 nodeId,uint128 massKg,int64 massDeviation_mg,uint32 r2Score,uint32 resilienceScore,bool isSealed,uint256 nonce)"
    );

    event NodeRegistered(bytes32 indexed nodeId, address indexed owner);
    event NodeTransferred(bytes32 indexed nodeId, address indexed newOwner);
    event AttestationUpdated(
        bytes32 indexed nodeId,
        uint128 massKg,
        uint64 timestamp,
        bool isSealed,
        uint256 nonce
    );

    constructor() {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(GOVERNANCE_ROLE, msg.sender);

        DOMAIN_SEPARATOR = keccak256(abi.encode(
            keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
            keccak256("SovereignNode"),
            keccak256("6.0"),
            block.chainid,
            address(this)
        ));
    }

    function transferNode(bytes32 _nodeId, address _newOwner) external onlyRole(GOVERNANCE_ROLE) {
        require(nodeOwners[_nodeId] != address(0), "Node not registered");
        require(_newOwner != address(0), "Invalid owner");
        nodeOwners[_nodeId] = _newOwner;
        emit NodeTransferred(_nodeId, _newOwner);
    }

    function registerNode(bytes32 _nodeId, address _owner) external onlyRole(GOVERNANCE_ROLE) {
        require(_owner != address(0), "Invalid owner");
        require(nodeOwners[_nodeId] == address(0), "Node already registered");
        nodeOwners[_nodeId] = _owner;
        emit NodeRegistered(_nodeId, _owner);
    }

    /// @notice Verifies EIP-712 signature with nonce-based replay protection.
    /// @param _nonce Must be strictly greater than previous nonce for this node.
    function submitAttestation(
        bytes32 _nodeId,
        uint128 _massKg,
        int64   _massDeviation_mg,
        uint32  _r2Score,
        uint32  _resilienceScore,
        bool    _isSealed,
        uint256 _nonce,
        bytes calldata _signature
    ) external onlyRole(NODE_ROLE) {
        require(_massKg > 0,                         "Invalid mass");
        require(nodeOwners[_nodeId] != address(0),   "Node not registered");
        require(_nonce > attestationNonces[_nodeId], "Nonce too old");
        require(_r2Score <= 10000,                   "r2Score out of range");
        require(_resilienceScore <= 10000,           "resilienceScore out of range");

        attestationNonces[_nodeId] = _nonce;

        bytes32 structHash = keccak256(abi.encode(
            ATTESTATION_TYPEHASH,
            _nodeId,
            _massKg,
            _massDeviation_mg,
            _r2Score,
            _resilienceScore,
            _isSealed,
            _nonce
        ));

        bytes32 digest = MessageHashUtils.toTypedDataHash(DOMAIN_SEPARATOR, structHash);
        (address signer, ECDSA.RecoverError error,) = ECDSA.tryRecover(digest, _signature);
        require(error == ECDSA.RecoverError.NoError, "Invalid signature format");
        require(signer == nodeOwners[_nodeId],        "Invalid signer");

        latestAttestations[_nodeId] = Attestation({
            massKg:           _massKg,
            massDeviation_mg: _massDeviation_mg,
            r2Score:          _r2Score,
            resilienceScore:  _resilienceScore,
            timestamp:        uint64(block.timestamp),
            isSealed:         _isSealed
        });

        emit AttestationUpdated(_nodeId, _massKg, uint64(block.timestamp), _isSealed, _nonce);
    }

    /// @notice Returns true only if ALL 5 physics gate conditions pass.
    /// @dev Downstream contracts (OnRampEscrow etc.) MUST call this before minting SOV.
    ///      Each condition maps directly to the whitepaper physics gate threshold.
    function attested(bytes32 _nodeId) external view returns (bool) {
        Attestation memory att = latestAttestations[_nodeId];
        if (att.timestamp == 0) return false; // never attested

        bool tamperOk     = att.isSealed;
        bool massOk       = att.massDeviation_mg >= -MASS_DEV_THRESHOLD_MG &&
                            att.massDeviation_mg <=  MASS_DEV_THRESHOLD_MG;
        bool r2Ok         = att.r2Score >= R2_THRESHOLD;
        bool resilienceOk = att.resilienceScore >= RESILIENCE_THRESHOLD;
        bool freshnessOk  = (block.timestamp - att.timestamp) < STALENESS_THRESHOLD_S;

        return tamperOk && massOk && r2Ok && resilienceOk && freshnessOk;
    }

    function getAttestation(bytes32 _nodeId) external view returns (Attestation memory) {
        return latestAttestations[_nodeId];
    }
}
