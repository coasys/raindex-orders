# The bridge's Safes

On mainnet the vault admin is a Safe multisig from the bridge's first transaction, and the coupon signer is a key or a Safe. Neither needs a contract change or a redeploy to move later. The coupon signer can also move to a [Fireblocks MPC wallet](#fireblocks-as-the-coupon-signer).

- **The vault admin** is `ADMIN_ADDRESS`, which `deploy-mainnet.sh` hands the vault to inside the one transaction that deploys it: a `HoloBridgeDeployer` deploys the claim input token and the vault with itself as admin, adds the claim order through the vault, and calls `setAdmin(ADMIN_ADDRESS)`, all in that transaction. No key is the admin at any point, and the deployer contract holds no right once the transaction ends. The deploy refuses a key, a contract that is not a Safe, or a Safe of threshold 1 as `ADMIN_ADDRESS`, so that no one key controls the vault, unless `UNSAFE_ALLOW_SINGLE_KEY_ADMIN=yes` is set, which it logs. From then on every admin call is a Safe transaction its threshold of owners approve: `adminWithdraw`, `adminRecoverTokens`, `setMinLockAmount`, `addOrder`, `removeOrder` and `setAdmin`.
- **The coupon signer** can be a contract. Raindex V6 checks a coupon's signature with OpenZeppelin's `SignatureChecker`: for a contract signer it asks the contract's EIP-1271 `isValidSignature`, so `valid-signer` in `src/holo-claim.rain` can be a Safe with no Rainlang change. A Safe 1.4.1 answers through its `CompatibilityFallbackHandler`, which accepts the signatures of its threshold of owners over the SafeMessage hash of the coupon's digest, sorted by owner address and joined. A key with an EIP-7702 delegation counts as a contract to Raindex V6, which asks its delegate and never checks the key's own signature, so such a key cannot be the coupon signer: the deploy and rotation scripts and the orchestrator refuse one. A delegated key can still be a Safe owner, as the Safe recovers each owner's signature itself.

`test/fork-rehearsal.sh` proves all of it on a fork of mainnet: the deploy's refusals, a 2 of 3 Safe as the vault admin from the deploy's block, the coupon signer's move to a 2 of 3 Safe, the orchestrator signing for that Safe, the website reading its coupons, and the override.

Each key holder follows [key-holder.md](./key-holder.md).

## Create the Safes

In the Safe web app, create a Safe on Ethereum for the vault admin with three or more owners and a threshold of 2 or more. Write down its address, its threshold and its owners: the deploy takes all three and refuses a Safe that answers otherwise, so the vault cannot go to a Safe other than the one meant.

A coupon signer Safe needs a threshold of 2 to 20, which the deploy and `rotate-claim-signer.sh` check, and owners that sign with keys. The website's coupon status reads a 65-byte signature as one key's, so with a threshold of 1 every coupon reads as invalid, and it reads a longer signature only when each owner's part is a key's signature. Its owners are the keys of the signer services, which are not built yet: see [What is not built yet](#what-is-not-built-yet).

## Launch with the admin Safe

```sh
ETH_RPC_URL=... \
ADMIN_ADDRESS=<the admin Safe> ADMIN_SAFE_THRESHOLD=2 ADMIN_SAFE_OWNERS=0x...,0x...,0x... \
VALID_SIGNER=<the coupon signer: a key, or the signer Safe> \
./deploy-mainnet.sh --ledger
```

The deploy prints the Safe's threshold and owners as it read them, sends its one transaction, then prints the deploy record, which refuses a vault whose admin changed other than once, from the `HoloBridgeDeployer` to `ADMIN_ADDRESS`. [DEPLOY.md](../DEPLOY.md#mainnet-deploy) has the whole flow.

To hand the vault to one key regardless, set `UNSAFE_ALLOW_SINGLE_KEY_ADMIN=yes`. The deploy then takes a key, or a Safe of threshold 1, as `ADMIN_ADDRESS`, and logs that one key controls the vault. `setAdmin` from that key moves the vault to a Safe later:

```sh
cast send "$MAINNET_LOCK_VAULT_ADDRESS" 'setAdmin(address)' "$SAFE" --ledger --rpc-url "$ETH_RPC_URL"
cast call "$MAINNET_LOCK_VAULT_ADDRESS" 'admin()(address)' --rpc-url "$ETH_RPC_URL"
```

## The coupon signer: a key or a Safe

`VALID_SIGNER` at the deploy, or at a rotation, is either:

- **A key.** The orchestrator runs with `SIGNER_PRIVATE_KEY`, that key. At startup it refuses unless the claim order on chain accepts coupons signed with it.
- **A Safe.** The orchestrator runs with `SAFE_OWNER_KEYS`: the keys of as many of the Safe's owners as its threshold, separated by commas, and no `SIGNER_PRIVATE_KEY`. It signs each coupon as all of them, naming the Safe as the coupon's signer, and at startup it reads the Safe's threshold, owners and EIP-712 domain, refuses a key count other than the threshold, a key that is not an owner's, or a key twice, and then simulates a claim through the Safe's own `isValidSignature`. **This is one party signing as the Safe, however many keys it holds.** It makes the Safe the signer on chain, so that owners can later be replaced by independent signer services without another rotation, but it adds no protection until each owner checks the withdrawal itself before it signs. That is the [signer service](./signer-service.md), which is not built.

## Move the coupon signer to a Safe later

1. Create the signer Safe, as above.
2. Stop the orchestrator. Until step 3, any coupon it signs is for an order that is about to be removed.
3. Replace the claim order with one whose `valid-signer` is the Safe. Export the current deploy record's lines, then run:

   ```sh
   ETH_RPC_URL=... VALID_SIGNER=<the Safe> ./rotate-claim-signer.sh
   ```

   The script adds the new order and then removes the old one, through the vault admin. It reads the old order from the record's `NETWORK`, `MAINNET_LOCK_VAULT_ADDRESS`, `ORDER_HASH`, `PUBLIC_CLAIM_BYTECODE` and `PUBLIC_CLAIM_INPUT_TOKEN`. The new record it prints is read from the chain, and the script refuses to print it unless the new order accepts coupons from `VALID_SIGNER`.

   - If the admin is a Safe, pass no wallet option. The script sends nothing and prints the two calls. Propose each from the admin Safe in that order, in the Safe web app's Transaction Builder: the vault as the address, value 0, and the printed data. When both have run, print the new deploy record with `./rotate-claim-signer.sh record <block of the first call>`. It checks only the orders the vault added from that block on, so pass the first call's own block.
   - If the admin is a key, pass its wallet option, `--ledger` or `--account <keystore>`. The script sends both calls and prints the new deploy record.
4. Give the orchestrator the new record's `ORDER_HASH`, `CLAIM_SIGNER`, `CLAIM_INTERPRETER`, `CLAIM_STORE`, `CLAIM_BYTECODE` and `CLAIM_INPUT_TOKEN`, and `SAFE_OWNER_KEYS` in place of `SIGNER_PRIVATE_KEY`, then start it.
5. Give the website the new `PUBLIC_CLAIM_ORDER_HASH`, `PUBLIC_CLAIM_SIGNER`, `PUBLIC_CLAIM_INTERPRETER`, `PUBLIC_CLAIM_STORE`, `PUBLIC_CLAIM_BYTECODE` and `PUBLIC_CLAIM_INPUT_TOKEN` from the new deploy record, then build and deploy it again. The build refuses values that do not hash to the order hash, but it cannot check the signer. Its coupon status asks the Safe's `isValidSignature` for each coupon that names it, in the same call that reads the coupon's nonce.
6. Reissue the coupons that were not claimed. A coupon names its order's hash, so a coupon for the old order fails on the new one.

The claim order marks a nonce used under its own order hash. A withdrawal claimed on an old order is not marked on the new one, so a new coupon for it pays it a second time. Reissue a coupon only once its order is removed, and only for a withdrawal none of whose coupons is redeemed. To read whether a coupon is redeemed, ask the store of the order it names, where a nonzero answer means redeemed:

```sh
namespace=$(cast keccak "$(cast abi-encode 'f(address,address)' "$VAULT" "$ORDERBOOK")")
key=$(cast keccak "$(cast abi-encode --packed 'f(uint256,uint256)' "$COUPON_ORDER_HASH" "$NONCE")")
cast call "$COUPON_ORDER_STORE" 'get(uint256,bytes32)(bytes32)' "$namespace" "$key" --rpc-url "$ETH_RPC_URL"
```

`COUPON_ORDER_HASH` is the coupon's sixth field, `NONCE` its last, and `COUPON_ORDER_STORE` the `PUBLIC_CLAIM_STORE` of the deploy record that named that order. After more than one rotation, check every order a withdrawal has had a coupon for.

## Fireblocks as the coupon signer

A Fireblocks MPC wallet is a paid alternative to a Safe. It signs as one Ethereum address, so the claim order needs only that address as `valid-signer`, set at the deploy or with `rotate-claim-signer.sh` as above. The website needs no code change, only the new build variables, as it checks a 65-byte signature as one key's. The orchestrator needs a `CouponKey` in `bridge-orchestrator/src/signer.rs` that has Fireblocks sign the coupon's digest and returns the 65-byte signature, and its startup check compares `CLAIM_SIGNER` with that key's address.

## What is not built yet

A Safe as the coupon signer is M-of-N only once each owner checks the withdrawal itself. Until then, the orchestrator holding every owner key is one party, as a single key is.

- **The signer service**, one per owner. It receives a signing request from the orchestrator, reads the withdrawal from its own Holochain node, checks the burn, its amount and recipient, the coupon's expiry and nonce, and the claim order, and signs the coupon's SafeMessage hash with its own owner key only when all of it holds. [signer-service.md](./signer-service.md) says what it receives and what it checks, and lists the open questions.
- **The orchestrator collecting the signatures.** A `CouponKey` for the Safe in `bridge-orchestrator/src/signer.rs` that asks each service, waits for the threshold, sorts the signatures by owner address and joins them, in place of `SafeOwners`, which signs with the keys it holds. Coupon building does not change.
