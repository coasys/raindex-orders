#!/usr/bin/env bash
# Replaces the vault's claim order with one that accepts coupons signed by
# SIGNER_THRESHOLD of VALID_SIGNERS, as docs/enable-multisig.md describes: the
# signer list and the threshold are part of the order, so changing either is a
# new order. Source the current deploy record first. Then:
#   ./rotate-claim-signer.sh --ledger      an admin key signs and sends the calls
#   ./rotate-claim-signer.sh               a Safe admin: prints the calls for the Safe to execute
#   ./rotate-claim-signer.sh record BLOCK  prints the new deploy record once they have run
set -euo pipefail
cd "$(dirname "$0")"
source script/forge-broadcast.sh

case "${NETWORK:-base-sepolia}" in
mainnet) rpc_var=ETH_RPC_URL chain_id=1 rpc_url=${ETH_RPC_URL:-} ;;
base-sepolia) rpc_var=BASE_SEPOLIA_RPC_URL chain_id=84532 rpc_url=${BASE_SEPOLIA_RPC_URL:-https://sepolia.base.org} ;;
*) die "NETWORK must be base-sepolia or mainnet" ;;
esac
[[ -n $rpc_url ]] || die "$rpc_var is required for NETWORK=$NETWORK"

script=script/RotateClaimSigner.s.sol:RotateClaimSigner

if [[ ${1:-} == record ]]; then
	[[ ${2:-} =~ ^[0-9]+$ ]] || die "usage: $0 record <block of the first call>"
	exec forge script "$script" --rpc-url "$rpc_url" --sig 'record(uint256)' "$2"
fi

if [[ $# -eq 0 ]]; then
	exec forge script "$script" --rpc-url "$rpc_url"
fi

require_wallet "$@"
run_file="${FOUNDRY_BROADCAST:-broadcast}/RotateClaimSigner.s.sol/$chain_id/run-latest.json"
started=$(mktemp)
trap 'rm -f "$started"' EXIT

if ! forge script "$script" --rpc-url "$rpc_url" --broadcast --slow "$@"; then
	if sent_since "$started" "$run_file"; then
		echo "The rotation stopped part way. It sent:" >&2
		landed "$run_file" >&2
	else
		echo "Nothing was sent." >&2
	fi
	exit 1
fi
if ! sent_since "$started" "$run_file"; then
	echo "Nothing was sent."
	exit 0
fi

echo "Sent:"
landed "$run_file"
block=$(first_block "$run_file")
[[ -n $block ]] || die "The calls landed. Read the first call's block from $run_file, then run: $0 record <block>"
forge script "$script" --rpc-url "$rpc_url" --sig 'record(uint256)' "$block" ||
	die "The calls landed from block $block. Fix the above, then run: $0 record $block"
