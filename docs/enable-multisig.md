# The bridge's Safes and its M-of-N coupon signers

On mainnet the vault admin is a Safe multisig from the bridge's first transaction. The claim order lists N coupon signers and takes a coupon only when M of them signed it. Each signer is a key or a Safe. Neither the admin nor the signers needs a contract change or a redeploy to change later.

- **The vault admin** is `ADMIN_ADDRESS`, which `deploy-mainnet.sh` hands the vault to inside the one transaction that deploys it: a `HoloBridgeDeployer` deploys the claim input token and the vault with itself as admin, adds the claim order through the vault, and calls `setAdmin(ADMIN_ADDRESS)`, all in that transaction. No key is the admin at any point, and the deployer contract holds no right once the transaction ends. The deploy refuses a key, a contract that is not a Safe, or a Safe of threshold 1 as `ADMIN_ADDRESS`, so that no one key controls the vault, unless `UNSAFE_ALLOW_SINGLE_KEY_ADMIN=yes` is set, which it logs. From then on every admin call is a Safe transaction its threshold of owners approve: `adminWithdraw`, `adminRecoverTokens`, `setMinLockAmount`, `addOrder`, `removeOrder` and `setAdmin`.
- **The coupon signers** are `VALID_SIGNERS`, N addresses, and `SIGNER_THRESHOLD`, M, given at the deploy or at a rotation. Both are written into the claim order's expression, so changing either is a new order.

`test/fork-rehearsal.sh` proves this on a fork of mainnet, with 2 of 3 signers: see [DEPLOY.md](../DEPLOY.md#rehearse-it-first).

Each key holder follows [key-holder.md](./key-holder.md).

## How the claim order checks M of N

A claim carries the coupon's nine words signed by M signers: one signed context per signer, each with the same nine words. Signed context i is seat i. `compose-rainlang.mjs` writes these checks into `src/holo-claim.rain` from the signer list and the threshold:

| check | refusal |
|---|---|
| The signer of each of seats 0 to M-1 is one of the N | `Wrong signer` |
| No signer fills two seats | `Duplicate signer` |
| Every seat signed the same nine words as seat 0: their hashes are equal | `Coupons differ` |
| The claim carries at least M seats | Solidity's `Panic(0x32)`: the order reads seat M-1, which is not there |

Before the order runs, Raindex V6 checks the signature of every seat a claim carries, and refuses a bad one with `InvalidSignature(i)`, i the seat. It checks a key's 65-byte signature by recovery, and asks a contract signer's EIP-1271 `isValidSignature` (OpenZeppelin's `SignatureChecker`). A claim may carry more than M seats: the order reads seats 0 to M-1 only, and Raindex still checks the signature of every seat.

Each signer is one of:

- **A key with no EIP-7702 delegation.** Raindex V6 counts a delegated key as a contract, asks its delegate, and never checks the key's own signature, so the deploy and rotation scripts and the orchestrator refuse one. A delegated key can still be a Safe owner, as the Safe recovers each owner's signature itself.
- **A Safe of threshold 2 to 20.** A Safe 1.4.1 answers `isValidSignature` through its `CompatibilityFallbackHandler`, which accepts the signatures of its threshold of owners over the SafeMessage hash of the coupon's digest, sorted by owner address and joined. A Safe fills one seat, however many owners sign for it. The website reads a 65-byte signature as a key's, so it would read the signature of a Safe of threshold 1 as invalid; the scripts refuse such a Safe.

The deploy and the rotation also refuse more than 15 signers, a signer listed twice, a threshold outside 1 to N, and the test signer on mainnet. They take a threshold of 1 on mainnet, and log it: any one signer alone then signs coupons that pay out of the vault.

### Two limits of the deployed Rainlang

**The words.** The checks follow the M-of-N example of st0x.attest's SPEC.md: `binary-in<M>` over the seats and the signer list, and `binary-unique` over the seats. Those words came after Rainlang 0.1.9, the release deployed on mainnet and Base Sepolia. Its parser answers `UnknownWord` for both, and `BadOpInputsLength` for a `binary-equal-to` of more than two inputs; `test/TestClaim.t.sol` pins this against the deployed parser. So the composer writes the same checks with the words 0.1.9 has: for membership, an `any` of `binary-equal-to` per seat; for uniqueness, `is-zero(binary-equal-to(...))` per pair of seats; and for the coupon, the hash of each seat's nine words compared with the hash of seat 0's. When a release with the newer words is deployed, the composer can write them instead, in fewer operations, as a new order.

**The size.** The deployed parser takes at most 255 operations in one source, and refuses more with `SourceTotalOpsOverflow`. The claim order's `calculate-io` holds 49 besides the signer checks. The signer checks take M(3N+3), plus 3M(M-1) + 14M - 4 when M is more than 1. The composer counts operations as the parser does, and the deploy and the rotation refuse a larger shape by name before they send anything. The largest shapes that parse:

| M | largest N | operations |
|---|---|---|
| 1 | 15 | 97 |
| 2 | 15 | 175 |
| 3 | 15 | 249 |
| 4 | 8 | 245 (4 of 9 is 257) |
| 5 or more | none | 5 of 5 is 265 |

`test/TestClaim.t.sol` has the deployed parser parse 4 of 8 and 3 of 15, and refuse 4 of 9 and 5 of 5.

## The orchestrator collects M signatures

The orchestrator reads `CLAIM_SIGNERS` and `CLAIM_THRESHOLD` from the deploy record. It signs for the signers it is given through any mix of:

- `SIGNER_PRIVATE_KEY`: one or more keys, separated by commas, each the key of one listed signer.
- `SAFE_SIGNER` and `SAFE_OWNER_KEYS`: a listed Safe, and the keys of as many of its owners as its threshold. It signs as all of them, naming the Safe as the seat's signer. **This is one party signing as the Safe, however many keys it holds.**
- `SIGNER_SERVICES`: `<signer>=<url>` entries, separated by commas, each an independent party's [signer service](./signer-service.md) for one listed signer.

For each withdrawal it asks every signer at once, and gives each 20 seconds. It takes the first M that sign, in `CLAIM_SIGNERS` order, and writes the coupon as `signer1,signature1,...,signerM,signatureM,c0,...,c8`. A coupon from before M-of-N is the same with one seat. With fewer than M signatures, the withdrawal stays parked and is asked again on the next cycle; the error names why each other signer did not sign.

At startup it refuses, before it reads Holochain:

- a signer it signs for that `CLAIM_SIGNERS` does not list, or one it signs for twice
- fewer signers than `CLAIM_THRESHOLD`
- a listed key with an EIP-7702 delegation, a key given for a listed contract, or a `SAFE_SIGNER` with no contract
- a `SAFE_SIGNER` that does not answer as a Safe 1.3.0 or later on the chain, whose threshold is not the number of `SAFE_OWNER_KEYS`, or that does not have each of them as an owner
- a signer service that answers `GET /signer` for another signer or chain

It logs a signer service that does not answer, and passes while the signers that can sign are at least M. Then it simulates two claims with coupons its own keys sign: one with M seats, which the order must take, and one with M-1, which the order must refuse because it reads seat M-1. So a record whose `CLAIM_THRESHOLD` or `CLAIM_SIGNERS` is not the order's stops it. With fewer than M signers here, it simulates a claim with as many as there are, which the order must refuse in the same way, after it found each of them listed.

### What M-of-N protects, and what it does not

M signatures protect the vault only when M independent parties each check the withdrawal before they sign. An orchestrator that holds M keys, or a Safe's owner keys, is one party: one compromise of it signs any coupon. The protection comes from signer services that other parties run, each of which checks the burn on its own Holochain node: [signer-service.md](./signer-service.md).

## Create the Safes

In the Safe web app, create a Safe on Ethereum for the vault admin with three or more owners and a threshold of 2 or more. Write down its address, its threshold and its owners: the deploy takes all three and refuses a Safe that answers otherwise, so the vault cannot go to a Safe other than the one meant.

A Safe that is one of the coupon signers needs a threshold of 2 to 20, which the deploy and `rotate-claim-signer.sh` check, and owners that sign with keys: the website reads its signature only when each owner's part is a key's 65-byte signature.

## Launch

```sh
ETH_RPC_URL=... \
ADMIN_ADDRESS=<the admin Safe> ADMIN_SAFE_THRESHOLD=2 ADMIN_SAFE_OWNERS=0x...,0x...,0x... \
VALID_SIGNERS=<the N coupon signers, keys or Safes, separated by commas> SIGNER_THRESHOLD=<M> \
./deploy-mainnet.sh --ledger
```

The deploy prints the Safe's threshold and owners as it read them, sends its one transaction, then prints the deploy record, which refuses a vault whose admin changed other than once, from the `HoloBridgeDeployer` to `ADMIN_ADDRESS`. The record holds `CLAIM_SIGNERS` and `CLAIM_THRESHOLD` for the orchestrator, and `PUBLIC_CLAIM_SIGNERS` and `PUBLIC_CLAIM_THRESHOLD` for the website. [DEPLOY.md](../DEPLOY.md#mainnet-deploy) has the whole flow.

To hand the vault to one key regardless, set `UNSAFE_ALLOW_SINGLE_KEY_ADMIN=yes`. The deploy then takes a key, or a Safe of threshold 1, as `ADMIN_ADDRESS`, and logs that one key controls the vault. `setAdmin` from that key moves the vault to a Safe later:

```sh
cast send "$MAINNET_LOCK_VAULT_ADDRESS" 'setAdmin(address)' "$SAFE" --ledger --rpc-url "$ETH_RPC_URL"
cast call "$MAINNET_LOCK_VAULT_ADDRESS" 'admin()(address)' --rpc-url "$ETH_RPC_URL"
```

## Change the signers or the threshold

1. Create any new signer Safe, as above.
2. Stop the orchestrator. Until step 3, any coupon it signs is for an order that is about to be removed.
3. Replace the claim order with one for the new signers and threshold. Export the current deploy record's lines, then run:

   ```sh
   ETH_RPC_URL=... VALID_SIGNERS=<the new N> SIGNER_THRESHOLD=<the new M> ./rotate-claim-signer.sh
   ```

   The script adds the new order and then removes the old one, through the vault admin. It reads the old order from the record's `NETWORK`, `MAINNET_LOCK_VAULT_ADDRESS`, `ORDER_HASH`, `PUBLIC_CLAIM_BYTECODE` and `PUBLIC_CLAIM_INPUT_TOKEN`. The new record it prints is read from the chain, and the script refuses to print it unless the new order's expression is the one composed for `VALID_SIGNERS`, in their order, and `SIGNER_THRESHOLD`.

   - If the admin is a Safe, pass no wallet option. The script sends nothing and prints the two calls. Propose each from the admin Safe in that order, in the Safe web app's Transaction Builder: the vault as the address, value 0, and the printed data. When both have run, print the new deploy record with `./rotate-claim-signer.sh record <block of the first call>`. It checks only the orders the vault added from that block on, so pass the first call's own block.
   - If the admin is a key, pass its wallet option, `--ledger` or `--account <keystore>`. The script sends both calls and prints the new deploy record.
4. Give the orchestrator the new record's `ORDER_HASH`, `CLAIM_SIGNERS`, `CLAIM_THRESHOLD`, `CLAIM_INTERPRETER`, `CLAIM_STORE`, `CLAIM_BYTECODE` and `CLAIM_INPUT_TOKEN`, and the signer settings for the new signers, then start it.
5. Give the website the new `PUBLIC_CLAIM_ORDER_HASH`, `PUBLIC_CLAIM_SIGNERS`, `PUBLIC_CLAIM_THRESHOLD`, `PUBLIC_CLAIM_INTERPRETER`, `PUBLIC_CLAIM_STORE`, `PUBLIC_CLAIM_BYTECODE` and `PUBLIC_CLAIM_INPUT_TOKEN` from the new deploy record, then build and deploy it again. The build refuses values that do not hash to the order hash, but it cannot check the signers or the threshold against the order, so take them from the record.
6. Reissue the coupons that were not claimed. A coupon names its order's hash, so a coupon for the old order fails on the new one.

The claim order marks a nonce used under its own order hash. A withdrawal claimed on an old order is not marked on the new one, so a new coupon for it pays it a second time. Reissue a coupon only once its order is removed, and only for a withdrawal none of whose coupons is redeemed. To read whether a coupon is redeemed, ask the store of the order it names, where a nonzero answer means redeemed:

```sh
namespace=$(cast keccak "$(cast abi-encode 'f(address,address)' "$VAULT" "$ORDERBOOK")")
key=$(cast keccak "$(cast abi-encode --packed 'f(uint256,uint256)' "$COUPON_ORDER_HASH" "$NONCE")")
cast call "$COUPON_ORDER_STORE" 'get(uint256,bytes32)(bytes32)' "$namespace" "$key" --rpc-url "$ETH_RPC_URL"
```

`COUPON_ORDER_HASH` is the fourth of the nine numbers at the end of the coupon, `NONCE` the last, and `COUPON_ORDER_STORE` the `PUBLIC_CLAIM_STORE` of the deploy record that named that order. After more than one rotation, check every order a withdrawal has had a coupon for.

## Fireblocks as one of the signers

A Fireblocks MPC wallet is a paid alternative to a Safe. It signs as one Ethereum address, so it is one entry of `VALID_SIGNERS`. The website needs no code change, as it checks a 65-byte signature as a key's. The orchestrator needs a `CouponKey` in `bridge-orchestrator/src/signer.rs` that has Fireblocks sign the coupon's digest and returns the 65-byte signature, or a signer service in front of Fireblocks.

## What is not built yet

**The signer service.** The orchestrator's side is built: for `SIGNER_SERVICES` it asks each service over HTTP, checks the answer, and fills a seat with it. The service itself, which reads the withdrawal from its own Holochain node and checks it before it signs, is not. [signer-service.md](./signer-service.md) says what it receives, what it must check and what it answers. Until independent parties run it, the M signatures come from keys that one orchestrator holds, which is one party.
