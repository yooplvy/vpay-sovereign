#!/bin/bash
npx hardhat verify \
  --network polygon_mainnet \
  --constructor-args scripts/args_redemption_v2.js \
  0x72CaF0Ae3765A57eEC0aeb2A44Cd2Be57f810B83
