#!/bin/bash
# verify-all.sh — Verify all 9 VPAY contracts on Polygonscan (Etherscan V2 API)
# Run from: /Users/apple/vpay-genesis/contracts

DEPLOYER="0xc899eCe085ffB1382c85B0f2159F100c09D5EAc0"
SOV_TOKEN="0x5833ABF0Ecfe61e85682F3720BA4d636084E0EC0"
SOV_NODE="0x721A41B6da222697b4cc3be02715CAD2e598D834"
ORACLE="0xE130956e443ABBecefc3BE4E33DD811C70749752"
CB="0xA6500cA2dcF8E9F67a71F7aA9795cA2d51FE9ba9"
PAYMENT_SOV="0x3451222D576AF7Ee994915C8D2B7b09a738FBF49"
ON_RAMP="0x34Dd2c07e7a6a051A08691e9d1abA23d81033779"
OFF_RAMP="0xBd8536E2EBFD3EB54ed1E717C109a1271Ff87275"
VAULT="0x1B6d93dB06521F22cAF31DfF251f277A619586B3"
STAKING="0x549215Ac647E763E77a8e8dB923C75176c19DF0b"
CHAINLINK="0x0C466540B2ee1a31b441671eac0ca886e051E410"
BAND="0x0000000000000000000000000000000000000000"
USDC="0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359"
LZ_ENDPOINT="0x1a44076050125825900e736c501f859c50fE728c"

echo "=== VPAY Polygon Mainnet Verification ==="

echo -e "\n[1/9] SovereignToken..."
npx hardhat verify --network polygon_mainnet $SOV_TOKEN || true

echo -e "\n[2/9] SovereignNode..."
npx hardhat verify --network polygon_mainnet $SOV_NODE || true

echo -e "\n[3/9] OracleTriad (chainlink, band)..."
npx hardhat verify --network polygon_mainnet $ORACLE "$CHAINLINK" "$BAND" || true

echo -e "\n[4/9] CircuitBreaker (admin=deployer)..."
npx hardhat verify --network polygon_mainnet $CB "$DEPLOYER" || true

echo -e "\n[5/9] PaymentSOV (name, symbol, lzEndpoint, delegate)..."
npx hardhat verify --network polygon_mainnet $PAYMENT_SOV "VPAY Sovereign" "SOV" "$LZ_ENDPOINT" "$DEPLOYER" || true

echo -e "\n[6/9] OnRampEscrow (paymentSOV, circuitBreaker, sovereignNode, admin)..."
npx hardhat verify --network polygon_mainnet $ON_RAMP "$PAYMENT_SOV" "$CB" "$SOV_NODE" "$DEPLOYER" || true

echo -e "\n[7/9] OffRampEscrow (token, admin)..."
npx hardhat verify --network polygon_mainnet $OFF_RAMP "$PAYMENT_SOV" "$DEPLOYER" || true

echo -e "\n[8/9] VPAYVault (node, stablecoin, treasury, oracleTriad)..."
npx hardhat verify --network polygon_mainnet $VAULT "$SOV_NODE" "$USDC" "$DEPLOYER" "$ORACLE" || true

echo -e "\n[9/9] StakingModule (usdc, vpay)..."
npx hardhat verify --network polygon_mainnet $STAKING "$USDC" "$PAYMENT_SOV" || true

echo -e "\n=== Done ==="
