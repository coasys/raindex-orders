#!/usr/bin/env bash
# Rehearses the mainnet deploy, with a Safe as the vault admin from the first
# transaction and a claim order that takes coupons signed by 2 of 3 keys, then
# its rotation to one that takes coupons signed by 2 of two of those keys and a
# Safe, on an anvil fork of Ethereum mainnet:
#   nix develop -c test/fork-rehearsal.sh
# FORK_URL is the mainnet RPC anvil forks. Every transaction goes to an anvil
# this script starts on 127.0.0.1, never to FORK_URL.
set -euo pipefail
cd "$(dirname "$0")/.."

FORK_URL=${FORK_URL:-https://ethereum-rpc.publicnode.com}
ORCHESTRATOR=${ORCHESTRATOR:-bridge-orchestrator/target/debug/bridge-orchestrator}
PORT=${REHEARSAL_PORT:-18545}
fork=http://127.0.0.1:$PORT
plain=http://127.0.0.1:$((PORT + 1))

unset ETH_RPC_URL SEPOLIA_RPC_URL ADMIN_ADDRESS VALID_SIGNER VALID_SIGNERS SIGNER_THRESHOLD \
	ADMIN_SAFE_THRESHOLD ADMIN_SAFE_OWNERS UNSAFE_ALLOW_SINGLE_KEY_ADMIN
export FOUNDRY_DISABLE_NIGHTLY_WARNING=1

work=$(mktemp -d)
anvils=()
cleanup() {
	for pid in "${anvils[@]}"; do
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

start_anvil() {
	local url=$1 pid
	shift
	cast chain-id --rpc-url "$url" >/dev/null 2>&1 && fail "something already answers on $url"
	anvil --host 127.0.0.1 --port "${url##*:}" --silent "$@" &
	pid=$!
	anvils+=("$pid")
	for _ in $(seq 120); do
		kill -0 "$pid" 2>/dev/null || fail "anvil on $url exited"
		[[ $(cast rpc web3_clientVersion --rpc-url "$url" 2>/dev/null) == '"anvil/'* ]] && return
		sleep 0.5
	done
	fail "anvil on $url did not start"
}

# Anvil's own accounts, from its published test mnemonic.
keys=(
	0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
	0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d
	0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a
	0x7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6
	0x47e179ec197488593b187f80a00eb0da91f1b9d0b13f8733639f19c30a34926a
	0x8b3a350cf5c34c9194ca85829a2df0ec3153be0318b5e2d3348e872092edffba
	0x92db14e403b83dfe3df233f83dfa3a0d7096f21ca9b0d6d6b8d88b2b4ec1564e
	0x4bbbf85ce3377467afe5d46f804f221813b2bb87f24d81f60f1fcdbf7cbf4356
	0xdbda1821b80551c9d65939329250298aa3472ba22feea921c0cf5d620ea67b97
	0x2a871d0798f97d79848a013d4936a73bf4ae7b1cfd0dddbdf9ad2d28c75e78c3
)
address_of() { cast wallet address --private-key "$1"; }
# Anvil's accounts carry EIP-7702 delegations on mainnet, which Raindex V6 refuses
# as coupon signers (it asks a delegated key's delegate through EIP-1271), so the
# coupon signers are fresh keys. A Safe's owners sign with ecrecover, so anvil's
# accounts serve as owners.
fresh_key() { cast wallet new --json | jq -r '.data[0].private_key'; }
deployer_key=${keys[0]} admin_key=${keys[1]} other_signer_key=$(fresh_key)
deployer=$(address_of "$deployer_key")
admin=$(address_of "$admin_key")
other_signer=$(address_of "$other_signer_key")
# The launch's claim order lists these three keys, and takes coupons 2 of them sign.
signer_keys=("$(fresh_key)" "$(fresh_key)" "$(fresh_key)")
signers=()
for key in "${signer_keys[@]}"; do signers+=("$(address_of "$key")"); done
launch_signers=$(IFS=,; echo "${signers[*]}")
test_signer=0x8E72b7568738da52ca3DCd9b24E178127A4E7d37

# The deployer signs from an encrypted keystore, as on mainnet.
cast wallet import deployer --private-key "$deployer_key" --keystore-dir "$work/keys" \
	--unsafe-password rehearsal >/dev/null
wallet=(--keystore "$work/keys/deployer" --password rehearsal)

record_value() { grep -oE "$1=0x[0-9a-fA-F]+" "$2" | tail -1 | cut -d= -f2 || true; }
# A list of addresses, or a number, in the deploy record `log`, in lower case.
record_list() { grep -oE "(^| )$1=[0-9a-fA-Fx,]+" "$2" | tail -1 | cut -d= -f2 | tr 'A-F' 'a-f' || true; }
lower() { tr 'A-F' 'a-f' <<<"$1"; }
nonce() { cast nonce "$deployer" --rpc-url "$1"; }
next_block() { echo $(($(cast block-number --rpc-url "$fork") + 1)); }

# Runs deploy-mainnet.sh against `url`, which must refuse, naming `reason`, and
# send nothing.
expect_refusal() {
	local url=$1 reason=$2 log=$work/refusal.log before
	shift 2
	before=$(nonce "$url")
	if env ETH_RPC_URL="$url" "$@" >"$log" 2>&1; then
		cat "$log"
		fail "deploy-mainnet.sh did not refuse: $reason"
	fi
	grep -qF -- "$reason" "$log" || {
		cat "$log"
		fail "deploy-mainnet.sh refused without naming: $reason"
	}
	[[ $(nonce "$url") == "$before" ]] || fail "deploy-mainnet.sh sent a transaction while refusing: $reason"
	echo "refused, sending nothing: $reason"
}

[[ -x $ORCHESTRATOR ]] ||
	fail "build the orchestrator first: cargo build in bridge-orchestrator, on its pinned toolchain, or set ORCHESTRATOR"
ORCHESTRATOR=$(realpath "$ORCHESTRATOR")

step "Starting anvil: a fork of mainnet on $fork, and a chain 31337 on $plain"
start_anvil "$fork" --fork-url "$FORK_URL"
start_anvil "$plain"
[[ $(cast chain-id --rpc-url "$fork") == 1 ]] || fail "the fork is not chain 1"

safe() {
	forge script test/rehearsal/RehearsalSafe.s.sol:RehearsalSafe --rpc-url "$fork" --broadcast \
		--private-key "$deployer_key" "$@"
}
create_safe() {
	local threshold=$1 salt=$2 owners=() key
	shift 2
	for key in "$@"; do owners+=("$(address_of "$key")"); done
	safe --sig 'create(address[],uint256,uint256)' "[$(IFS=,; echo "${owners[*]}")]" "$threshold" "$salt" |
		grep -oE 'SAFE=0x[0-9a-fA-F]{40}' | cut -d= -f2 || true
}
owners_of() {
	local owners=() key
	for key in "$@"; do owners+=("$(address_of "$key")"); done
	IFS=,
	echo "${owners[*]}"
}
admin_owner_keys=("${keys[4]}" "${keys[5]}" "${keys[6]}")
signer_owner_keys=("${keys[7]}" "${keys[8]}" "${keys[9]}")

step "Creating Safes of 3 anvil accounts on the fork: two that need 2 signatures, one that needs 1"
admin_safe=$(create_safe 2 1 "${admin_owner_keys[@]}")
signer_safe=$(create_safe 2 2 "${signer_owner_keys[@]}")
single_safe=$(create_safe 1 3 "${signer_owner_keys[@]}")
[[ -n $admin_safe && -n $signer_safe && -n $single_safe ]] || fail "a Safe was not created"
admin_owners=$(owners_of "${admin_owner_keys[@]}")
signer_owners=$(owners_of "${signer_owner_keys[@]}")
echo "admin Safe $admin_safe, signer Safe $signer_safe"
# The rotated claim order lists keys 0 and 1 and the signer Safe, 2 signing each coupon.
rotated_signers="${signers[0]},${signers[1]},$signer_safe"

step "The deploy refuses before it sends anything"
inputs=(ADMIN_ADDRESS="$admin_safe" ADMIN_SAFE_THRESHOLD=2 ADMIN_SAFE_OWNERS="$admin_owners"
	VALID_SIGNERS="$launch_signers" SIGNER_THRESHOLD=2)
deploy=(./deploy-mainnet.sh "${wallet[@]}")
expect_refusal "$plain" "the RPC answers for chain 31337, and NETWORK=mainnet is chain 1" \
	env "${inputs[@]}" "${deploy[@]}"
expect_refusal "$fork" "ADMIN_ADDRESS is required" \
	env -u ADMIN_ADDRESS VALID_SIGNERS="$launch_signers" SIGNER_THRESHOLD=2 "${deploy[@]}"
expect_refusal "$fork" "pass the signer as a forge wallet option" \
	env "${inputs[@]}" ./deploy-mainnet.sh
expect_refusal "$fork" "--private-key takes a raw key" \
	env "${inputs[@]}" ./deploy-mainnet.sh --private-key "$deployer_key"
echo "-- the coupon signers: 1 to 15 of them, none twice, and a threshold from 1 to their number"
expect_refusal "$fork" "VALID_SIGNERS is required" \
	env "${inputs[@]}" env -u VALID_SIGNERS "${deploy[@]}"
expect_refusal "$fork" "SIGNER_THRESHOLD is required" \
	env "${inputs[@]}" env -u SIGNER_THRESHOLD "${deploy[@]}"
expect_refusal "$fork" "VALID_SIGNER is replaced by VALID_SIGNERS" \
	env "${inputs[@]}" VALID_SIGNER="${signers[0]}" "${deploy[@]}"
expect_refusal "$fork" "VALID_SIGNERS names $test_signer, the test signer, whose key is public: mainnet refuses it" \
	env "${inputs[@]}" VALID_SIGNERS="${signers[0]},$test_signer,${signers[2]}" "${deploy[@]}"
expect_refusal "$fork" "VALID_SIGNERS names $(address_of "${keys[2]}"), which has an EIP-7702 delegation" \
	env "${inputs[@]}" VALID_SIGNERS="${signers[0]},${signers[1]},$(address_of "${keys[2]}")" "${deploy[@]}"
expect_refusal "$fork" "VALID_SIGNERS names $single_safe, a contract but not a Safe whose threshold is 2 to 20" \
	env "${inputs[@]}" VALID_SIGNERS="${signers[0]},${signers[1]},$single_safe" "${deploy[@]}"
expect_refusal "$fork" "VALID_SIGNERS lists ${signers[0]} twice" \
	env "${inputs[@]}" VALID_SIGNERS="${signers[0]},${signers[1]},${signers[0]}" "${deploy[@]}"
expect_refusal "$fork" "SIGNER_THRESHOLD is 4, and must be 1 to the 3 signers VALID_SIGNERS lists" \
	env "${inputs[@]}" SIGNER_THRESHOLD=4 "${deploy[@]}"
expect_refusal "$fork" "SIGNER_THRESHOLD is 0, and must be 1 to the 3 signers VALID_SIGNERS lists" \
	env "${inputs[@]}" SIGNER_THRESHOLD=0 "${deploy[@]}"
# Rainlang 0.1.9's parser takes at most 255 operations in a source: 5 of 5 is more.
five=()
for _ in 1 2 3 4 5; do five+=("$(address_of "$(fresh_key)")"); done
expect_refusal "$fork" "--threshold 5 of 5 signers needs" \
	env "${inputs[@]}" VALID_SIGNERS="$(IFS=,; echo "${five[*]}")" SIGNER_THRESHOLD=5 "${deploy[@]}"
grep -qF "and the deployed parser takes at most 255: list fewer signers or lower the threshold" "$work/refusal.log" ||
	fail "the deploy refused 5 of 5 without naming the parser's limit"
echo "-- the vault admin must be a Safe of threshold 2 or more, the one meant"
expect_refusal "$fork" "ADMIN_ADDRESS $admin is a key, not a Safe" \
	env "${inputs[@]}" ADMIN_ADDRESS="$admin" "${deploy[@]}"
expect_refusal "$fork" "ADMIN_ADDRESS $deployer is a key, not a Safe" \
	env "${inputs[@]}" ADMIN_ADDRESS="$deployer" "${deploy[@]}"
expect_refusal "$fork" "ADMIN_ADDRESS is the deployer" \
	env "${inputs[@]}" ADMIN_ADDRESS="$deployer" UNSAFE_ALLOW_SINGLE_KEY_ADMIN=yes "${deploy[@]}"
expect_refusal "$fork" "is a Safe of threshold 1 with 3 owners, which one key controls" \
	env "${inputs[@]}" ADMIN_ADDRESS="$single_safe" ADMIN_SAFE_THRESHOLD=1 ADMIN_SAFE_OWNERS="$signer_owners" "${deploy[@]}"
expect_refusal "$fork" "is a contract but not a Safe" \
	env "${inputs[@]}" ADMIN_ADDRESS=0x37FC0EFec37D19f8A221aa4F8F7600C9ba2AcD20 "${deploy[@]}"
expect_refusal "$fork" "ADMIN_SAFE_THRESHOLD is required" \
	env "${inputs[@]}" env -u ADMIN_SAFE_THRESHOLD "${deploy[@]}"
expect_refusal "$fork" "is a Safe of threshold 2 with 3 owners, not ADMIN_SAFE_THRESHOLD=3" \
	env "${inputs[@]}" ADMIN_SAFE_THRESHOLD=3 "${deploy[@]}"
expect_refusal "$fork" "ADMIN_SAFE_OWNERS is required" \
	env "${inputs[@]}" env -u ADMIN_SAFE_OWNERS "${deploy[@]}"
expect_refusal "$fork" "ADMIN_SAFE_OWNERS does not list the owners of ADMIN_ADDRESS $admin_safe" \
	env "${inputs[@]}" ADMIN_SAFE_OWNERS="$signer_owners" "${deploy[@]}"
expect_refusal "$fork" "ADMIN_SAFE_OWNERS does not list the owners of ADMIN_ADDRESS $admin_safe" \
	env "${inputs[@]}" ADMIN_SAFE_OWNERS="$(owners_of "${admin_owner_keys[0]}" "${admin_owner_keys[1]}")" "${deploy[@]}"

# Reads the deploy record `log` into the variables the proofs and the
# orchestrator take.
read_record() {
	local log=$1
	vault=$(record_value MAINNET_LOCK_VAULT_ADDRESS "$log")
	order_hash=$(record_value ORDER_HASH "$log")
	interpreter=$(record_value PUBLIC_CLAIM_INTERPRETER "$log")
	store=$(record_value PUBLIC_CLAIM_STORE "$log")
	bytecode=$(record_value PUBLIC_CLAIM_BYTECODE "$log")
	input_token=$(record_value PUBLIC_CLAIM_INPUT_TOKEN "$log")
	bridge_deployer=$(record_value HoloBridgeDeployer "$log")
	[[ -n $vault && -n $order_hash && -n $interpreter && -n $store && -n $bytecode && -n $input_token &&
		-n $bridge_deployer ]] || fail "the deploy printed no complete deploy record"
}

step "Deploying: the admin Safe is the vault admin from the first transaction, 2 of 3 keys sign coupons"
deploy_block=$(next_block)
ETH_RPC_URL=$fork env "${inputs[@]}" ./deploy-mainnet.sh "${wallet[@]}" | tee "$work/deploy.log"
grep -qF "ADMIN_ADDRESS $admin_safe is a Safe of threshold 2 with 3 owners" "$work/deploy.log" ||
	fail "the deploy did not print the admin Safe's threshold and owners"
[[ $(grep -c "succeeded in block" "$work/deploy.log") == 1 ]] || fail "the deploy sent more than one transaction"
read_record "$work/deploy.log"
[[ $(cast call --rpc-url "$fork" "$vault" 'admin()(address)') == "$admin_safe" ]] ||
	fail "the vault's admin is not the admin Safe"
[[ $(record_list CLAIM_SIGNERS "$work/deploy.log") == $(lower "$launch_signers") &&
	$(record_list CLAIM_THRESHOLD "$work/deploy.log") == 2 ]] ||
	fail "the deploy record does not name the 3 signers and threshold 2"

proofs() {
	REHEARSAL=true REHEARSAL_RPC_URL=$fork MAINNET_LOCK_VAULT_ADDRESS=$vault \
		REHEARSAL_DEPLOYER=$deployer REHEARSAL_SIGNER_KEYS="$(IFS=,; echo "${signer_keys[*]}")" \
		forge test --match-path test/rehearsal/MainnetForkRehearsal.t.sol -vv "$@"
}

# Starts `bridge-orchestrator run` on the fork with the deploy record in `record`
# and the key settings `settings`, with no Holochain node: it gets past its
# startup checks only to stop where it needs the node. The conductor config it
# is given is durable and names a lair socket that is not there, which is where
# it stops. Prints what it logged.
orchestrate() {
	local record=$1 dir
	shift
	dir=$(mktemp -d -p "$work")
	printf 'keystore:\n  type: lair_server\n  connection_url: unix:///%s/no-lair?k=abc\ndb_sync_level: Full\n' \
		"$dir" >"$dir/conductor-config.yaml"
	(
		cd "$dir"
		mapfile -t lines < <(sed -n '/bridge-orchestrator:/,/website:/p' "$record" | grep -oE '[A-Z_]+=[^ ]+')
		env -i PATH="$PATH" "${lines[@]}" ETH_RPC_URL="$fork" "$@" \
			HOLOCHAIN_BRIDGING_AGENT_PUBKEY=uhCAkYoBhEs3GyOWslej78VfMRmSSdc2TXsRQmqFn5b3v8jl58Kkj \
			DB_PATH="$dir/bridge.db" CONDUCTOR_CONFIG="$dir/conductor-config.yaml" \
			LAIR_PASSPHRASE_FILE="$dir/no-passphrase" "$ORCHESTRATOR" run 2>&1 || true
	)
}
# The orchestrator must pass its startup checks with `record` and the key
# settings that follow.
expect_startup() {
	local record=$1 what=$2
	shift 2
	orchestrate "$record" "$@" >"$work/orchestrator.log"
	grep -qF "startup checks passed" "$work/orchestrator.log" || {
		cat "$work/orchestrator.log"
		fail "the orchestrator did not pass its startup checks $what"
	}
	echo "passed its startup checks $what"
}
# The orchestrator must refuse to start, naming `reason`.
expect_orchestrator_refusal() {
	local record=$1 reason=$2
	shift 2
	orchestrate "$record" "$@" >"$work/orchestrator.log"
	grep -qF "startup checks passed" "$work/orchestrator.log" && {
		cat "$work/orchestrator.log"
		fail "the orchestrator started: $reason"
	}
	grep -qF -- "$reason" "$work/orchestrator.log" || {
		cat "$work/orchestrator.log"
		fail "the orchestrator refused without naming: $reason"
	}
	echo "refused: $reason"
}

# The deploy record `log` with `from` replaced by `to`.
edited() { sed "s/$2/$3/g" "$1" >"$work/edited-$4.log" && echo "$work/edited-$4.log"; }

step "Starting the orchestrator against the deployed claim order"
expect_startup "$work/deploy.log" "with 2 of the 3 signers' keys" \
	SIGNER_PRIVATE_KEY="${signer_keys[0]},${signer_keys[1]}"
grep -qF "the order takes coupons from 2 of its signers" "$work/orchestrator.log" ||
	fail "the orchestrator did not log the threshold"
expect_startup "$work/deploy.log" "with all 3 signers' keys" \
	SIGNER_PRIVATE_KEY="${signer_keys[2]},${signer_keys[0]},${signer_keys[1]}"
expect_orchestrator_refusal "$work/deploy.log" \
	"this orchestrator signs for 1 of CLAIM_SIGNERS, and each coupon needs CLAIM_THRESHOLD=2" \
	SIGNER_PRIVATE_KEY="${signer_keys[0]}"
expect_orchestrator_refusal "$work/deploy.log" \
	"SIGNER_PRIVATE_KEY signs for $other_signer, which CLAIM_SIGNERS does not list" \
	SIGNER_PRIVATE_KEY="${signer_keys[0]},$other_signer_key"
expect_orchestrator_refusal "$work/deploy.log" \
	"${signers[1]} is signed for twice" \
	SIGNER_PRIVATE_KEY="${signer_keys[1]},${signer_keys[1]}"
expect_orchestrator_refusal "$work/deploy.log" \
	"SAFE_SIGNER ${signers[0]} has no contract, so it is a key, not a Safe, and SAFE_OWNER_KEYS signs for a Safe" \
	SAFE_SIGNER="${signers[0]}" SAFE_OWNER_KEYS="${signer_owner_keys[0]},${signer_owner_keys[1]}" \
	SIGNER_PRIVATE_KEY="${signer_keys[1]}"
echo "-- its probe of the deployed order catches a record whose signers or threshold are not the order's"
expect_orchestrator_refusal "$(edited "$work/deploy.log" "CLAIM_THRESHOLD=2" "CLAIM_THRESHOLD=1" m1)" \
	"the claim order ORDER_HASH reads more seats than the 1 of CLAIM_THRESHOLD" \
	SIGNER_PRIVATE_KEY="${signer_keys[0]}"
expect_orchestrator_refusal "$(edited "$work/deploy.log" "CLAIM_THRESHOLD=2" "CLAIM_THRESHOLD=3" m3)" \
	"the claim order ORDER_HASH took a coupon from 2 of CLAIM_SIGNERS (${signers[0]}, ${signers[1]}), fewer than CLAIM_THRESHOLD=3: its threshold is lower" \
	SIGNER_PRIVATE_KEY="$(IFS=,; echo "${signer_keys[*]}")"
expect_orchestrator_refusal "$(edited "$work/deploy.log" "${signers[0]}" "$other_signer" other)" \
	"does not accept coupons from 2 of CLAIM_SIGNERS ($other_signer, ${signers[1]}): it answered \"Wrong signer\"" \
	SIGNER_PRIVATE_KEY="$other_signer_key,${signer_keys[1]}"

step "Proving the launched bridge on the fork: the Safe admin and coupons signed by 2 of 3 keys"
ORDER_HASH=$order_hash PUBLIC_CLAIM_INTERPRETER=$interpreter PUBLIC_CLAIM_STORE=$store \
	PUBLIC_CLAIM_BYTECODE=$bytecode PUBLIC_CLAIM_INPUT_TOKEN=$input_token \
	ADMIN_SAFE=$admin_safe HOLO_BRIDGE_DEPLOYER=$bridge_deployer REHEARSAL_DEPLOY_BLOCK=$deploy_block \
	REHEARSAL_ADMIN_OWNER_KEYS="${admin_owner_keys[0]},${admin_owner_keys[1]}" \
	proofs --match-contract LaunchRehearsal

step "Acting as the admin Safe on the fork with 2 owner signatures"
min_lock_amount=2000000000000000000
REHEARSAL_OWNER_KEYS="${admin_owner_keys[0]},${admin_owner_keys[1]}" safe \
	--sig 'exec(address,address,bytes)' "$admin_safe" "$vault" \
	"$(cast calldata 'setMinLockAmount(uint256)' "$min_lock_amount")" >/dev/null
[[ $(cast call --rpc-url "$fork" "$vault" 'minLockAmount()(uint256)' | cut -d' ' -f1) == "$min_lock_amount" ]] ||
	fail "the admin Safe's setMinLockAmount did not take effect"
echo "minLockAmount is $min_lock_amount, set by the admin Safe"

step "Rotating the claim order to 2 of keys 0 and 1 and the signer Safe through rotate-claim-signer.sh"
rotation=(NETWORK=mainnet ETH_RPC_URL="$fork" MAINNET_LOCK_VAULT_ADDRESS="$vault" ORDER_HASH="$order_hash"
	PUBLIC_CLAIM_BYTECODE="$bytecode" PUBLIC_CLAIM_INPUT_TOKEN="$input_token"
	VALID_SIGNERS="$rotated_signers" SIGNER_THRESHOLD=2)
# rotate-claim-signer.sh, given `settings`, must refuse naming `reason`.
expect_rotation_refusal() {
	local reason=$1
	shift
	if env "${rotation[@]}" "$@" ./rotate-claim-signer.sh >"$work/refusal.log" 2>&1; then
		fail "rotate-claim-signer.sh did not refuse: $reason"
	fi
	grep -qF -- "$reason" "$work/refusal.log" || {
		cat "$work/refusal.log"
		fail "rotate-claim-signer.sh refused without naming: $reason"
	}
	echo "refused: $reason"
}
expect_rotation_refusal "VALID_SIGNERS names $test_signer, the test signer" \
	VALID_SIGNERS="${signers[0]},$test_signer"
expect_rotation_refusal "VALID_SIGNERS names $single_safe, a contract but not a Safe whose threshold is 2 to 20" \
	VALID_SIGNERS="${signers[0]},${signers[1]},$single_safe"
expect_rotation_refusal "VALID_SIGNERS lists $signer_safe twice" \
	VALID_SIGNERS="$signer_safe,${signers[0]},$signer_safe"
safe_calls() { grep -oE '[0-9]+\. to 0x[0-9a-fA-F]{40}, value 0, data 0x[0-9a-fA-F]+' "$1" || true; }
# Executes each printed call from the admin Safe, signed by two of its owners.
execute() {
	local call to data
	for call in "$@"; do
		to=$(grep -oE 'to 0x[0-9a-fA-F]{40}' <<<"$call" | cut -d' ' -f2)
		data=$(grep -oE 'data 0x[0-9a-fA-F]+' <<<"$call" | cut -d' ' -f2)
		REHEARSAL_OWNER_KEYS="${admin_owner_keys[0]},${admin_owner_keys[2]}" safe \
			--sig 'exec(address,address,bytes)' "$admin_safe" "$to" "$data" >/dev/null
	done
}
env "${rotation[@]}" ./rotate-claim-signer.sh | tee "$work/rotate.log"
mapfile -t calls < <(safe_calls "$work/rotate.log")
[[ ${#calls[@]} == 2 ]] || fail "rotate-claim-signer.sh did not print the 2 Safe calls"

# Runs the printed calls on a snapshot of the fork, expects record to refuse
# naming `reason`, then reverts the fork.
expect_record_refusal() {
	local reason=$1 snapshot from_block
	shift
	snapshot=$(cast rpc evm_snapshot --rpc-url "$fork" | tr -d '"')
	from_block=$(next_block)
	execute "$@"
	if env "${rotation[@]}" ./rotate-claim-signer.sh record "$from_block" >"$work/refusal.log" 2>&1; then
		fail "the record passed: $reason"
	fi
	grep -qF "$reason" "$work/refusal.log" || fail "the record refused without naming: $reason"
	[[ $(cast rpc evm_revert "$snapshot" --rpc-url "$fork") == true ]] || fail "the fork did not revert"
	echo "refused: a record when $reason"
}

# A V6 order is its bytecode, so the same signers and threshold give the same
# order, which the orderbook already holds: the second order is for other signers.
env "${rotation[@]}" VALID_SIGNERS="$other_signer,${signers[1]}" ./rotate-claim-signer.sh >"$work/rogue.log" ||
	fail "rotate-claim-signer.sh did not print the calls for a second order"
mapfile -t rogue < <(safe_calls "$work/rogue.log")
[[ ${#rogue[@]} == 2 ]] || fail "rotate-claim-signer.sh did not print the 2 calls for a second order"
expect_record_refusal "the vault holds another order" "${rogue[0]}" "${calls[@]}"

# The claim order's call names the network's interpreter; one naming another
# address adds, since the orderbook does not check it, and the record must refuse it.
padded() { printf '%064s' "$(tr 'A-F' 'a-f' <<<"${1#0x}")" | tr ' ' 0; }
other_interpreter=$(address_of "${keys[3]}")
misrun=${calls[0]//$(padded "$interpreter")/$(padded "$other_interpreter")}
[[ $misrun != "${calls[0]}" ]] || fail "the claim order's call names no interpreter to replace"
expect_record_refusal "not run by the network's interpreter and store" "$misrun" "${calls[1]}"

from_block=$(next_block)
execute "${calls[@]}"
# The record must name the signers and threshold the new order was composed for.
expect_record_mismatch() {
	if env "${rotation[@]}" "$@" ./rotate-claim-signer.sh record "$from_block" >"$work/refusal.log" 2>&1; then
		fail "the record passed with $*, which the new claim order was not composed for"
	fi
	grep -qF "is not the claim expression for VALID_SIGNERS and SIGNER_THRESHOLD" "$work/refusal.log" || {
		cat "$work/refusal.log"
		fail "the record refused $* without naming the expression"
	}
	echo "refused: a record with $*, which the claim order was not composed for"
}
expect_record_mismatch VALID_SIGNERS="$launch_signers"
expect_record_mismatch SIGNER_THRESHOLD=3
expect_record_mismatch VALID_SIGNERS="${signers[1]},${signers[0]},$signer_safe"
env "${rotation[@]}" ./rotate-claim-signer.sh record "$from_block" | tee "$work/rotated.log"
new_order_hash=$(record_value ORDER_HASH "$work/rotated.log")
new_bytecode=$(record_value PUBLIC_CLAIM_BYTECODE "$work/rotated.log")
[[ -n $new_order_hash && -n $new_bytecode ]] || fail "the rotation printed no complete deploy record"
[[ $(record_value PUBLIC_CLAIM_INPUT_TOKEN "$work/rotated.log") == "$input_token" ]] ||
	fail "the new deploy record does not keep the claim input token"
[[ $(record_list PUBLIC_CLAIM_SIGNERS "$work/rotated.log") == $(lower "$rotated_signers") &&
	$(record_list PUBLIC_CLAIM_THRESHOLD "$work/rotated.log") == 2 ]] ||
	fail "the new deploy record does not name keys 0 and 1 and the signer Safe, threshold 2"

step "Starting the orchestrator for the rotated order: a key and the signer Safe's owners' keys"
two_owner_keys="${signer_owner_keys[1]},${signer_owner_keys[2]}"
key0=(SIGNER_PRIVATE_KEY="${signer_keys[0]}")
safe_signer=(SAFE_SIGNER="$signer_safe" SAFE_OWNER_KEYS="$two_owner_keys")
expect_startup "$work/rotated.log" "with key 0 and the keys of 2 of the signer Safe's 3 owners" \
	"${key0[@]}" "${safe_signer[@]}"
grep -qF "SAFE_SIGNER $signer_safe is a Safe of threshold 2" "$work/orchestrator.log" ||
	fail "the orchestrator did not log the Safe's threshold"
expect_startup "$work/rotated.log" "with keys 0 and 1" SIGNER_PRIVATE_KEY="${signer_keys[0]},${signer_keys[1]}"
expect_orchestrator_refusal "$work/rotated.log" \
	"SIGNER_PRIVATE_KEY signs for ${signers[2]}, which CLAIM_SIGNERS does not list" \
	SIGNER_PRIVATE_KEY="${signer_keys[0]},${signer_keys[2]}"
expect_orchestrator_refusal "$work/rotated.log" \
	"this orchestrator signs for 1 of CLAIM_SIGNERS, and each coupon needs CLAIM_THRESHOLD=2" \
	"${safe_signer[@]}"
expect_orchestrator_refusal "$work/rotated.log" \
	"SAFE_SIGNER is required with SAFE_OWNER_KEYS" \
	"${key0[@]}" SAFE_OWNER_KEYS="$two_owner_keys"
expect_orchestrator_refusal "$work/rotated.log" \
	"SAFE_OWNER_KEYS holds 1 keys" \
	"${key0[@]}" SAFE_SIGNER="$signer_safe" SAFE_OWNER_KEYS="${signer_owner_keys[0]}"
expect_orchestrator_refusal "$work/rotated.log" \
	"SAFE_OWNER_KEYS holds 3 keys, and SAFE_SIGNER $signer_safe is a Safe of threshold 2" \
	"${key0[@]}" SAFE_SIGNER="$signer_safe" SAFE_OWNER_KEYS="$(IFS=,; echo "${signer_owner_keys[*]}")"
expect_orchestrator_refusal "$work/rotated.log" \
	"SAFE_OWNER_KEYS holds the key of $other_signer, which is not an owner of SAFE_SIGNER $signer_safe" \
	"${key0[@]}" SAFE_SIGNER="$signer_safe" SAFE_OWNER_KEYS="${signer_owner_keys[0]},$other_signer_key"
expect_orchestrator_refusal "$work/rotated.log" \
	"SAFE_OWNER_KEYS holds the key of $(address_of "${admin_owner_keys[0]}"), which is not an owner of SAFE_SIGNER $signer_safe" \
	"${key0[@]}" SAFE_SIGNER="$signer_safe" SAFE_OWNER_KEYS="${admin_owner_keys[0]},${admin_owner_keys[1]}"
expect_orchestrator_refusal "$work/rotated.log" \
	"SAFE_OWNER_KEYS holds the key of $(address_of "${signer_owner_keys[0]}") twice" \
	"${key0[@]}" SAFE_SIGNER="$signer_safe" SAFE_OWNER_KEYS="${signer_owner_keys[0]},${signer_owner_keys[0]}"

# The website's claimer: a fresh key anvil gives ETH, which the proofs' coupons
# for the website pay.
claimer_key=$(fresh_key)
claimer=$(address_of "$claimer_key")
cast rpc anvil_setBalance "$claimer" 0xDE0B6B3A7640000 --rpc-url "$fork" >/dev/null

step "Proving the Safe admin and the rotated order, 2 of keys 0 and 1 and the signer Safe, on the fork"
ORDER_HASH=$new_order_hash PREVIOUS_ORDER_HASH=$order_hash REHEARSAL_WEBSITE_CLAIMER=$claimer \
	PUBLIC_CLAIM_INTERPRETER=$interpreter PUBLIC_CLAIM_STORE=$store \
	PUBLIC_CLAIM_BYTECODE=$new_bytecode PUBLIC_CLAIM_INPUT_TOKEN=$input_token \
	ADMIN_SAFE=$admin_safe SIGNER_SAFE=$signer_safe REHEARSAL_MIN_LOCK_AMOUNT=$min_lock_amount \
	REHEARSAL_SIGNER_OWNER_KEYS="$two_owner_keys" \
	REHEARSAL_SIGNER_ONE_OWNER_KEY="${signer_owner_keys[0]}" \
	REHEARSAL_ADMIN_OWNER_KEYS="${admin_owner_keys[0]},${admin_owner_keys[1]}" \
	proofs --match-contract SafeSignerRehearsal | tee "$work/safe-proofs.log"
coupon_value() { grep -oE "$1=[^ ]+" "$work/safe-proofs.log" | head -1 | cut -d= -f2- || true; }
claim_calldata=$(coupon_value CLAIM_CALLDATA)
[[ -n $claim_calldata ]] || fail "the proofs printed no claim for the website"
# REHEARSAL_COUPONS for the website's fork test: each coupon the proofs printed and
# the status expected of it, the accepted coupon's `$1`.
website_coupons() {
	local name status pairs=()
	for name in ACCEPTED REFUSED_ONE_OWNER REFUSED_NON_OWNER REFUSED_ONE_SEAT REFUSED_KEY_TWICE \
		REFUSED_UNLISTED REFUSED_FORGED UNCLAIMED_KEYS UNCLAIMED_THREE_SEATS; do
		case $name in
		ACCEPTED) status=$1 ;;
		REFUSED_*) status=invalid ;;
		UNCLAIMED_*) status=unredeemed ;;
		esac
		[[ -n $(coupon_value "WEBSITE_$name") ]] || fail "the proofs printed no WEBSITE_$name coupon"
		pairs+=("$(jq -cn --arg c "$(coupon_value "WEBSITE_$name")" --arg s "$status" '[$c, $s]')")
	done
	jq -cs . <<<"${pairs[*]}"
}

step "The website's coupon status reads the rotated order's coupons on the fork, before and after a claim"
# The website's build variables are the rotated deploy record's.
mapfile -t website < <(sed -n '/website:/,$p' "$work/rotated.log" | grep -oE 'PUBLIC_[A-Z_]+=[^ ]+')
# A lock funds the claim: anvil gives the locker 100 HOT (HOT keeps balances in
# its storage slot 2).
locker=$(address_of "${keys[3]}")
hot=0x6c6EE5e31d828De241282B9606C8e98Ea48526E2
cast rpc anvil_setStorageAt "$hot" "$(cast index address "$locker" 2)" \
	"$(cast to-uint256 100000000000000000000)" --rpc-url "$fork" >/dev/null
[[ $(cast call --rpc-url "$fork" "$hot" 'balanceOf(address)(uint256)' "$locker" | cut -d' ' -f1) == 100000000000000000000 ]] ||
	fail "anvil did not give the locker HOT"
# The website reads at the `safe` block, which anvil answers as 32 blocks behind
# the latest, as Ethereum's lags: mining past that puts the rotation, and later
# the claim, in the block it reads.
mine_past_safe() { cast rpc anvil_mine 40 --rpc-url "$fork" >/dev/null; }
coupon_status() {
	mine_past_safe
	(
		cd ui
		env "${website[@]}" REHEARSAL_RPC_URL="$fork" REHEARSAL_COUPONS="$(website_coupons "$1")" \
			npx vitest run src/routes/api/coupon-status/server.fork.test.ts
	)
}
coupon_status unredeemed
# The claim as the website sends it, from the claimer; the vault holds the HOT a
# lock put there through the proofs' own fork, not this one, so lock first.
cast send --rpc-url "$fork" --private-key "${keys[3]}" "$hot" 'approve(address,uint256)' "$vault" 100000000000000000000 >/dev/null
cast send --rpc-url "$fork" --private-key "${keys[3]}" "$vault" 'lock(uint256,bytes32)' 100000000000000000000 \
	"$(cast keccak "a Unyt agent")" >/dev/null
cast send --rpc-url "$fork" --private-key "$claimer_key" 0x37FC0EFec37D19f8A221aa4F8F7600C9ba2AcD20 "$claim_calldata" >/dev/null ||
	fail "the claim of the coupon a key and the Safe signed failed on the fork"
echo "claimed the coupon a key and the Safe signed on the fork"
coupon_status redeemed

step "Deploying with UNSAFE_ALLOW_SINGLE_KEY_ADMIN=yes: a key as the vault admin, 2 of keys 0 and 1 and the signer Safe sign coupons"
deploy_block=$(next_block)
ETH_RPC_URL=$fork UNSAFE_ALLOW_SINGLE_KEY_ADMIN=yes ADMIN_ADDRESS=$admin \
	VALID_SIGNERS="$rotated_signers" SIGNER_THRESHOLD=2 ./deploy-mainnet.sh "${wallet[@]}" | tee "$work/unsafe.log"
grep -qF "UNSAFE_ALLOW_SINGLE_KEY_ADMIN=yes: ADMIN_ADDRESS $admin is one key, which alone controls the vault" \
	"$work/unsafe.log" || fail "the deploy did not log the override"
read_record "$work/unsafe.log"
[[ $(record_list PUBLIC_CLAIM_SIGNERS "$work/unsafe.log") == $(lower "$rotated_signers") ]] ||
	fail "the deploy record does not name keys 0 and 1 and the signer Safe"
expect_startup "$work/unsafe.log" "for key 1 and the signer Safe from the deploy" \
	SIGNER_PRIVATE_KEY="${signer_keys[1]}" "${safe_signer[@]}"
ORDER_HASH=$order_hash PUBLIC_CLAIM_INTERPRETER=$interpreter PUBLIC_CLAIM_STORE=$store \
	PUBLIC_CLAIM_BYTECODE=$bytecode PUBLIC_CLAIM_INPUT_TOKEN=$input_token \
	ADMIN_ADDRESS=$admin SIGNER_SAFE=$signer_safe HOLO_BRIDGE_DEPLOYER=$bridge_deployer \
	REHEARSAL_DEPLOY_BLOCK=$deploy_block REHEARSAL_SIGNER_OWNER_KEYS="$two_owner_keys" \
	proofs --match-contract SingleKeyAdminRehearsal

step "Fork rehearsal passed"
