// SPDX-License-Identifier: MIT
// @title PaymentSOV — Sovereign Payment Token (Arbitrum One)
// @notice True LayerZero OFT ERC-20 for VPAY MoMo payment rail.
//         MINTER_ROLE: Gateway operational wallet (on-ramp mints)
//         BURNER_ROLE: OffRampEscrow.sol (burns on release)
//         Bridge activation: Phase 3 — call setPeer() to connect Polygon SOVToken.
//         Until setPeer() is called, OFT.send() reverts with "NoPeer" — bridge dormant.
pragma solidity ^0.8.20;

import "@layerzerolabs/oft-evm/contracts/OFT.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

// OFT already inherits ERC20, OAppCore (which inherits Ownable).
// We add AccessControl on top for MINTER_ROLE / BURNER_ROLE separation.
// NOTE: OZ v5 Ownable requires initialOwner in constructor. OAppCore doesn't
// pass it, so we explicitly chain Ownable(_delegate) here.
contract PaymentSOV is OFT, AccessControl, ReentrancyGuard {
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant BURNER_ROLE = keccak256("BURNER_ROLE");

    /// @param _name       Token name ("Sovereign Payment Token")
    /// @param _symbol     Token symbol ("pSOV")
    /// @param _lzEndpoint LayerZero V2 endpoint (MockLZEndpoint on testnet)
    /// @param _delegate   Initial OFT delegate + DEFAULT_ADMIN_ROLE holder + Ownable owner
    constructor(
        string memory _name,
        string memory _symbol,
        address _lzEndpoint,
        address _delegate
    ) OFT(_name, _symbol, _lzEndpoint, _delegate) Ownable(_delegate) {
        require(_delegate != address(0), "PaymentSOV: delegate is zero address");
        // OFT base constructor: ERC20(_name, _symbol) + OFTCore(decimals(), _lzEndpoint, _delegate)
        // OFTCore → OApp → OAppCore: endpoint.setDelegate(_delegate)
        // Ownable(_delegate): sets owner (OZ v5 requires explicit initialOwner)
        _grantRole(DEFAULT_ADMIN_ROLE, _delegate);
    }

    /// @notice Mint PaymentSOV to a recipient. Only MINTER_ROLE.
    function mint(address to, uint256 amount)
        external
        onlyRole(MINTER_ROLE)
        nonReentrant
    {
        _mint(to, amount);
    }

    /// @notice Burn PaymentSOV from an address. Only BURNER_ROLE.
    ///         Called internally by OffRampEscrow.release() — never by Gateway directly.
    function burn(address from, uint256 amount)
        external
        onlyRole(BURNER_ROLE)
        nonReentrant
    {
        _burn(from, amount);
    }

    // NOTE: Cross-chain bridging uses the inherited OFT.send() function.
    // Bridge is DORMANT until Phase 3: admin calls setPeer(polygonChainId, polygonSOVTokenAddress).
    // Before setPeer(), OFT.send() reverts with NoPeer — no stub needed.
}
