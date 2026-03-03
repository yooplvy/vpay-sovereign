// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";

/**
 * @title SovereignToken ($SOV)
 * @notice The native governance and utility token of the VPAY Sovereign Stack.
 *         Used for staking, fee collection, and governing the gold reserves.
 */
contract SovereignToken is ERC20, AccessControl {
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant BURNER_ROLE = keccak256("BURNER_ROLE");
    
    // FIXED SUPPLY: 100,000,000 SOV
    uint256 public constant MAX_SUPPLY = 100_000_000 * 10**18;

    constructor() ERC20("VPAY Sovereign", "SOV") {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(MINTER_ROLE, msg.sender);
        _grantRole(BURNER_ROLE, msg.sender);
        
        // Genesis Mint: 15% to Architect (You)
        _mint(msg.sender, 15_000_000 * 10**18);
    }

    function mint(address to, uint256 amount) external onlyRole(MINTER_ROLE) {
        require(totalSupply() + amount <= MAX_SUPPLY, "Max supply reached");
        _mint(to, amount);
    }

    function burn(uint256 amount) external onlyRole(BURNER_ROLE) {
        _burn(_msgSender(), amount);
    }
}
