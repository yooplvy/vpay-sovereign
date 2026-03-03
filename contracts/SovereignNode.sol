// SPDX-License-Identifier: VPAY-1.0
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

/**
 * @title SovereignNode (Production v2.4)
 * @notice Hardened attestation with EIP-712 domain separation & replay protection.
 * @dev Uses tryRecover for graceful error handling.
 */
contract SovereignNode is AccessControl {
    bytes32 public constant NODE_ROLE = keccak256("NODE_ROLE");
    bytes32 public constant GOVERNANCE_ROLE = keccak256("GOVERNANCE_ROLE");

    struct Attestation {
        uint128 massKg;
        uint64 tempC;
        uint64 timestamp;
        bool isSealed;
    }

    mapping(bytes32 => address) public nodeOwners;
    mapping(bytes32 => Attestation) public latestAttestations;
    mapping(bytes32 => uint256) public attestationNonces;

    // EIP-712 Domain Separator
    bytes32 public immutable DOMAIN_SEPARATOR;
    bytes32 public constant ATTESTATION_TYPEHASH = keccak256(
        "Attestation(bytes32 nodeId,uint128 massKg,bool isSealed,uint256 nonce)"
    );

    event NodeRegistered(bytes32 indexed nodeId, address indexed owner);
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
            keccak256("2.4"),
            block.chainid,
            address(this)
        ));
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
        bool _isSealed,
        uint256 _nonce,
        bytes calldata _signature
    ) external onlyRole(NODE_ROLE) {
        require(_massKg > 0, "Invalid mass");
        require(nodeOwners[_nodeId] != address(0), "Node not registered");
        require(_nonce > attestationNonces[_nodeId], "Nonce too old");
        
        attestationNonces[_nodeId] = _nonce;

        // EIP-712 structured data hashing
        bytes32 structHash = keccak256(abi.encode(
            ATTESTATION_TYPEHASH,
            _nodeId,
            _massKg,
            _isSealed,
            _nonce
        ));
        
        bytes32 digest = MessageHashUtils.toTypedDataHash(DOMAIN_SEPARATOR, structHash);
        
        // FIX: Use tryRecover for graceful error handling
        (address signer, ECDSA.RecoverError error,) = ECDSA.tryRecover(digest, _signature);
        require(error == ECDSA.RecoverError.NoError, "Invalid signature format");
        require(signer == nodeOwners[_nodeId], "Invalid signer");

        latestAttestations[_nodeId] = Attestation({
            massKg: _massKg,
            tempC: 0,
            timestamp: uint64(block.timestamp),
            isSealed: _isSealed
        });
        
        emit AttestationUpdated(_nodeId, _massKg, uint64(block.timestamp), _isSealed, _nonce);
    }

    function getAttestation(bytes32 _nodeId) external view returns (Attestation memory) {
        return latestAttestations[_nodeId];
    }
}
