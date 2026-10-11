# Holo Bridge deployment guide

This guide covers deploying and testing the complete HOT <> bridged HOT bridge infrastructure on the TestNet, Base Sepolia, and [deploying it on Ethereum mainnet](#mainnet-deploy).

## Raindex V6 and Rainlang

The bridge runs on the Raindex V6 and Rainlang release Rain deployed: rain.orderbook 0.1.15 (its RaindexV6 and subparser are unchanged since 0.1.14, cut 2026-08-23) and rainlang 0.1.9 (cut 2026-08-25). Rain deploys each release through its deterministic deployer, so a contract has the same address on every chain it is on, and `src/Constants.sol` takes each address, and the hash of its code, from the frozen `src/generated/<tag>/` file of the Soldeer package (`raindex` 0.1.15, `rainlang` 0.2.6). Every script checks the code at each address before it sends anything.

| Contract | Address, on Ethereum mainnet and Base Sepolia |
|---|---|
| RaindexV6 | `0x37FC0EFec37D19f8A221aa4F8F7600C9ba2AcD20` |
| RaindexV6SubParser | `0x09Bc7AF266012F44fb41D8Bd682da931666605e1` |
| Rainlang expression deployer (parses the claim expression) | `0xb90c299a8321fbdd8D0F367e560f5341F840dA3F` |
| Rainlang interpreter | `0x4c52eee7Fb6aeD0F1a30130d96d02409D9d886cf` |
| Rainlang store | `0x1Aa775533E28B1D843e1A589034984E3a62005DC` |

None of these is on Ethereum Sepolia, which is why the TestNet is Base Sepolia (chain 84532).

Raindex V6 counts every amount as a decimal float. The vault converts each lock losslessly (the wei as the coefficient, -18 as the exponent) and a coupon's amount word is that float. V6 takes an order only at a positive io-ratio, and pulls at least one unit of the order's input token from the taker, so the claim order's ratio is 1e-30 and its input token is a `ClaimInputToken`, deployed with the vault, whose transfers succeed and move nothing. A V6 order carries its parsed bytecode, so the deploy record prints `CLAIM_BYTECODE` in place of an expression address.

## Prerequisites

1. A deployer wallet with Base Sepolia ETH: a Ledger, or an encrypted keystore as below. Base lists faucets at [docs.base.org](https://docs.base.org/base-chain/tools/network-faucets); the Coinbase Developer Platform faucet and Alchemy's give Base Sepolia ETH directly, and Base's bridge moves Ethereum Sepolia ETH over
2. Foundry installed (`forge`, `cast` commands available), and the Soldeer packages: `forge soldeer install`
3. Rust toolchain (for bridge-orchestrator)
4. Node.js 20+ (for UI, and `npm ci` at the repo root for `compose-rainlang.mjs`)

## Deploy the TestNet on Base Sepolia

### 1. Set Up Environment

```bash
# Copy example env file. It holds addresses, never a private key.
cp .env.example .env

# Keep the deployer key in an encrypted keystore, entered at a prompt
cast wallet import deployer --interactive
```

Every step that sends a transaction takes the deployer as `--account deployer`, or `--ledger` for a Ledger. `deploy-base-sepolia.sh` refuses a `PRIVATE_KEY` in `.env` and a `--private-key` option. `BASE_SEPOLIA_RPC_URL` in `.env` is the RPC it sends through, `https://sepolia.base.org` unless set, and it refuses an RPC that answers for another chain.

### 2. Deploy All Contracts

The `deploy-base-sepolia.sh` script handles all deployment steps:

```bash
# Check your wallet and balance
./deploy-base-sepolia.sh status --account deployer

# Step 1: Deploy MockHOT token
./deploy-base-sepolia.sh token --account deployer
# Note: Updates .env with TOKEN_ADDRESS automatically

# Step 2: Deploy HoloLockVault, and the ClaimInputToken its claim order takes as input
./deploy-base-sepolia.sh vault --account deployer
# Note: Updates .env with BASE_SEPOLIA_LOCK_VAULT_ADDRESS and CLAIM_INPUT_TOKEN automatically

# Step 3: Mint test tokens to your wallet
./deploy-base-sepolia.sh mint --account deployer

# Step 4: Deploy claim order via HoloLockVault, accepting coupons from
# VALID_SIGNER (the test signer unless set)
./deploy-base-sepolia.sh order-via-vault --account deployer
# Note: Updates .env with ORDER_HASH and ORDER_OWNER automatically
```

### 3. Verify Deployment

```bash
# Show all deployed addresses and configuration
./deploy-base-sepolia.sh status
```

### 4. Run the orchestrator and the website against it

The orchestrator and the website take what is the same on every chain from TestNet's defaults (RaindexV6, the Rainlang interpreter and store, the vault ID, the test signer) and need the rest from this deploy: the orchestrator `BASE_SEPOLIA_LOCK_VAULT_ADDRESS`, `TOKEN_ADDRESS`, `ORDER_HASH`, `ORDER_OWNER`, `CLAIM_BYTECODE` and `CLAIM_INPUT_TOKEN`, and the website `PUBLIC_LOCK_VAULT_ADDRESS`, `PUBLIC_TOKEN_ADDRESS`, `PUBLIC_CLAIM_ORDER_HASH`, `PUBLIC_CLAIM_BYTECODE` and `PUBLIC_CLAIM_INPUT_TOKEN`. `rotate-claim-signer.sh record <block>` prints them all as a deploy record once the order is added (`NETWORK=base-sepolia`, `VALID_SIGNER` the test signer); so does `cast` on the order's `AddOrderV3` event. Then:

```bash
# bridge-orchestrator: NETWORK=base-sepolia, BASE_SEPOLIA_RPC_URL, SIGNER_PRIVATE_KEY
# (TEST_SIGNER_KEY in src/Constants.sol), HOLOCHAIN_BRIDGING_AGENT_PUBKEY and the lines above
cargo run -- run
# ui: PUBLIC_NETWORK=base-sepolia and the PUBLIC_* lines above, BASE_SEPOLIA_RPC_URL
# and FAUCET_PRIVATE_KEY as the Worker's secrets
npm run build
```

### Deployed Contract Addresses (Base Sepolia)

The TestNet bridge is not deployed on Base Sepolia yet. Rain's contracts are at [their addresses above](#raindex-v6-and-rainlang). The test signer is `0x8E72b7568738da52ca3DCd9b24E178127A4E7d37`.

The previous TestNet, on Ethereum Sepolia against OrderBookV3 (vault `0xE3E064e3C2EEf66cb93dA8D8114F5084E92F48D6`, orderbook `0xfca89cD12Ba1346b1ac570ed988AB43b812733fe`), does not carry over: its vault, order and coupons are V3's.

## Mainnet deploy

`deploy-mainnet.sh` deploys the bridge on Ethereum mainnet against the RaindexV6 Rain deployed there, in one transaction, with a Safe as the vault admin from that transaction on. It deploys no orderbook.

```bash
npm ci   # compose-rainlang.mjs, which composes the claim expression
ETH_RPC_URL=<an Ethereum RPC> \
ADMIN_ADDRESS=<the vault admin: a Safe> \
ADMIN_SAFE_THRESHOLD=<its threshold> ADMIN_SAFE_OWNERS=<its owners, separated by commas> \
VALID_SIGNER=<the coupon signer: a key, or a Safe> \
./deploy-mainnet.sh --ledger            # or --account <keystore>
```

- **Refusals.** Before it sends anything, it refuses a chain other than 1, a missing input, a raw key option such as `--private-key`, an `ADMIN_ADDRESS` equal to the deployer, a `VALID_SIGNER` equal to the test signer, a `VALID_SIGNER` with an EIP-7702 delegation (Raindex V6 asks a delegated key's delegate for a coupon's signature, never the key), a contract `VALID_SIGNER` that is not a Safe of threshold 2 to 20, and a Rain contract that is not the release on the chain. It refuses an `ADMIN_ADDRESS` that is a key, a contract that is not a Safe, or a Safe of threshold 1, so that no one key controls the vault; `UNSAFE_ALLOW_SINGLE_KEY_ADMIN=yes` lets a key or a threshold-1 Safe through, and is logged. For a Safe admin it reads the Safe's threshold and owners, prints them, and refuses ones other than `ADMIN_SAFE_THRESHOLD` and `ADMIN_SAFE_OWNERS`: the operator states which Safe is meant, and a wrong address is caught before the vault goes to it.
- **What it sends.** One transaction: a `HoloBridgeDeployer`, whose constructor deploys the `ClaimInputToken`, then `HoloLockVault(HOT, RaindexV6, HOLO_VAULT_ID, <itself>, MIN_LOCK_AMOUNT)`, adds the claim order through the vault, and calls `setAdmin(ADMIN_ADDRESS)`. The deployer contract is the vault's admin only inside that transaction and holds no right after it; the key that sends it is never the admin. The transaction reverts as a whole if any step fails, leaving nothing behind.
- **The record.** It reads the vault from the `HoloBridgeDeployer`, reads back the vault's token, orderbook, vault ID and admin, checks that the vault's admin changed exactly once, from the deployer contract to `ADMIN_ADDRESS`, in the deploy's block, and reads the claim order. Then it prints the deploy record under the variable names the orchestrator and the website take, `CLAIM_BYTECODE` and `CLAIM_INPUT_TOKEN` among them. To print it again: `forge script script/DeployMainnet.s.sol:DeployMainnet --rpc-url $ETH_RPC_URL --sig 'record(address,uint256)' <HoloBridgeDeployer> <block>`.
- **The coupon signer.** A key: the orchestrator runs with `SIGNER_PRIVATE_KEY`. A Safe: it runs with `SAFE_OWNER_KEYS`, the keys of its threshold of owners, which is one party signing as the Safe until the signer services exist ([docs/enable-multisig.md](./docs/enable-multisig.md), [docs/signer-service.md](./docs/signer-service.md)).
- **Failure.** A run that sends its transaction and sees it revert, or not land, prints it. A new run deploys a new vault.

### Rehearse it first

`test/fork-rehearsal.sh` runs `deploy-mainnet.sh` and `rotate-claim-signer.sh`, unchanged, against an anvil fork of mainnet. Every transaction goes to an anvil it starts on 127.0.0.1.

```bash
nix develop -c test/fork-rehearsal.sh   # FORK_URL sets the mainnet RPC that anvil forks
```

It creates three Safes of anvil accounts on the fork, then proves that the deploy sends nothing while it refuses a chain other than 1 (a plain anvil on chain 31337), a missing input, a raw key, the test signer, a signer with an EIP-7702 delegation (anvil's published accounts carry one on mainnet, so the rehearsal's coupon signers are fresh keys), a key or the deployer as the admin, a Safe of threshold 1, a contract that is not a Safe, and a stated threshold or owner list that is not the Safe's. Then it deploys on the fork with the admin Safe as the vault admin and a key as the coupon signer, in one transaction, and proves that the orchestrator passes its startup checks with the deploy record and the coupon signer's key, refuses another key, and refuses `SAFE_OWNER_KEYS` for a key signer. It proves that a lock lands in the vault, that a coupon signed as the orchestrator signs claims it back, that nonce reuse, a wrong signer and an expired coupon fail, that the vault's admin was handed over once, from the deployer contract to the Safe, in the deploy's block, that the deployer, the deployer contract and each owner alone are refused every admin call, and that the Safe acts with two owner signatures and not with one.

Then it moves the coupon signer to a 2 of 3 Safe through the admin Safe, as [docs/enable-multisig.md](./docs/enable-multisig.md) describes. The rotation refuses the test signer and a Safe of threshold 1, and its record refuses a signer the new order does not accept, a second order of the vault's left on the orderbook, and an order run by another interpreter. The orchestrator then passes its startup checks with the keys of two of the Safe's three owners, through the Safe's own `isValidSignature`, and refuses a key for the Safe, one key, three, a key that is not an owner's, the admin Safe's owners, a key twice, and both key variables set. On the fork, a coupon with two owner signatures claims, and one with a single signature, with an owner's and a stranger's, with an owner's twice, or with the admin Safe's owners' fails. The website's coupon status reads a coupon the Safe's owners signed as unredeemed and two the Safe refuses as invalid, through the real Safe on the fork, then reads the first as redeemed once it is claimed (`ui/src/routes/api/coupon-status/server.fork.test.ts`). Last, a deploy with `UNSAFE_ALLOW_SINGLE_KEY_ADMIN=yes` hands the vault to a key, with the signer Safe as the coupon signer from the start.

`FORK_URL` is `https://ethereum-rpc.publicnode.com` unless set.

The rehearsal runs the orchestrator binary, so build it first: `cargo build` in `bridge-orchestrator`, on its pinned toolchain, or set `ORCHESTRATOR` to a built binary.

### Website

One SvelteKit build per network, each its own Cloudflare Worker: `hot-bridge-ui` for Base Sepolia, and `hot-bridge-ui-mainnet`, the wrangler env `mainnet`. Each Workers Builds project sets `PUBLIC_NETWORK` and the `PUBLIC_*` build variables the deploy record prints, and its RPC secret: `BASE_SEPOLIA_RPC_URL` and `FAUCET_PRIVATE_KEY`, or `ETH_RPC_URL`. `PUBLIC_NETWORK` defaults to `base-sepolia`, and a base-sepolia build takes TestNet's value, in `ui/src/lib/network.ts`, for what is the same on every chain (`PUBLIC_ORDERBOOK_ADDRESS`, `PUBLIC_CLAIM_INTERPRETER`, `PUBLIC_CLAIM_STORE`, `PUBLIC_CLAIM_SIGNER`), and logs which; it must be given the rest, as TestNet is not deployed on Base Sepolia yet. A mainnet build takes none: it fails when a variable is missing or malformed. Either fails when the claim order the variables describe does not hash to `PUBLIC_CLAIM_ORDER_HASH`, and a mainnet build when the signer is the test signer. The MainNet Workers Builds project must set `PUBLIC_NETWORK=mainnet`. The build cannot check that `PUBLIC_CLAIM_SIGNER` is the order's signer, so take it from the deploy record. The mainnet website has no faucet.

The website waits for a sent transaction by polling every 2 seconds, Base's block time, for up to 5 minutes, as before: that is about 150 Base blocks, and 25 on mainnet.

## Testing the Complete Flow

### Lock Flow (HOT -> Bridged HOT)

1. **Start the bridge orchestrator:**
```bash
cd bridge-orchestrator
# Set HOLOCHAIN_BRIDGING_AGENT_PUBKEY, SIGNER_PRIVATE_KEY and the deploy record's
# values; what is the same on every chain defaults to TestNet's (bridge-orchestrator/README.md)
cargo run -- run
```

2. **Start the UI:**
```bash
cd ui
npm install
npm run dev
```

3. **Lock tokens:**
   - Open http://localhost:5173
   - Connect MetaMask to Base Sepolia
   - Select "Lock HOT -> bridged HOT" tab
   - Enter amount and Holochain agent public key
   - Approve and lock tokens
   - Watch the bridge-orchestrator detect the event and drive the Holochain bridge

### Claim Flow (Bridged HOT -> HOT)

1. **Coupon generation:**
   Withdrawal coupons are produced by the bridge orchestrator as part of its bridging cycle whenever a burn/withdraw request is observed on the Holochain side. See `bridge-orchestrator/src/signer.rs` for the signing logic.

2. **Claim via UI:**
   - Open http://localhost:5173/claim
   - Paste the coupon string into the input field
   - Or use URL: `http://localhost:5173/claim?c=<coupon>`
   - Click "Claim HOT"

3. **Claim via URL parameter:**
   - Coupons use a URL-safe format
   - Share: `http://localhost:5173/claim?c=<signer>,<signature>,<ctx0>,<ctx1>,...`

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────┐
│                    SHARED LIQUIDITY POOL                         │
│         (Raindex V6 vault owned by HoloLockVault)               │
│                                                                  │
│   LOCK (HOT→bHOT)            HOT Tokens             CLAIM (bHOT→HOT)
│   ─────────────────►    ┌───────────────┐    ◄─────────────────
│   Deposits INTO         │   Balance: N   │         Withdraws FROM
│                         └───────────────┘                        │
└─────────────────────────────────────────────────────────────────┘
```

**Key Design**: The HoloLockVault contract owns both:
1. The vault where locked HOT is deposited
2. The claim order that allows withdrawals via signed coupons

This ensures LOCK deposits and CLAIM withdrawals operate on the **same pool of tokens**.

## Component Details

### HoloLockVault Contract (`src/HoloLockVault.sol`)

Functions:
- `lock(amount, holochainAgent)` - Lock tokens (deposited as a lossless decimal float), emit event for bridged HOT crediting
- `addOrder(config)` - Deploy claim order, an `OrderConfigV4` (admin only)
- `removeOrder(order)` - Remove claim order, an `OrderV4` (admin only)
- `adminWithdraw(amount, to)` - Emergency withdrawal (admin only)
- `vaultBalance()` - Check vault balance, in wei

### Bridge Orchestrator (`bridge-orchestrator/`)

Rust service that replaces the legacy `lock-watcher-rs` and `coupon-signer`:
```bash
cd bridge-orchestrator
cargo run -- run
```

Responsibilities:
- Polls the orderbook for new Lock events and drives the Holochain bridge
- Processes withdrawal requests from Holochain and generates signed claim coupons (see `CouponSigner::coupon` in `src/signer.rs`)
- Emits batched bridging RAVE transactions with explicit links and a coupons map
- Produces the same URL-safe coupon format consumed by the UI: `signer,signature,ctx0,ctx1,...,ctx8`

### UI (`ui/`)

SvelteKit web interface:
- `/` - Connect a wallet and see its network
- `/lock` - Lock HOT to receive bridged HOT
- `/claim` - Claim HOT with coupon
- `/claim?c=<coupon>` - Direct claim via URL parameter
- `POST /api/coupon-status`: the status of up to 20 claim coupons, read from the build's network through its RPC secret

#### What bounds coupon-status RPC use

- **Signature gate.** A coupon is read only if it names the claim order's signer (the order's `valid-signer`, `PUBLIC_CLAIM_SIGNER` in the build) and carries a signature that signer gives, checked as the orderbook checks it. A 65-byte signature must recover to the signer, and any other coupon of that form answers `invalid` and is never read. A signature of 2 to 20 owner parts, each a key's 65-byte signature, is a contract signer's, such as a Safe's: the signer's EIP-1271 `isValidSignature` checks it in the same `eth_call` that reads the nonces. Such a coupon causes a read even when it answers `invalid`, until a check finds that the claim signer has no code; for the next 10 minutes that Worker isolate answers such coupons `invalid` without a read, and logs that it does. A coupon signer Safe needs a threshold of 2 or more, as a 65-byte signature is read as a key's.
- **Cache.** Answers are kept in the Workers Cache, keyed by the coupon's signer, signature and context values, so a coupon respelled with other hex case or leading zeros shares its entry. `redeemed` and `expired` are kept from then on. `unredeemed` is kept for 60 s, and never once the coupon's expiry has passed. The Workers Cache is local to each Cloudflare data centre, so each data centre reads a coupon once for itself. A cache read or write that fails is logged and costs only a read; it never changes an answer.
- **One read at most.** A request makes at most one `eth_call` to its network's RPC secret, `BASE_SEPOLIA_RPC_URL` or `ETH_RPC_URL`: one Multicall3 `aggregate3` at the `safe` block, reading each uncached nonce once. A request the cache answers in full, or with no valid coupon, makes none, and its `block` is `null`. An RPC that answers for another chain is refused.

A coupon whose expiry has passed, but which the `safe` block still shows unexpired, is read on every request until the `safe` block passes its expiry, about 10 to 15 minutes on Ethereum and a few minutes on Base.

#### Why 20 coupons per request

`hot-bridge-ui` runs on the Workers Free plan, which allows 50 subrequests per request, Cache API `match()` and `put()` calls included, and 10 ms of CPU. A request of N coupons the cache has not seen costs N cache matches, one RPC fetch and N cache puts. On a preview build, 6 to 20 new coupons answered `200`, 25 answered `500` (the 25th put), and 44 or 50 answered `502` (the RPC fetch). So a request takes at most 20 coupons: 41 subrequests and 20 signature checks. Checking a signature costs about 1 ms of CPU, and a coupon the cache holds is not checked again. The Workers Paid plan allows 10,000 subrequests per request.

#### Optional WAF rule

Optionally, for raw floods, add a Cloudflare WAF rate limiting rule in the dashboard (Security, then WAF, then Rate limiting rules) for the zone that serves `hot-bridge.unyt.dev`:

| Setting | Value |
|---|---|
| Match | URI path equals `/api/coupon-status` |
| Count by | IP |
| Rate | 20 requests per 10 s |
| Action | Block for 10 s |

An app sends about one request every 3 minutes, plus one each time Interaction Details is opened, so this sits far above genuine use. These are the Free plan's only period and timeout, and the Free plan cannot match on method. The rule covers the custom domain only, not the Worker's `workers.dev` and version URLs.

## Coupon Format

The signed coupon contains 9 context words, each a bytes32 the orchestrator writes as a decimal number:
| Index | Field | Description |
|-------|-------|-------------|
| 0 | recipient | Ethereum address to receive tokens, as a word |
| 1 | amount | The decimal float Raindex V6 pays out: the wei as the coefficient with exponent -18, so `0xffffffee` then the wei in the low 224 bits |
| 2 | expiry | Unix timestamp when coupon expires (a float of exponent 0 is its integer, as `block-timestamp()` is) |
| 3 | orderHash | Hash of the claim order (keccak256 of the abi-encoded OrderV4) |
| 4 | orderOwner | HoloLockVault address |
| 5 | orderbook | RaindexV6 address |
| 6 | outputToken | Token address (HOT) |
| 7 | outputVaultId | Vault ID |
| 8 | nonce | keccak256 of the 39 raw bytes of the withdrawal's Holochain transaction ID (prevents replay) |

The expression compares words 0 and 3 to 8 bit for bit, and words 1 and 2 as numbers. Each signer signs the EIP-191 hash of the packed words. `test/TestCouponSignature.t.sol` pins a test vector (fixed inputs, their nine words, the signature anvil's third account gives, the order hash and the claim's `takeOrders4` calldata) that `bridge-orchestrator/src/signer.rs`, `bridge-orchestrator/src/preflight.rs` and `ui/src/lib/coupon.test.ts`, `network.test.ts` and `claim.test.ts` reproduce.

## Troubleshooting

### "Order not found" in UI
The UI reads order status directly from the blockchain via RPC. If you see this error:
1. Verify the order was deployed: `./deploy-base-sepolia.sh status`
2. Check ORDER_HASH in `.env` matches the deployed order
3. Check the website's `PUBLIC_*` build variables against the deploy record

### Transaction fails with "Wrong signer"
The claim order does not accept the coupon's signer, as for a coupon signed before `rotate-claim-signer.sh` moved the order to a new signer. The orchestrator signs only with a key the order accepts: it refuses to start otherwise.

### "Nonce already used"
What it means depends on when the coupon was signed. Coupons signed before the per-withdrawal nonce carry the unix second they were signed in, a ten-digit nonce.

- **Ten-digit nonce:** coupons signed in the same second shared that nonce, so the error can mean a sibling coupon was claimed and this withdrawal is still unpaid. `POST /api/coupon-status` reports the coupon as `redeemed` in both cases. Re-issue the withdrawal (UNYT-1041).
- **Any other nonce:** the withdrawal has been claimed. Every coupon signed for one withdrawal carries the same nonce, so only one of them can be claimed.

## Security Notes

- Rotate the TestNet RPC API key once the faucet fix (UNYT-1040) is deployed: until then `/api/faucet` answered a failed RPC call with an error that held the full RPC URL. Change the `BASE_SEPOLIA_RPC_URL` Workers Builds build variable, which `ui/scripts/cf-deploy.sh` re-applies as the runtime secret on every deploy.
- Keep private keys out of `.env` files and command lines: sign with `--account` or `--ledger`
- The test signer key in this repo is for testing only, and every mainnet input refuses it
- Who holds the coupon signer and the vault admin, and how each moves to a multisig: [docs/enable-multisig.md](./docs/enable-multisig.md)
- The vault admin controls emergency withdrawals. On mainnet it is a Safe multisig from the deploy's first transaction, whose key holders follow [docs/key-holder.md](./docs/key-holder.md)
