// SPDX-License-Identifier: VPAY-1.0
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title ISovereignToken
 * @notice Interface for the deployed SovereignToken ($SOV) on Polygon.
 *         Contract: 0x5833ABF0Ecfe61e85682F3720BA4d636084e0eC0
 */
interface ISovereignToken is IERC20 {
    function mint(address to, uint256 amount) external;
    function burn(uint256 amount) external;
    function burnFrom(address account, uint256 amount) external;
    function MINTER_ROLE() external view returns (bytes32);
    function BURNER_ROLE() external view returns (bytes32);
    function MAX_SUPPLY() external view returns (uint256);
    function hasRole(bytes32 role, address account) external view returns (bool);
    function grantRole(bytes32 role, address account) external;
}
