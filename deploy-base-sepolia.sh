#!/bin/bash
# ===========================================
# Holo Bridge - Base Sepolia (TestNet) Deployment Script
# ===========================================
# This script deploys all contracts needed for the Holo Bridge on Base Sepolia (chain 84532)
#
# Prerequisites:
# 1. Copy .env.example to .env. It holds addresses, never a private key.
# 2. A deployer wallet forge can sign with: a Ledger, or an encrypted keystore
#    made with `cast wallet import deployer --interactive`
# 3. Have Base Sepolia ETH in that wallet (DEPLOY.md names faucets)
#
# Usage:
#   ./deploy-base-sepolia.sh [step] --account deployer
#   ./deploy-base-sepolia.sh [step] --ledger
#
# Steps:
#   1 or token           Deploy MockHOT token
#   2 or vault           Deploy HoloLockVault
#   3 or mint            Mint test tokens to your wallet (MINT_AMOUNT, in wei)
#   4 or order-via-vault Deploy claim order via vault
#   all                  Run all steps
#   status               Show current deployment status

set -e
cd "$(dirname "$0")"
source script/forge-broadcast.sh

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Load environment
if [ -f .env ]; then
    source .env
else
    echo -e "${RED}Error: .env file not found${NC}"
    echo "Please copy .env.example to .env"
    exit 1
fi

if [ -n "$PRIVATE_KEY" ]; then
    echo -e "${RED}Error: remove PRIVATE_KEY from .env. Pass --account <keystore> or --ledger instead.${NC}"
    exit 1
fi

if [ -z "$BASE_SEPOLIA_RPC_URL" ]; then
    BASE_SEPOLIA_RPC_URL="https://sepolia.base.org"
fi

STEP="${1:-status}"
shift || true
WALLET=("$@")
if [ "$STEP" != "status" ]; then
    CHAIN_ID=$(cast chain-id --rpc-url "$BASE_SEPOLIA_RPC_URL") || die "BASE_SEPOLIA_RPC_URL did not answer"
    [ "$CHAIN_ID" = 84532 ] || die "BASE_SEPOLIA_RPC_URL answers for chain $CHAIN_ID, not Base Sepolia"
fi

if [ ${#WALLET[@]} -gt 0 ] || [ "$STEP" != "status" ]; then
    require_wallet "${WALLET[@]}"
    WALLET_ADDRESS=$(cast wallet address "${WALLET[@]}")
    # Scripts that default to msg.sender see the wallet only through --sender.
    WALLET+=(--sender "$WALLET_ADDRESS")
    echo -e "${BLUE}Wallet: $WALLET_ADDRESS${NC}"
fi

# Runs a forge script that broadcasts, leaving its output in OUTPUT. A failed
# run stops the deploy, so no later step reads an earlier run's results.
broadcast() {
    if ! OUTPUT=$(forge script "$@" --rpc-url "$BASE_SEPOLIA_RPC_URL" "${WALLET[@]}" --broadcast -vvv 2>&1); then
        echo "$OUTPUT"
        die "forge script $1 failed"
    fi
    echo "$OUTPUT"
}

BALANCE=0
if [ -n "$WALLET_ADDRESS" ]; then
    BALANCE=$(cast balance "$WALLET_ADDRESS" --rpc-url "$BASE_SEPOLIA_RPC_URL" 2>/dev/null || echo "0")
    echo -e "${BLUE}Balance: $(cast from-wei "$BALANCE") ETH${NC}"
fi
echo ""

set_env() {
    if grep -q "^$1=" .env; then
        sed -i "s|^$1=.*|$1=$2|" .env
    else
        [ -z "$(tail -c1 .env)" ] || echo >> .env
        echo "$1=$2" >> .env
    fi
}

deploy_token() {
    echo -e "${YELLOW}=== Step 1: Deploying MockHOT Token ===${NC}"

    broadcast script/DeployTestHOT.s.sol:DeployTestHOT

    # Extract deployed address
    TOKEN_ADDR=$(echo "$OUTPUT" | grep -oP "MockHOT deployed at: \K0x[a-fA-F0-9]{40}" || true)

    if [ -n "$TOKEN_ADDR" ]; then
        echo -e "${GREEN}MockHOT deployed at: $TOKEN_ADDR${NC}"
        set_env TOKEN_ADDRESS "$TOKEN_ADDR"
        echo -e "${GREEN}Updated .env with TOKEN_ADDRESS${NC}"
    else
        die "Could not extract token address from output"
    fi
}

deploy_vault() {
    echo -e "${YELLOW}=== Step 2: Deploying HoloLockVault ===${NC}"

    if [ -z "$TOKEN_ADDRESS" ]; then
        echo -e "${RED}Error: TOKEN_ADDRESS not set in .env${NC}"
        echo "Run step 1 first, or set TOKEN_ADDRESS to an existing token on Base Sepolia"
        exit 1
    fi

    echo "Using token: $TOKEN_ADDRESS"

    broadcast script/DeployHoloLockVault.s.sol:DeployBaseSepoliaHoloLockVault

    # Extract deployed addresses
    VAULT_ADDR=$(echo "$OUTPUT" | grep -oP "HoloLockVault deployed at: \K0x[a-fA-F0-9]{40}" || true)
    INPUT_TOKEN_ADDR=$(echo "$OUTPUT" | grep -oP "ClaimInputToken deployed at: \K0x[a-fA-F0-9]{40}" || true)

    if [ -n "$VAULT_ADDR" ] && [ -n "$INPUT_TOKEN_ADDR" ]; then
        echo -e "${GREEN}HoloLockVault deployed at: $VAULT_ADDR${NC}"
        echo -e "${GREEN}ClaimInputToken deployed at: $INPUT_TOKEN_ADDR${NC}"
        set_env BASE_SEPOLIA_LOCK_VAULT_ADDRESS "$VAULT_ADDR"
        set_env CLAIM_INPUT_TOKEN "$INPUT_TOKEN_ADDR"
        echo -e "${GREEN}Updated .env with BASE_SEPOLIA_LOCK_VAULT_ADDRESS and CLAIM_INPUT_TOKEN${NC}"
    else
        die "Could not extract the vault and claim input token addresses from output"
    fi
}

mint_tokens() {
    echo -e "${YELLOW}=== Step 3: Minting Test Tokens ===${NC}"

    if [ -z "$TOKEN_ADDRESS" ]; then
        echo -e "${RED}Error: TOKEN_ADDRESS not set in .env${NC}"
        exit 1
    fi

    AMOUNT=${MINT_AMOUNT:-1000000000000000000000}

    echo "Minting $(cast from-wei "$AMOUNT") tokens to $WALLET_ADDRESS"

    # Run mint script
    TOKEN_ADDRESS="$TOKEN_ADDRESS" \
    RECIPIENT="$WALLET_ADDRESS" \
    AMOUNT="$AMOUNT" \
    forge script script/DeployTestHOT.s.sol:MintTestHOT \
        --rpc-url "$BASE_SEPOLIA_RPC_URL" \
        "${WALLET[@]}" \
        --broadcast \
        -vvv

    echo -e "${GREEN}Tokens minted successfully!${NC}"
}

deploy_order_via_vault() {
    echo -e "${YELLOW}=== Deploying Claim Order via HoloLockVault ===${NC}"
    echo -e "${GREEN}This makes the vault the order owner, so claims use the same vault as locks.${NC}"

    if [ -z "$BASE_SEPOLIA_LOCK_VAULT_ADDRESS" ] || [ -z "$CLAIM_INPUT_TOKEN" ]; then
        echo -e "${RED}Error: BASE_SEPOLIA_LOCK_VAULT_ADDRESS or CLAIM_INPUT_TOKEN not set in .env${NC}"
        echo "Deploy the vault first with: ./deploy-base-sepolia.sh vault"
        exit 1
    fi

    # TestNet coupons are signed by the test signer alone, whose key is in
    # src/Constants.sol, unless VALID_SIGNERS and SIGNER_THRESHOLD name others.
    [ -z "${VALID_SIGNER:-}" ] || die "VALID_SIGNER is replaced by VALID_SIGNERS and SIGNER_THRESHOLD: unset it"
    VALID_SIGNERS="${VALID_SIGNERS:-0x8E72b7568738da52ca3DCd9b24E178127A4E7d37}"
    SIGNER_THRESHOLD="${SIGNER_THRESHOLD:-1}"
    echo "Using vault: $BASE_SEPOLIA_LOCK_VAULT_ADDRESS"
    echo "Claim input token: $CLAIM_INPUT_TOKEN"
    echo "Coupon signers: $SIGNER_THRESHOLD of $VALID_SIGNERS"

    BROADCAST_FILE="${FOUNDRY_BROADCAST:-broadcast}/DeployClaimOrderViaVault.s.sol/84532/run-latest.json"
    STARTED=$(mktemp)
    trap 'rm -f "$STARTED"' EXIT
    NETWORK=base-sepolia BASE_SEPOLIA_LOCK_VAULT_ADDRESS="$BASE_SEPOLIA_LOCK_VAULT_ADDRESS" CLAIM_INPUT_TOKEN="$CLAIM_INPUT_TOKEN" \
        VALID_SIGNERS="$VALID_SIGNERS" SIGNER_THRESHOLD="$SIGNER_THRESHOLD" broadcast script/DeployClaimOrderViaVault.s.sol:DeployClaimOrderViaVault
    sent_since "$STARTED" "$BROADCAST_FILE" || die "forge sent nothing: is the vault admin a Safe?"

    # The order hash is the second word of Raindex's AddOrderV3 event data.
    ORDER_HASH_VAL=$(jq -r '.receipts[0].logs[] | select(.topics[0] == "0x87491344dfbcf91f6cbbc610cbbeedc85313d37a02df0c93527f7ea5f8db717f") | .data' "$BROADCAST_FILE" | cut -c67-130 | sed 's/^/0x/')

    if [ -n "$ORDER_HASH_VAL" ] && [ "$ORDER_HASH_VAL" != "0x" ]; then
        echo -e "${GREEN}Order deployed via vault! Hash: $ORDER_HASH_VAL${NC}"
        set_env ORDER_HASH "$ORDER_HASH_VAL"
        set_env ORDER_OWNER "$BASE_SEPOLIA_LOCK_VAULT_ADDRESS"
        echo -e "${GREEN}Updated .env with ORDER_HASH and ORDER_OWNER (vault address)${NC}"
    else
        die "The order was added, but its hash is not in $BROADCAST_FILE. Take ORDER_HASH from the transaction on Etherscan, and set ORDER_OWNER to $BASE_SEPOLIA_LOCK_VAULT_ADDRESS."
    fi
}

show_status() {
    echo -e "${BLUE}=== Deployment Status ===${NC}"
    echo ""
    if [ -n "$WALLET_ADDRESS" ]; then
        echo "Wallet:          $WALLET_ADDRESS"
        echo "Balance:         $(cast from-wei "$BALANCE") ETH"
        echo ""
    fi
    echo "Token Address:   ${TOKEN_ADDRESS:-Not deployed}"
    echo "Vault Address:   ${BASE_SEPOLIA_LOCK_VAULT_ADDRESS:-Not deployed}"
    echo "Order Hash:      ${ORDER_HASH:-Not deployed}"
    echo "Order Owner:     ${ORDER_OWNER:-Not set}"
    echo ""
    echo "Orderbook:       $ORDERBOOK_ADDRESS"
    echo "Vault ID:        $VAULT_ID"
    echo ""

    if [ -n "$TOKEN_ADDRESS" ] && [ -n "$WALLET_ADDRESS" ]; then
        TOKEN_BAL=$(cast call "$TOKEN_ADDRESS" "balanceOf(address)(uint256)" "$WALLET_ADDRESS" --rpc-url "$BASE_SEPOLIA_RPC_URL" 2>/dev/null || echo "0")
        echo "Your token balance: $(cast from-wei "$TOKEN_BAL")"
    fi
}

# Main
case "$STEP" in
    1|token)
        deploy_token
        ;;
    2|vault)
        deploy_vault
        ;;
    3|mint)
        mint_tokens
        ;;
    4|order-via-vault)
        deploy_order_via_vault
        ;;
    all)
        deploy_token
        echo ""
        source .env
        deploy_vault
        echo ""
        source .env
        mint_tokens
        echo ""
        source .env
        deploy_order_via_vault
        ;;
    status)
        show_status
        ;;
    *)
        echo "Usage: $0 [step] --account <keystore> | --ledger"
        echo ""
        echo "Steps:"
        echo "  1 or token          - Deploy MockHOT token"
        echo "  2 or vault          - Deploy HoloLockVault"
        echo "  3 or mint           - Mint test tokens"
        echo "  4 or order-via-vault - Deploy claim order via vault"
        echo "  all                 - Run all steps"
        echo "  status              - Show deployment status"
        exit 1
        ;;
esac
