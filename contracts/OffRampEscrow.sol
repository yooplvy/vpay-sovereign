// SPDX-License-Identifier: MIT
// @title OffRampEscrow — Atomic $SOV → fiat off-ramp
// @notice Citizen deposits SOV. Gateway calls release() after GHS confirmed delivered.
//         release() burns SOV via BURNER_ROLE. refund() returns SOV if disbursement fails.
//         SOV is NEVER burned before fiat is confirmed — atomicity guaranteed.
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./interfaces/IPaymentSOV.sol";

error TxAlreadyExists();
error TxAlreadyProcessed();
error TxNotFound();

contract OffRampEscrow is AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    bytes32 public constant GATEWAY_ROLE = keccak256("GATEWAY_ROLE");

    IPaymentSOV public immutable token;
    IERC20      public immutable tokenERC20;

    enum TxStatus { NONE, ESCROWED, RELEASED, REFUNDED }

    struct EscrowRecord {
        address depositor;
        uint256 amount;
        TxStatus status;
    }

    mapping(bytes32 => EscrowRecord) public escrows;

    event SOVEscrowed(bytes32 indexed txId, address indexed depositor, uint256 amount);
    event SOVReleased(bytes32 indexed txId, uint256 amount); // burned
    event SOVRefunded(bytes32 indexed txId, address indexed depositor, uint256 amount);

    constructor(address _token, address _admin) {
        require(_token != address(0), "OffRampEscrow: zero token");
        require(_admin != address(0), "OffRampEscrow: zero admin");
        token      = IPaymentSOV(_token);
        tokenERC20 = IERC20(_token);
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
    }

    /// @notice Citizen deposits SOV to escrow. Requires prior ERC-20 approval.
    function deposit(bytes32 txId, uint256 amount) external nonReentrant {
        if (escrows[txId].status != TxStatus.NONE) revert TxAlreadyExists();
        require(amount > 0, "OffRampEscrow: zero amount");

        escrows[txId] = EscrowRecord({
            depositor: msg.sender,
            amount:    amount,
            status:    TxStatus.ESCROWED
        });

        tokenERC20.safeTransferFrom(msg.sender, address(this), amount);
        emit SOVEscrowed(txId, msg.sender, amount);
    }

    /// @notice Called by Gateway after Flutterwave confirms GHS delivered. Burns escrowed SOV.
    function release(bytes32 txId) external onlyRole(GATEWAY_ROLE) nonReentrant {
        EscrowRecord storage rec = escrows[txId];
        if (rec.status == TxStatus.NONE) revert TxNotFound();
        if (rec.status != TxStatus.ESCROWED) revert TxAlreadyProcessed();

        rec.status = TxStatus.RELEASED;
        token.burn(address(this), rec.amount);
        emit SOVReleased(txId, rec.amount);
    }

    /// @notice Called by Gateway if Flutterwave disbursement fails. Returns SOV to depositor.
    function refund(bytes32 txId) external onlyRole(GATEWAY_ROLE) nonReentrant {
        EscrowRecord storage rec = escrows[txId];
        if (rec.status == TxStatus.NONE) revert TxNotFound();
        if (rec.status != TxStatus.ESCROWED) revert TxAlreadyProcessed();

        rec.status = TxStatus.REFUNDED;
        tokenERC20.safeTransfer(rec.depositor, rec.amount);
        emit SOVRefunded(txId, rec.depositor, rec.amount);
    }
}
