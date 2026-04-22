#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# gen_kommit_wallets.sh — generate REASONER + ORACLE keypairs for KommitBridge v1.1
#
# Usage:
#   bash contracts/scripts/gen_kommit_wallets.sh
#
# What this does:
#   1. Generates two fresh Ethereum keypairs using `cast wallet new`.
#   2. Saves each keypair to ~/.vpay-kommit/{reasoner,oracle}.key with 0600 perms.
#   3. Prints the addresses to stdout (safe to share / paste into env files).
#   4. Writes ~/.vpay-kommit/env.example you can `source` before broadcast.
#
# Security:
#   - Keys never leave your machine.
#   - Files are mode 0600 (readable only by you).
#   - The script does NOT print private keys to stdout — only addresses.
#   - You MUST back up ~/.vpay-kommit/ to a hardware-encrypted volume before
#     funding the wallets. Loss of these keys = loss of REASONER and ORACLE
#     ability for the lifetime of KommitBridge v1.1 (until Safe rotates roles).
#
# After this script runs:
#   1. `cat ~/.vpay-kommit/env.example` → see addresses to paste into deploy
#   2. Fund both addresses with ~1 MATIC each on Polygon Mainnet (gas reserve).
#   3. Run the deploy script with REASONER_WALLET / ORACLE_WALLET exported.
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail

KEY_DIR="${HOME}/.vpay-kommit"
REASONER_FILE="${KEY_DIR}/reasoner.key"
ORACLE_FILE="${KEY_DIR}/oracle.key"
ENV_EXAMPLE="${KEY_DIR}/env.example"

# ── Pre-flight checks ────────────────────────────────────────────────────────
if ! command -v cast >/dev/null 2>&1; then
    echo "ERROR: 'cast' not found in PATH. Install Foundry first:" >&2
    echo "  curl -L https://foundry.paradigm.xyz | bash && foundryup" >&2
    exit 1
fi

if [[ -f "${REASONER_FILE}" || -f "${ORACLE_FILE}" ]]; then
    echo "ERROR: Existing keys found in ${KEY_DIR}." >&2
    echo "  Refusing to overwrite. Move them aside or delete first:" >&2
    echo "    mv ${KEY_DIR} ${KEY_DIR}.backup-\$(date +%Y%m%d-%H%M%S)" >&2
    exit 1
fi

mkdir -p "${KEY_DIR}"
chmod 700 "${KEY_DIR}"

# ── Helper: generate one wallet, save key, print address ─────────────────────
gen_wallet() {
    local name="$1"
    local keyfile="$2"

    # `cast wallet new` outputs:
    #   Successfully created new keypair.
    #   Address:     0x...
    #   Private key: 0x...
    local out
    out=$(cast wallet new)

    local addr pk
    addr=$(echo "${out}" | grep -E '^Address:'     | awk '{print $2}')
    pk=$(  echo "${out}" | grep -E '^Private key:' | awk '{print $3}')

    if [[ -z "${addr}" || -z "${pk}" ]]; then
        echo "ERROR: failed to parse cast wallet new output for ${name}." >&2
        echo "${out}" >&2
        exit 1
    fi

    # Save key (mode 0600)
    umask 077
    printf '%s\n' "${pk}" > "${keyfile}"
    chmod 600 "${keyfile}"

    # Echo address only (NEVER the private key)
    echo "${name}_ADDRESS=${addr}"
}

# ── Generate ─────────────────────────────────────────────────────────────────
echo "Generating REASONER + ORACLE wallets for KommitBridge v1.1..."
echo

REASONER_LINE=$(gen_wallet "REASONER" "${REASONER_FILE}")
ORACLE_LINE=$(  gen_wallet "ORACLE"   "${ORACLE_FILE}")

REASONER_ADDR=$(echo "${REASONER_LINE}" | cut -d= -f2)
ORACLE_ADDR=$(  echo "${ORACLE_LINE}"   | cut -d= -f2)

# Sanity: never let them collide (vanishingly unlikely from `cast wallet new`,
# but assert anyway because contract assumes they're distinct).
if [[ "${REASONER_ADDR}" == "${ORACLE_ADDR}" ]]; then
    echo "ERROR: REASONER and ORACLE addresses collided. Re-run." >&2
    rm -f "${REASONER_FILE}" "${ORACLE_FILE}"
    exit 1
fi

# ── Write env.example for sourcing ───────────────────────────────────────────
cat > "${ENV_EXAMPLE}" <<EOF
# ─────────────────────────────────────────────────────────────────────────────
# KommitBridge v1.1 deploy env — generated $(date -u +%Y-%m-%dT%H:%M:%SZ)
#
# Source this file (or copy lines) into your deploy shell:
#   source ~/.vpay-kommit/env.example
#
# Then the deploy script can be run:
#   cd contracts
#   forge script deploy/DeployKommit.s.sol \\
#     --rpc-url \$POLYGON_RPC \\
#     --broadcast --verify \\
#     --etherscan-api-key \$POLYGONSCAN_API_KEY \\
#     -vvvv
# ─────────────────────────────────────────────────────────────────────────────

export REASONER_WALLET=${REASONER_ADDR}
export ORACLE_WALLET=${ORACLE_ADDR}

# Optional: pre-register a canonical model hash in the same broadcast.
# Uncomment + fill if you want this. If unset, Safe will registerModel() later.
# export MODEL_HASH_PRIMARY=0x...
# export MODEL_NAME_PRIMARY="hermes-v2-zeus-orchestrator"

# DEPLOYER private key — NOT in this file. Export it manually in the deploy
# shell and never commit. Same for POLYGON_RPC and POLYGONSCAN_API_KEY.
# export PRIVATE_KEY=0x...
# export POLYGON_RPC=https://polygon-rpc.com
# export POLYGONSCAN_API_KEY=...
EOF
chmod 600 "${ENV_EXAMPLE}"

# ── Report ───────────────────────────────────────────────────────────────────
cat <<EOF

─────────────────────────────────────────────────────────────────────────────
  Wallets generated successfully.
─────────────────────────────────────────────────────────────────────────────

  REASONER:  ${REASONER_ADDR}
  ORACLE:    ${ORACLE_ADDR}

  Keys saved (mode 0600):
    ${REASONER_FILE}
    ${ORACLE_FILE}

  Env file written:
    ${ENV_EXAMPLE}

─────────────────────────────────────────────────────────────────────────────
  NEXT STEPS
─────────────────────────────────────────────────────────────────────────────

  1. BACK UP ~/.vpay-kommit/ to a hardware-encrypted volume.
     Loss = loss of REASONER + ORACLE for v1.1's lifetime.

  2. Fund both addresses with ~1 MATIC each on Polygon Mainnet for gas:
     - REASONER will pay gas for every Hermes attestation tick (cheap).
     - ORACLE will pay gas for every replay verdict (cheap).
     Top up periodically from the deployer wallet or Safe.

  3. (Optional) Fund REASONER with at least 10 SOV so it can post bonds.
     Without SOV, attestReasoning() will revert at the safeTransferFrom step.
     Address to send to: ${REASONER_ADDR}

  4. Source the env and broadcast the v1.1 deploy when ready:
     source ${ENV_EXAMPLE}
     export PRIVATE_KEY=...                  # deployer EOA
     export POLYGON_RPC=https://polygon-rpc.com
     export POLYGONSCAN_API_KEY=...
     cd contracts
     forge script deploy/DeployKommit.s.sol \\
       --rpc-url \$POLYGON_RPC \\
       --broadcast --verify \\
       --etherscan-api-key \$POLYGONSCAN_API_KEY \\
       -vvvv

─────────────────────────────────────────────────────────────────────────────
EOF
