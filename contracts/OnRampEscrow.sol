// SPDX-License-Identifier: MIT
// @title OnRampEscrow — Rate-locked fiat → $SOV mint authority
// @notice Gateway calls createRateLock() when citizen confirms amount.
//         TTL = 120s from creation. Only confirmAndMint() within TTL triggers mint.
//         Circuit breaker checked at mint time — PAUSED/REVERTED states block mint.
//         Physics gate (SovereignNode.attested) checked at mint time — unattested node blocks mint.
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./interfaces/IPaymentSOV.sol";
import "./interfaces/ICircuitBreaker.sol";
import "./SovereignNode.sol";

error TxAlreadyExists();
error TxAlreadyProcessed();
error TxNotFound();
error RateLockExpired();
error RateLockStillActive();
error MintingPaused();

contract OnRampEscrow is AccessControl, ReentrancyGuard {
    bytes32 public constant GATEWAY_ROLE = keccak256("GATEWAY_ROLE");

    uint256 public constant TTL = 120 seconds;

    IPaymentSOV     public immutable token;
    ICircuitBreaker public immutable circuitBreaker;
    SovereignNode   public immutable sovereignNode;

    enum TxStatus { NONE, PENDING, MINTED, CANCELLED }

    struct RateLock {
        address  recipient;
        uint256  sovAmount;
        uint256  expiresAt;
        TxStatus status;
    }

    mapping(bytes32 => RateLock) public rateLocks;

    event RateLockCreated(bytes32 indexed txId, address indexed recipient, uint256 sovAmount);
    event RateLockMinted(bytes32 indexed txId, address indexed recipient, uint256 sovAmount);
    event RateLockCancelled(bytes32 indexed txId);

    constructor(address _token, address _circuitBreaker, address _sovereignNode, address _admin) {
        require(_token          != address(0), "OnRampEscrow: zero token");
        require(_circuitBreaker != address(0), "OnRampEscrow: zero cb");
        require(_sovereignNode  != address(0), "OnRampEscrow: zero node");
        require(_admin          != address(0), "OnRampEscrow: zero admin");
        token          = IPaymentSOV(_token);
        circuitBreaker = ICircuitBreaker(_circuitBreaker);
        sovereignNode  = SovereignNode(_sovereignNode);
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
    }

    /// @notice Gateway creates a 120s rate-locked mint intent.
    function createRateLock(
        bytes32 txId,
        address recipient,
        uint256 sovAmount
    ) external onlyRole(GATEWAY_ROLE) {
        if (rateLocks[txId].status != TxStatus.NONE) revert TxAlreadyExists();
        require(recipient != address(0), "OnRampEscrow: zero recipient");
        require(sovAmount  > 0,          "OnRampEscrow: zero amount");

        rateLocks[txId] = RateLock({
            recipient: recipient,
            sovAmount: sovAmount,
            expiresAt: block.timestamp + TTL,
            status:    TxStatus.PENDING
        });

        emit RateLockCreated(txId, recipient, sovAmount);
    }

    /// @notice Called after Flutterwave webhook confirms payment.
    /// @param txId   The rate lock transaction ID.
    /// @param nodeId The SovereignNode ID that must have a passing physics gate attestation.
    function confirmAndMint(bytes32 txId, bytes32 nodeId)
        external
        onlyRole(GATEWAY_ROLE)
        nonReentrant
    {
        RateLock storage lock = rateLocks[txId];
        if (lock.status == TxStatus.NONE)    revert TxNotFound();
        if (lock.status != TxStatus.PENDING) revert TxAlreadyProcessed();
        if (block.timestamp > lock.expiresAt) revert RateLockExpired();
        if (!circuitBreaker.canMint())        revert MintingPaused();
        require(sovereignNode.attested(nodeId), "OnRampEscrow: physics gate not attested");

        lock.status = TxStatus.MINTED;
        token.mint(lock.recipient, lock.sovAmount);

        emit RateLockMinted(txId, lock.recipient, lock.sovAmount);
    }

    /// @notice Cancel an expired rate lock.
    function cancelRateLock(bytes32 txId) external onlyRole(GATEWAY_ROLE) {
        RateLock storage lock = rateLocks[txId];
        if (lock.status == TxStatus.NONE)    revert TxNotFound();
        if (lock.status != TxStatus.PENDING) revert TxAlreadyProcessed();
        if (block.timestamp <= lock.expiresAt) revert RateLockStillActive();

        lock.status = TxStatus.CANCELLED;
        emit RateLockCancelled(txId);
    }
}
