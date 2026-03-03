require("@nomicfoundation/hardhat-toolbox");
require("dotenv").config();

module.exports = {
  solidity: "0.8.28",
  networks: {
    arbitrum_sepolia: {
      url: "https://sepolia-rollup.arbitrum.io/rpc",
      accounts: [process.env.PRIVATE_KEY],
      chainId: 421614
    }
  },
  etherscan: {
    apiKey: {
      arbitrum_sepolia: process.env.ARBISCAN_API_KEY // We will add this next
    }
  }
};
