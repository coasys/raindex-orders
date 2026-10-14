#!/usr/bin/env bash
# Rehearses a fresh TestNet deploy on an anvil fork of Base Sepolia, with one
# Safe as the vault admin and the coupon signer (DEPLOY.md, "Deploy the TestNet
# on Base Sepolia"):
#   test/base-sepolia-safe-rehearsal.sh
# deploy-base-sepolia.sh all-safe deploys mock HOT, creates the Safe through
# Safe's factory, and deploys the vault and claim order in one transaction. Then
# the orchestrator passes its startup checks against the fork with the Safe's
# owners at mock signer services, and the one-Safe proofs run on the fork.
# FORK_URL is the Base Sepolia RPC anvil forks. Every transaction goes to an
# anvil this script starts on 127.0.0.1, never to FORK_URL.
set -euo pipefail
cd "$(dirname "$0")/.."

FORK_URL=${FORK_URL:-https://sepolia.base.org}
ORCHESTRATOR=${ORCHESTRATOR:-bridge-orchestrator/target/debug/bridge-orchestrator}
PORT=${REHEARSAL_PORT:-18645}
fork=http://127.0.0.1:$PORT

unset ETH_RPC_URL BASE_SEPOLIA_RPC_URL NETWORK ADMIN_ADDRESS VALID_SIGNER ADMIN_SAFE_THRESHOLD ADMIN_SAFE_OWNERS \
	UNSAFE_ALLOW_SINGLE_KEY_ADMIN SAFE_OWNERS SAFE_THRESHOLD SAFE_SALT_NONCE TOKEN_ADDRESS PRIVATE_KEY
export FOUNDRY_DISABLE_NIGHTLY_WARNING=1

work=$(mktemp -d)
pids=()
cleanup() {
	for pid in "${pids[@]}"; do
		kill "$pid" 2>/dev/null || true
		wait "$pid" 2>/dev/null || true
	done
	rm -rf "$work"
}
trap cleanup EXIT
export FOUNDRY_BROADCAST=$work/broadcast FOUNDRY_CACHE_PATH=$work/cache

step() { printf '\n== %s\n' "$*"; }
fail() {
	echo "REHEARSAL FAILED: $*" >&2
	exit 1
}

[[ -x $ORCHESTRATOR ]] ||
	fail "build the orchestrator first: cargo build in bridge-orchestrator, on its pinned toolchain, or set ORCHESTRATOR"
ORCHESTRATOR=$(realpath "$ORCHESTRATOR")

step "Starting anvil: a fork of Base Sepolia on $fork"
cast chain-id --rpc-url "$fork" >/dev/null 2>&1 && fail "something already answers on $fork"
anvil --host 127.0.0.1 --port "$PORT" --silent --fork-url "$FORK_URL" &
pids+=("$!")
for _ in $(seq 120); do
	[[ $(cast rpc web3_clientVersion --rpc-url "$fork" 2>/dev/null) == '"anvil/'* ]] && break
	sleep 0.5
done
[[ $(cast chain-id --rpc-url "$fork") == 84532 ]] || fail "the fork is not Base Sepolia, chain 84532"

address_of() { cast wallet address --private-key "$1"; }
fresh_key() { cast wallet new --json | jq -r '.data[0].private_key'; }
# Anvil's account 0 carries an EIP-7702 delegation on Base Sepolia: on the fork it
# is a plain key again, with ETH, and signs from a keystore as on Base Sepolia.
deployer_key=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
deployer=$(address_of "$deployer_key")
cast rpc anvil_setCode "$deployer" 0x --rpc-url "$fork" >/dev/null
cast rpc anvil_setBalance "$deployer" 0x3635C9ADC5DEA00000 --rpc-url "$fork" >/dev/null
cast wallet import deployer --private-key "$deployer_key" --keystore-dir "$work/keys" \
	--unsafe-password rehearsal >/dev/null
wallet=(--keystore "$work/keys/deployer" --password rehearsal)
nonce() { cast nonce "$deployer" --rpc-url "$fork"; }

owner_keys=("$(fresh_key)" "$(fresh_key)" "$(fresh_key)")
owners=$(for key in "${owner_keys[@]}"; do address_of "$key"; done | paste -sd,)
owner() { address_of "${owner_keys[$1]}"; }

step "deploy-base-sepolia.sh all-safe: mock HOT, the Safe, and the bridge in one transaction"
# The env file is .env.example, as an operator starts from, pointed at the fork.
sed "s|^BASE_SEPOLIA_RPC_URL=.*|BASE_SEPOLIA_RPC_URL=$fork|" .env.example >"$work/deploy.env"
printf 'SAFE_OWNERS=%s\nSAFE_THRESHOLD=2\n' "$owners" >>"$work/deploy.env"
ENV_FILE=$work/deploy.env ./deploy-base-sepolia.sh all-safe "${wallet[@]}" | tee "$work/deploy.log"
# shellcheck source=/dev/null
source "$work/deploy.env"
safe=$ADMIN_ADDRESS
[[ -n $safe && $VALID_SIGNER == "$safe" && $CLAIM_SIGNER == "$safe" ]] ||
	fail "the env file does not name the Safe as ADMIN_ADDRESS, VALID_SIGNER and CLAIM_SIGNER"
[[ $(cast storage "$safe" 0 --rpc-url "$fork") == "$(cast to-uint256 0x29fcB43b46531BcA003ddC8FCB67FFE91900C762)" ]] ||
	fail "the Safe does not run the SafeL2 1.4.1 singleton"
[[ $(cast call --rpc-url "$fork" "$safe" 'getThreshold()(uint256)') == 2 ]] || fail "the Safe's threshold is not 2"
[[ $(cast call --rpc-url "$fork" "$BASE_SEPOLIA_LOCK_VAULT_ADDRESS" 'admin()(address)') == "$safe" ]] ||
	fail "the vault's admin is not the Safe"
grep -qF "VALID_SIGNER is ADMIN_ADDRESS $safe: one Safe is the vault admin and the coupon signer" "$work/deploy.log" ||
	fail "the deploy did not say one Safe holds both roles"
run_file=$work/broadcast/DeployBridge.s.sol/84532/run-latest.json
[[ $(jq '[.transactions[]] | length' "$run_file") == 1 ]] || fail "the bridge deploy sent other than one transaction"
bridge_deployer=$(jq -r '.transactions[0].contractAddress' "$run_file")
deploy_block=$(printf '%d' "$(jq -r '.receipts[0].blockNumber' "$run_file")")
echo "the Safe $safe is the vault admin and the coupon signer, from block $deploy_block"
before=$(nonce)
ENV_FILE=$work/deploy.env ./deploy-base-sepolia.sh safe "${wallet[@]}" >"$work/again.log"
grep -qF "The Safe exists, with these owners and threshold. Nothing was sent: $safe" "$work/again.log" ||
	fail "the safe step did not find the Safe again"
[[ $(nonce) == "$before" ]] || fail "the safe step sent a transaction for a Safe that exists"
echo "found again, sending nothing: $safe"

step "Starting mock signer services for the Safe's three owners (no Holochain checks)"
service_port=$((PORT + 10))
for i in 0 1 2; do
	env -i PATH="$PATH" OWNER_KEY="${owner_keys[$i]}" SAFE="$safe" CHAIN_ID=84532 PORT=$((service_port + i)) \
		ORDER_HASH="$ORDER_HASH" ORDER_OWNER="$ORDER_OWNER" ORDERBOOK_ADDRESS="$ORDERBOOK_ADDRESS" \
		TOKEN_ADDRESS="$TOKEN_ADDRESS" VAULT_ID="$VAULT_ID" \
		node ui/scripts/mock-signer-service.mjs >"$work/service-$i.log" 2>&1 &
	pids+=("$!")
done
for i in 0 1 2; do
	for _ in $(seq 40); do
		curl -sf "http://127.0.0.1:$((service_port + i))/signer" >/dev/null && break
		sleep 0.25
	done
done

# Starts `bridge-orchestrator run` against the fork with the deploy record and
# `settings`, with no Holochain node: it gets past its startup checks only to
# stop where it needs the node.
orchestrate() {
	local dir
	dir=$(mktemp -d -p "$work")
	printf 'keystore:\n  type: lair_server\n  connection_url: unix:///%s/no-lair?k=abc\ndb_sync_level: Full\n' \
		"$dir" >"$dir/conductor-config.yaml"
	(
		cd "$dir"
		env -i PATH="$PATH" NETWORK=base-sepolia BASE_SEPOLIA_RPC_URL="$fork" \
			BASE_SEPOLIA_LOCK_VAULT_ADDRESS="$BASE_SEPOLIA_LOCK_VAULT_ADDRESS" TOKEN_ADDRESS="$TOKEN_ADDRESS" \
			ORDER_HASH="$ORDER_HASH" ORDER_OWNER="$ORDER_OWNER" CLAIM_SIGNER="$CLAIM_SIGNER" \
			CLAIM_BYTECODE="$CLAIM_BYTECODE" CLAIM_INPUT_TOKEN="$CLAIM_INPUT_TOKEN" "$@" \
			HOLOCHAIN_BRIDGING_AGENT_PUBKEY=uhCAkYoBhEs3GyOWslej78VfMRmSSdc2TXsRQmqFn5b3v8jl58Kkj \
			DB_PATH="$dir/bridge.db" CONDUCTOR_CONFIG="$dir/conductor-config.yaml" \
			LAIR_PASSPHRASE_FILE="$dir/no-passphrase" "$ORCHESTRATOR" run 2>&1 || true
	)
}
expect_startup() {
	local what=$1
	shift
	orchestrate "$@" >"$work/orchestrator.log"
	grep -qF "startup checks passed" "$work/orchestrator.log" || {
		cat "$work/orchestrator.log"
		fail "the orchestrator did not pass its startup checks $what"
	}
	echo "passed its startup checks $what"
}

step "Starting the orchestrator against the fork"
expect_startup "with the Safe's 3 owners at their signer services" \
	SAFE_OWNER_SERVICES="$(owner 0)=http://127.0.0.1:$service_port,$(owner 1)=http://127.0.0.1:$((service_port + 1)),$(owner 2)=http://127.0.0.1:$((service_port + 2))"
grep -qF "the claim order took the probe signed by 2 owners of CLAIM_SIGNER $safe, and refused it signed by 1" \
	"$work/orchestrator.log" || fail "the orchestrator did not probe with 2 owner signatures and with 1"
expect_startup "with the keys of 2 of the Safe's owners" SAFE_OWNER_KEYS="${owner_keys[1]},${owner_keys[2]}"

step "Proving the TestNet on the fork: one Safe is the vault admin and the coupon signer"
REHEARSAL=true REHEARSAL_RPC_URL=$fork REHEARSAL_TOKEN=$TOKEN_ADDRESS \
	MAINNET_LOCK_VAULT_ADDRESS=$BASE_SEPOLIA_LOCK_VAULT_ADDRESS ORDER_HASH=$ORDER_HASH \
	PUBLIC_CLAIM_INTERPRETER=0x4c52eee7Fb6aeD0F1a30130d96d02409D9d886cf \
	PUBLIC_CLAIM_STORE=0x1Aa775533E28B1D843e1A589034984E3a62005DC \
	PUBLIC_CLAIM_BYTECODE=$CLAIM_BYTECODE PUBLIC_CLAIM_INPUT_TOKEN=$CLAIM_INPUT_TOKEN \
	BRIDGE_SAFE=$safe HOLO_BRIDGE_DEPLOYER=$bridge_deployer REHEARSAL_DEPLOY_BLOCK=$deploy_block \
	REHEARSAL_DEPLOYER=$deployer REHEARSAL_SIGNER_KEY="${owner_keys[0]}" \
	REHEARSAL_BRIDGE_OWNER_KEYS="${owner_keys[2]},${owner_keys[0]}" \
	REHEARSAL_BRIDGE_ONE_OWNER_KEY="${owner_keys[1]}" \
	forge test --match-path test/rehearsal/MainnetForkRehearsal.t.sol --match-contract OneSafeRehearsal -vv

step "Base Sepolia fork rehearsal passed"
