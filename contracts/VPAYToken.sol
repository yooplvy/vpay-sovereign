// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";

/**
 * @title VPAYToken
 * @notice Fixed supply governance token.
 * @dev MINTER_ROLE is strictly enforced with MAX_SUPPLY cap.
 */
contract VPAYToken is ERC20, AccessControl {
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant BURNER_ROLE = keccak256("BURNER_ROLE");
    
    uint256 public constant MAX_SUPPLY = 100_000_000 * 10**18; // 100 Million Hard Cap

    constructor() ERC20("VPAY Sovereign Token", "VPAY") {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(MINTER_ROLE, msg.sender);
        _grantRole(BURNER_ROLE, msg.sender);
        
        // Genesis Mint
        _mint(msg.sender, 15_000_000 * 10**18);
    }

    /**
     * @notice Mints new tokens. STRICTLY ENFORCED CAP.
     * @dev Even if MINTER_ROLE is compromised, they cannot exceed MAX_SUPPLY.
     */
    function mint(address to, uint256 amount) external onlyRole(MINTER_ROLE) {
        require(totalSupply() + amount <= MAX_SUPPLY, "MAX SUPPLY REACHED");
        _mint(to, amount);
    }

    function burn(uint256 amount) external onlyRole(BURNER_ROLE) {
        _burn(_msgSender(), amount);
    }

    /// @notice Burns `amount` from `from`'s balance.
    ///         Caller must have BURNER_ROLE. `from` must have approved caller for at least `amount`.
    function burnFrom(address from, uint256 amount) external onlyRole(BURNER_ROLE) {
        _spendAllowance(from, _msgSender(), amount);
        _burn(from, amount);
    }
}
