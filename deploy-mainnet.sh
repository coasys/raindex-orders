#!/usr/bin/env bash
# Deploys the HOT bridge on Ethereum mainnet, in one transaction, with a Safe as
# the vault admin from the start. DEPLOY.md, "Mainnet deploy":
#   ETH_RPC_URL=... ADMIN_ADDRESS=<the Safe> ADMIN_SAFE_THRESHOLD=2 ADMIN_SAFE_OWNERS=0x..,0x..,0x.. \
#   VALID_SIGNERS=0x..,0x..,0x.. SIGNER_THRESHOLD=2 ./deploy-mainnet.sh --ledger
# VALID_SIGNERS are the coupon signers, keys or Safes, and SIGNER_THRESHOLD how many
# of them sign each coupon. One key as the admin needs UNSAFE_ALLOW_SINGLE_KEY_ADMIN=yes.
set -euo pipefail
cd "$(dirname "$0")"
source script/forge-broadcast.sh

: "${ETH_RPC_URL:?ETH_RPC_URL is required}"
: "${ADMIN_ADDRESS:?ADMIN_ADDRESS is required}"
: "${VALID_SIGNERS:?VALID_SIGNERS is required: the coupon signers, separated by commas}"
: "${SIGNER_THRESHOLD:?SIGNER_THRESHOLD is required: how many of VALID_SIGNERS sign each coupon}"
require_wallet "$@"

script=script/DeployMainnet.s.sol:DeployMainnet
run_file="${FOUNDRY_BROADCAST:-broadcast}/DeployMainnet.s.sol/1/run-latest.json"
started=$(mktemp)
trap 'rm -f "$started"' EXIT

if ! forge script "$script" --rpc-url "$ETH_RPC_URL" --broadcast --slow "$@"; then
	if sent_since "$started" "$run_file"; then
		echo "The deploy stopped part way. It cannot be resumed: a new run deploys a new vault. It sent:" >&2
		landed "$run_file" >&2
	else
		echo "Nothing was sent." >&2
	fi
	exit 1
fi
sent_since "$started" "$run_file" || die "forge sent nothing."

echo "Sent:"
landed "$run_file"
deployer=$(jq -r '[.transactions[] | select(.transactionType == "CREATE" and .contractName == "HoloBridgeDeployer")][0].contractAddress // empty' "$run_file" 2>/dev/null) || true
block=$(first_block "$run_file")
record="forge script $script --rpc-url \$ETH_RPC_URL --sig 'record(address,uint256)'"
[[ $deployer =~ ^0x[0-9a-fA-F]{40}$ && $block =~ ^[1-9][0-9]*$ ]] ||
	die "The deploy landed. Do not run this again. Read the HoloBridgeDeployer and its block from $run_file, then run: $record <HoloBridgeDeployer> <block>"
forge script "$script" --rpc-url "$ETH_RPC_URL" --sig 'record(address,uint256)' "$deployer" "$block" ||
	die "The deploy landed: HoloBridgeDeployer $deployer in block $block. Do not run this again. Fix the above, then run: $record $deployer $block"
