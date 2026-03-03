// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract GenesisCertificate is ERC721, Ownable {
    uint256 public constant TOKEN_ID = 1;
    string public constant ARCHITECT = "ANO-YOOFI-AGYEI";
    string public constant PROTOCOL_ID = "VPAY-GENESIS-v1.0";
    string public codeHash; 

    constructor(string memory _codeHash) ERC721("VPAY Genesis Architect", "VPAY-GEN") Ownable(msg.sender) {
        codeHash = _codeHash;
        _mint(msg.sender, TOKEN_ID);
    }
}
