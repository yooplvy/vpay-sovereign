// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IPaymentSOV {
    function mint(address to, uint256 amount) external;
    function burn(address from, uint256 amount) external;
    function MINTER_ROLE() external view returns (bytes32);
    function BURNER_ROLE() external view returns (bytes32);
}
