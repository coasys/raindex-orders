#!/usr/bin/env bash
# Deploys the TestNet bridge on a local anvil fork of Base Sepolia, for trying the
# website with MetaMask before the real Base Sepolia deploy (DEPLOY.md, "Test the
# website locally"):
#   test/local-ui.sh 0xYourMetaMaskAddress    start anvil, deploy, fund the address
#   test/local-ui.sh stop                     stop anvil
# The address may be given as FUND_ADDRESS instead. Every transaction goes to the
# anvil this script starts on 127.0.0.1, never to FORK_URL, and is signed by
# anvil's own published account 0. It writes ui/.env.development.local, which only
# `npm run dev` reads: a build never takes it.
set -euo pipefail
cd "$(dirname "$0")/.."
repo=$PWD

FORK_URL=${FORK_URL:-https://sepolia.base.org}
PORT=${LOCAL_UI_PORT:-8545}
rpc=http://127.0.0.1:$PORT
state=$repo/.local-ui
ui_env=$repo/ui/.env.development.local
marker='# Written by test/local-ui.sh'

# Anvil's account 0, from its published test mnemonic: a key everyone has.
deployer_key=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
deployer=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
test_signer=0x8E72b7568738da52ca3DCd9b24E178127A4E7d37

fail() {
	echo "local-ui: $*" >&2
	exit 1
}

stop_anvil() {
	local pid
	[[ -f $state/anvil.pid ]] || return 0
	pid=$(<"$state/anvil.pid")
	if kill -0 "$pid" 2>/dev/null && [[ $(ps -o comm= -p "$pid") == anvil ]]; then
		kill "$pid"
		for _ in $(seq 20); do
			kill -0 "$pid" 2>/dev/null || break
			sleep 0.25
		done
		echo "Stopped anvil ($pid)."
	fi
	rm -f "$state/anvil.pid"
}

if [[ ${1:-} == stop ]]; then
	stop_anvil
	exit 0
fi

fund=${1:-${FUND_ADDRESS:-}}
[[ $fund =~ ^0x[0-9a-fA-F]{40}$ ]] ||
	fail "usage: test/local-ui.sh <MetaMask address>, or FUND_ADDRESS=0x... test/local-ui.sh; test/local-ui.sh stop"
if [[ -f $ui_env ]] && ! grep -qxF "$marker" "$ui_env"; then
	fail "ui/.env.development.local is not one this script wrote: move it away first"
fi
for tool in anvil cast forge jq node; do
	command -v "$tool" >/dev/null || fail "$tool is not installed (nix develop, or foundryup)"
done
[[ -d node_modules ]] || fail "run npm ci at the top of the repo first: the deploy composes the claim expression with node"
[[ -d ui/node_modules ]] || fail "run npm ci in ui/ first"

# Nothing inherited may point the deploy at a real chain.
unset ETH_RPC_URL BASE_SEPOLIA_RPC_URL NETWORK VALID_SIGNER PRIVATE_KEY
# forge also reads the repo's .env, if there is one: account 0 is the vault's admin.
export ADMIN_ADDRESS=$deployer
export FOUNDRY_DISABLE_NIGHTLY_WARNING=1

stop_anvil
cast chain-id --rpc-url "$rpc" >/dev/null 2>&1 && fail "something already answers on $rpc: stop it, or set LOCAL_UI_PORT"
rm -rf "$state"
mkdir -p "$state"

echo "== Starting anvil on $rpc, a fork of Base Sepolia ($FORK_URL)"
nohup anvil --host 127.0.0.1 --port "$PORT" --fork-url "$FORK_URL" >"$state/anvil.log" 2>&1 &
echo $! >"$state/anvil.pid"
for _ in $(seq 120); do
	kill -0 "$(<"$state/anvil.pid")" 2>/dev/null || {
		cat "$state/anvil.log"
		fail "anvil exited"
	}
	[[ $(cast rpc web3_clientVersion --rpc-url "$rpc" 2>/dev/null) == '"anvil/'* ]] && break
	sleep 0.5
done
[[ $(cast rpc web3_clientVersion --rpc-url "$rpc" 2>/dev/null) == '"anvil/'* ]] || fail "anvil did not start"
[[ $(cast chain-id --rpc-url "$rpc") == 84532 ]] || fail "the fork is not Base Sepolia, chain 84532"
fork_block=$(cast block-number --rpc-url "$rpc")

# Account 0 carries an EIP-7702 delegation on Base Sepolia, and the test signer must
# not: on the fork, account 0 becomes a plain key again.
cast rpc anvil_setCode "$deployer" 0x --rpc-url "$rpc" >/dev/null
cast rpc anvil_setBalance "$deployer" 0x3635C9ADC5DEA00000 --rpc-url "$rpc" >/dev/null # 1000 ETH

echo "== Deploying mock HOT, HoloLockVault, ClaimInputToken and the claim order with deploy-base-sepolia.sh"
# deploy-base-sepolia.sh signs from a keystore, as on Base Sepolia; this one holds
# account 0. It keeps its addresses in a file of its own, not the repo's .env, and
# its broadcast logs out of broadcast/. The claim order takes the test signer's
# coupons, the deploy's default.
cast wallet import local-ui --private-key "$deployer_key" --keystore-dir "$state/keys" \
	--unsafe-password local-ui >/dev/null
printf 'BASE_SEPOLIA_RPC_URL=%s\n' "$rpc" >"$state/deploy.env"
ENV_FILE=$state/deploy.env FOUNDRY_BROADCAST=$state/broadcast MINT_AMOUNT=1000000000000000000000000 \
	./deploy-base-sepolia.sh all --keystore "$state/keys/local-ui" --password local-ui >"$state/deploy.log" 2>&1 || {
	cat "$state/deploy.log"
	fail "deploy-base-sepolia.sh failed"
}
# shellcheck source=/dev/null
source "$state/deploy.env"

echo "== Reading back the deploy record"
# rotate-claim-signer.sh's record reads the order the vault added from the chain and
# checks it. Its ORDER_HASH is the order a rotation replaces, which a first deploy has none of.
NETWORK=base-sepolia BASE_SEPOLIA_RPC_URL=$rpc BASE_SEPOLIA_LOCK_VAULT_ADDRESS=$BASE_SEPOLIA_LOCK_VAULT_ADDRESS \
	VALID_SIGNER=$test_signer ORDER_HASH=0x$(printf '%064d' 0) \
	./rotate-claim-signer.sh record "$((fork_block + 1))" >"$state/record.log" 2>&1 || {
	cat "$state/record.log"
	fail "the deploy record did not check out"
}
mapfile -t website < <(sed -n '/website:/,$p' "$state/record.log" | grep -oE 'PUBLIC_[A-Z_]+=[^ ]+')
[[ ${#website[@]} == 10 ]] || {
	cat "$state/record.log"
	fail "the deploy record has ${#website[@]} website lines, not 10"
}

echo "== Funding $fund with 100 ETH and 10000 mock HOT"
cast rpc anvil_setBalance "$fund" 0x56BC75E2D63100000 --rpc-url "$rpc" >/dev/null # 100 ETH
cast send "$TOKEN_ADDRESS" 'mint(address,uint256)' "$fund" 10000000000000000000000 \
	--private-key "$deployer_key" --rpc-url "$rpc" >/dev/null
hot=$(cast call "$TOKEN_ADDRESS" 'balanceOf(address)(uint256)' "$fund" --rpc-url "$rpc" | cut -d' ' -f1)
[[ $hot != 0 ]] || fail "$fund holds no mock HOT"

{
	echo "$marker"
	echo "# for the anvil fork on $rpc. Run it again after anvil restarts: the addresses may change."
	printf '%s\n' "${website[@]}"
	echo "BASE_SEPOLIA_RPC_URL=$rpc"
	echo "# Anvil's account 0, whose key is public, holds the faucet's mock HOT."
	echo "FAUCET_PRIVATE_KEY=$deployer_key"
} >"$ui_env"

cat <<EOF

The local TestNet is up. anvil runs in the background (log: .local-ui/anvil.log).
  mock HOT      $TOKEN_ADDRESS
  lock vault    $BASE_SEPOLIA_LOCK_VAULT_ADDRESS
  claim order   $ORDER_HASH
  $fund holds 100 ETH and $(cast from-wei "$hot" | sed -E 's/\.?0+$//') mock HOT.

1. Start the website:
     cd ui && npm run dev
   and open http://localhost:5173

2. In MetaMask, add a network (Settings > Networks > Add a network manually):
     Network name     Base Sepolia (local)
     RPC URL          $rpc
     Chain ID         84532
     Currency symbol  ETH
   If MetaMask already has Base Sepolia, add $rpc as another RPC URL of it and
   select that one. Add the token $TOKEN_ADDRESS to see your mock HOT.

3. Lock on /lock. Then make a coupon to claim it back, from ui/:
     npm run make-coupon -- --recipient $fund --amount 5
   and open the claim link it prints. A claim pays out of what has been locked.

4. Stop anvil when you are done:
     test/local-ui.sh stop
   After a restart, run this script again, and in MetaMask clear the account's
   activity (Settings > Advanced > Clear activity tab data): its nonces are stale.
EOF
