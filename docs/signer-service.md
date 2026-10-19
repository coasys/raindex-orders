# The signer service: the API between the orchestrator and each Safe owner

This is the contract for the signer services Unyt builds. One Safe is the bridge's vault admin and its coupon signer ([enable-multisig.md](./enable-multisig.md)). The Safe has N owners and a threshold M. Each owner is a signer service run by a separate party, holding that owner's key. A HOT claim on Ethereum pays only with a coupon that M owners signed.

The orchestrator's side is built and tested (`bridge-orchestrator/src/signer/safe.rs`). The rehearsal runs it against mock services (`ui/scripts/mock-signer-service.mjs`) that speak this API but check nothing on Holochain. The real services are not built.

## Why each service checks for itself

A coupon pays HOT out of the vault to the address it names, for the amount it names, once. M owner signatures over a coupon make it valid. If one party could produce M signatures, it could empty the vault. So each service must sign only what it has checked against its own Holochain node and its own copy of the deploy record, never what the orchestrator tells it.

**The same owner key also approves the Safe's admin transactions.** A coupon signature cannot be used as an admin approval: the two are hashed with different EIP-712 types, so a signature over one is not valid for the other ([enable-multisig.md](./enable-multisig.md#one-safe-for-both-roles)). That holds only if the service signs nothing but the hash it computed itself from coupon words it checked. **A service must never sign a hash it was sent.** A service that signs any 32 bytes it is given would sign an admin transaction's hash just as readily.

## Endpoints

Each service has a base URL. The orchestrator names it in `SAFE_OWNER_SERVICES` as `<owner address>=<base URL>`, separated by commas. On mainnet the URL must be https, or http to the same machine.

### `GET <base URL>/signer`

Who the service signs as. The orchestrator asks at startup and refuses to start if the answer is not the owner, Safe and chain it was configured with.

```json
200 { "owner": "0x7099...79C8", "safe": "0x3838...7a22", "chainId": 1 }
```

### `POST <base URL>/sign`

One request per coupon. Body, `Content-Type: application/json`:

| field | type | content |
|---|---|---|
| `safe` | string | The Safe, the claim order's coupon signer: `0x` and 40 hex digits |
| `chainId` | number | 1 for Ethereum mainnet, 84532 for Base Sepolia |
| `owner` | string | The owner the service is asked to sign as: `0x` and 40 hex digits |
| `withdrawal` | string or null | The withdrawal spend's Holochain action hash, in holo_hash's base64 form (`u` then base64url of its 39 bytes). `null` for the startup probe, below |
| `context` | array of 10 strings | The coupon's ten words, each `0x` and 64 hex digits, in the order below |
| `couponDigest` | string | The digest of the ten words, for comparison only |
| `safeMessageHash` | string | The hash the owner signs, for comparison only |

Addresses arrive in lowercase. Compare them without regard to case.

The ten words, each 32 bytes:

| # | word | encoding |
|---|---|---|
| 0 | recipient | the Ethereum address, left-padded with zeros |
| 1 | amount | a Rain decimal float: the top 4 bytes are `ffffffee` (exponent -18), the low 224 bits are the amount in wei (1.5 HOT is `0xffffffee000…0014d1120d7b160000`) |
| 2 | expiry | Unix seconds, as a plain integer |
| 3 | order hash | the deploy record's `ORDER_HASH` |
| 4 | order owner | the vault, `MAINNET_LOCK_VAULT_ADDRESS`, left-padded |
| 5 | orderbook | Raindex V6, `ORDERBOOK_ADDRESS`, left-padded |
| 6 | token | HOT, `TOKEN_ADDRESS`, left-padded |
| 7 | vault ID | `VAULT_ID` |
| 8 | nonce | keccak256 of the withdrawal action hash's 39 raw bytes |
| 9 | chain ID | the chain the coupon claims on, as a plain integer, left-padded: 1 for Ethereum mainnet (`0x00…01`), 84532 for Base Sepolia (`0x00…014a34`). The claim order refuses a coupon whose word 9 is not the chain it runs on |

Answers:

```json
200 { "owner": "0x7099...79C8", "signature": "0x<130 hex digits>" }
409 { "code": "amount_mismatch", "reason": "the amount 40 HOT is not the spend's 30 HOT" }
```

`signature` is 65 bytes: r, s, then v as 27 or 28, over `safeMessageHash` with no prefix. That is what a wallet's `eth_signTypedData_v4` of the typed data below returns, and what `sign(hash)` returns in most key libraries. The orchestrator also takes v as 0 or 1, and Safe's `eth_sign` form: v as 31 or 32, over the EIP-191 hash of `safeMessageHash`. Any s is fine, high or low: Safe's `ecrecover` does not require a low s.

A refusal is HTTP 409 with a `code` from this list and a `reason` for people. The orchestrator logs the code and the first 200 characters of the reason.

| code | when |
|---|---|
| `unknown_withdrawal` | the service's node does not hold a spend with that action hash |
| `not_a_withdrawal` | the spend is not a bridge withdrawal (role, lane or unit, below), is no longer parked, or its HOT amount is not one a coupon can carry ([the amount](#the-amount)) |
| `amount_mismatch` | word 1 is not the word the service makes of the spend's amount |
| `recipient_mismatch` | word 0 is not the spend's withdraw-to address |
| `expiry_out_of_range` | word 2 is outside the window in [the expiry](#the-expiry) |
| `nonce_mismatch` | word 8 is not keccak256 of the withdrawal's 39 bytes |
| `order_mismatch` | words 3 to 7 are not the service's own copy of the deploy record |
| `chain_mismatch` | word 9 is not the chain ID the service signs for |
| `wrong_safe_or_chain` | `safe` or `chainId` is not what the service signs for |
| `wrong_owner` | `owner` is not the service's owner |
| `probe_mismatch` | `withdrawal` is null and the words are not the startup probe's |
| `hash_mismatch` | the service's own digest or SafeMessage hash differs from the one sent |
| `already_signed` | the service signed this withdrawal for another order hash, and no operator has cleared that ([one order per withdrawal](#one-order-per-withdrawal)) |
| `not_ready` | the service cannot check now, for example its node is not in sync (HTTP 503 works too) |

Any other status (400 for a malformed body, 401 or 403 for authentication, 500, 503) counts as "did not sign", and the orchestrator logs the status. So does a redirect, which the orchestrator does not follow, and an answer of more than 64 KiB.

## The hash an owner signs

1. **The coupon digest**, which Raindex V6 checks the coupon against:
   `couponDigest = keccak256("\x19Ethereum Signed Message:\n32" ‖ keccak256(word0 ‖ word1 ‖ … ‖ word9))`
2. **The Safe's domain separator**, as Safe 1.3.0 and later compute it:
   `domainSeparator = keccak256(abi.encode(keccak256("EIP712Domain(uint256 chainId,address verifyingContract)"), chainId, safe))`
3. **The SafeMessage hash**, which the owner signs:
   `safeMessageHash = keccak256(0x19 ‖ 0x01 ‖ domainSeparator ‖ keccak256(abi.encode(keccak256("SafeMessage(bytes message)"), keccak256(couponDigest))))`

`‖` is byte concatenation. In step 3 the message is the 32 bytes of the digest, so `keccak256(message)` is `keccak256(couponDigest)`. This is the EIP-712 hash of this typed data, which a wallet or signing library can sign directly:

```json
{
  "domain": { "chainId": 1, "verifyingContract": "<safe>" },
  "types": { "SafeMessage": [{ "name": "message", "type": "bytes" }] },
  "primaryType": "SafeMessage",
  "message": { "message": "<couponDigest>" }
}
```

The Safe itself computes the same hash: `getMessageHashForSafe(safe, abi.encode(couponDigest))` on the CompatibilityFallbackHandler (`0xfd0732Dc9E303f09fCEf3a7388Ad10A83459Ec99`) answers it, so a service can compare its own result with the chain by an `eth_call`.

### Worked example

The coupon test vector, for a Safe of threshold 2 at `0x3838Fc4E0cba211c3D6D202539bB2dc2B72C7a22` on chain 1, whose owners are anvil's public test accounts 1, 2 and 3. The request to the service of owner `0x70997970C51812dc3A010C7d01b50e0d17dc79C8`:

```json
{
  "safe": "0x3838fc4e0cba211c3d6d202539bb2dc2b72c7a22",
  "chainId": 1,
  "owner": "0x70997970c51812dc3a010c7d01b50e0d17dc79c8",
  "withdrawal": "uhCkkBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBweIGAsC",
  "context": [
    "0x0000000000000000000000001111111111111111111111111111111111111111",
    "0xffffffee000000000000000000000000000000000000000014d1120d7b160000",
    "0x0000000000000000000000000000000000000000000000000000000068581c00",
    "0x5eeff397dac16f82057e20da98cf183daf95a0695980a196270e9e0922a275f9",
    "0x000000000000000000000000e3e064e3c2eef66cb93da8d8114f5084e92f48d6",
    "0x00000000000000000000000037fc0efec37d19f8a221aa4f8f7600c9ba2acd20",
    "0x0000000000000000000000006c6ee5e31d828de241282b9606c8e98ea48526e2",
    "0xeede83a4244afae4fef82c8f5b97df1f18bfe3193e65ba02052e37f6171b334b",
    "0x12c911abe545a1669fcbcdaeeede5352ee5a6743f59dbacdc0251b1e4c2f7b77",
    "0x0000000000000000000000000000000000000000000000000000000000000001"
  ],
  "couponDigest": "0x4cb8e1ac1a5194e298140ad5c708b227eec55df3ffd4c983641a9d81c544aa60",
  "safeMessageHash": "0xa2725acb9f918ab1eb2e6657d2d7ebecec2a152c93c3101f123385804bd5bffe"
}
```

The values along the way:

| value | |
|---|---|
| keccak256 of the ten words | `0x0ac233176e8632bb38ec9cfe568ec7f6f1f60bdd99b2b27843b78bf5d2954a70` |
| `couponDigest` | `0x4cb8e1ac1a5194e298140ad5c708b227eec55df3ffd4c983641a9d81c544aa60` |
| `domainSeparator` | `0x153d4789a76b589663cd7eaf7cecb28f92d106099b7323da9c72d5befb893f94` |
| `keccak256("SafeMessage(bytes message)")` | `0x60b3cbf8b4a223d68d641b3b6ddf9a298e7f33710cf3d3a9d1146b5a6150fbca` |
| struct hash | `0x052264522319a088369b93b36b377d11d46c253188dfc029e6448ccb8114545f` |
| `safeMessageHash` | `0xa2725acb9f918ab1eb2e6657d2d7ebecec2a152c93c3101f123385804bd5bffe` |

The owner's key is public (anvil's account 1, `0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d`), so its signature is a test vector too:

```
0x2400e7ddd4b737971e696dbfc5f5f9f6516d15980925ee2e38cb2b6a7be87dfb0fe177ede6ba7a45519c44841019e1f2357988698c43808dbe48cd8d53e170bc1b
```

This example's expiry is in 2025, so a real service refuses it with `expiry_out_of_range`. These values agree in `bridge-orchestrator/src/signer/safe/tests.rs` (Rust), `ui/scripts/safe-message.test.ts` (viem), `test/TestSafeCouponSignature.t.sol` (Solidity, against Safe 1.4.1 on a mainnet fork), and `cast`.

### Reference code

`ui/scripts/safe-message.mjs`, with viem:

```js
import { encodePacked, hashTypedData, keccak256 } from 'viem'
import { privateKeyToAccount } from 'viem/accounts'

export function couponDigest(words) {
	const packed = keccak256(encodePacked(Array(10).fill('bytes32'), words))
	return keccak256(encodePacked(['string', 'bytes32'], ['\x19Ethereum Signed Message:\n32', packed]))
}

export function safeMessageHash({ chainId, safe, digest }) {
	return hashTypedData({
		domain: { chainId, verifyingContract: safe },
		types: { SafeMessage: [{ name: 'message', type: 'bytes' }] },
		primaryType: 'SafeMessage',
		message: { message: digest }
	})
}

export async function signAsOwner(key, hash) {
	return privateKeyToAccount(key).sign({ hash }) // r, s, v with v 27 or 28
}
```

## What the service checks before it signs

Each check uses the service's own sources: its own Holochain node, or one it trusts, and a copy of the deploy record it was given when it was set up, never the request.

1. **The burn is real.** `withdrawal` names a spend on the Unyt network that the service's node holds. It is a parked spend whose counterparty role is `withdrawer`, in the bridging agent's lane for HOT: the one spend the bridge's template pays a withdrawal from. **Parked means parked when the service signs**: not yet accepted on Holochain, by the RAVE that delivers its coupon or otherwise. A withdrawal that is accepted already has its coupon, and the service does not sign it again. The orchestrator makes the same check (`bridging_spend` in `bridge-orchestrator/src/orchestrator.rs`), and each service must make it again on its own node. Otherwise `unknown_withdrawal` or `not_a_withdrawal`.
2. **The amount.** Word 1 is exactly the spend's amount in the HOT unit, converted as in [the amount](#the-amount) below. Not more, not another unit.
3. **The recipient.** Word 0 is the `withdraw_to_address` in the spend's attached payload.
4. **The expiry.** Word 2 is within the window in [the expiry](#the-expiry) below.
5. **The nonce.** Word 8 is keccak256 of the action hash's 39 raw bytes. Every coupon for one withdrawal carries this nonce, and the claim order marks it used under the vault, so only one of them ever claims, on any claim order the vault adds ([one order per withdrawal](#one-order-per-withdrawal)). Signing the same withdrawal again is safe for the same order; for another order, check 8 refuses it, the services' own line behind the chain's. A coupon whose nonce is not the withdrawal's would let one burn be claimed twice.
6. **The order and the chain.** Words 3 to 7 equal the service's copy of the deploy record, word 9 is the chain ID the service signs for, and `safe`, `chainId` and `owner` are what the service signs for. Otherwise `order_mismatch`, `chain_mismatch` or `wrong_safe_or_chain`. The claim order checks word 9 too: Raindex V6 and the vault can have the same addresses on two chains, and without it a coupon signed by a key would claim on both. The Safe's domain already binds the owners' signatures to one chain; word 9 puts the chain in the coupon itself, so a key and a Safe alike sign for one chain.
7. **The hashes.** The service computes `couponDigest` and `safeMessageHash` from the words it checked, and refuses with `hash_mismatch` if the request's differ. It signs its own `safeMessageHash`, and nothing else.
8. **One order per withdrawal.** The service has not signed this withdrawal for another order hash, as [below](#one-order-per-withdrawal). Otherwise `already_signed`.

If any check fails, the service refuses with its code and alerts a person. A refusal means the orchestrator and the service see the network differently: a bug, or an attack.

### The amount

The spend's `amount` maps each unit index, as a string, to a decimal string: a ZFuel, as `rave_engine` serialises it. The HOT amount is the entry under the bridge's `HOT_UNIT_INDEX`. The service converts it as the orchestrator does (`hot_in_wei` in `bridge-orchestrator/src/signer.rs`):

- **Format.** Digits, optionally a `.` and more digits: `5`, `1.5`, `0.000001`. Digits are required on both sides of a `.`, and there is no sign, exponent, space or hex.
- **Exact.** wei = the decimal × 10^18, with no rounding. At most 18 fractional digits; a ZFuel holds at most 6, so every real amount converts exactly.
- **Not zero.**
- **The word** is `ffffffee` (exponent -18) and then the wei as a 224-bit integer, as in the word table above. The service builds this word itself and compares all 32 bytes with word 1. It does not compare numeric values, as a float has more than one encoding of a value.

A spend with no HOT entry, or one that breaks these rules, is refused with `not_a_withdrawal`, since no coupon can pay it. A word 1 other than the service's own word is refused with `amount_mismatch`. `bridge-orchestrator/src/signer/safe/tests.rs` pins these vectors:

| amount | word 1 |
|---|---|
| `"1.5"` | `0xffffffee000000000000000000000000000000000000000014d1120d7b160000` |
| `"5"` | `0xffffffee00000000000000000000000000000000000000004563918244f40000` |
| `"0.000001"` | `0xffffffee0000000000000000000000000000000000000000000000e8d4a51000` |
| `"0.000000000000000001"` | `0xffffffee00000000000000000000000000000000000000000000000000000001` |
| `"0"`, `"0.0"`, `"-1"`, `"1e18"`, `".5"`, `"5."`, `"1.0000000000000000001"` | refused |

The last vector has more digits than a ZFuel holds. It tests the conversion, not a spend that can exist.

### The expiry

The orchestrator sets word 2 to its clock's now plus `EXPIRY_SECONDS`, 604800 (7 days) by default. Each service is configured with the same `EXPIRY_SECONDS` and with a tolerance for the two clocks, `EXPIRY_TOLERANCE_SECONDS`, 600 (10 minutes) by default. With `now` from the service's own clock, it signs only when:

```
now - EXPIRY_TOLERANCE_SECONDS  <  word 2  <=  now + EXPIRY_SECONDS + EXPIRY_TOLERANCE_SECONDS
```

So a clock up to 10 minutes apart does not park withdrawals, and no coupon lives more than 10 minutes past the agreed maximum. If the parties agree on a shorter maximum, the orchestrator's `EXPIRY_SECONDS` must change with it. Otherwise every coupon is refused with `expiry_out_of_range`. The mock services use the same defaults.

### One order per withdrawal

The claim order marks a nonce used at the nonce alone, under the store namespace Raindex keeps for the order's owner, the vault. A withdrawal claimed on one claim order is used on every claim order the vault adds after a rotation, so a second coupon for it fails on chain with `Nonce already used`, whatever order hash it names (`test/TestClaim.t.sol`, `testANonceClaimedOnOneClaimOrderIsUsedOnTheNext`). That holds while a rotation keeps the deploy record's `CLAIM_STORE`, as `rotate-claim-signer.sh` does ([enable-multisig.md](./enable-multisig.md#move-the-coupon-signer-to-another-signer)). Check 1 stops a second coupon for a withdrawal already accepted on Holochain. This rule is the services' own line behind the chain's: it stops a second coupon from being signed at all, for a withdrawal still parked, which a faulty or compromised orchestrator can ask for again, and it would hold even if a claim order were ever run by another store. The orchestrator is the one party the services exist to distrust.

A service **must**:

- Keep a durable record of each withdrawal it signed, with the order hash (word 3) it signed it for. It writes the record before it returns the signature. The record survives restarts and redeploys of the service.
- Sign a withdrawal again for the same order hash. The nonce lets only one of its coupons claim.
- Refuse a withdrawal recorded under another order hash with `409 already_signed`. An operator of that service may clear the withdrawal's record only after checking both of these:
  - **Unredeemed.** The store shows the withdrawal's nonce unredeemed under the vault's namespace. [enable-multisig.md](./enable-multisig.md#move-the-coupon-signer-to-another-signer) gives the `cast` command.
  - **Removed.** The old order is removed: `orderExists(old order hash)` on the orderbook is false.

The startup probe has no withdrawal, so the service keeps no record of it.

**The records stop a second coupon only if every two sets of signers share an owner.** A coupon needs M of the Safe's N owners. If two sets of M owners can be disjoint, as in a Safe of 2 of 4, the orchestrator can have owners A and B sign a withdrawal for the old order and, after a rotation, owners C and D sign it for the new one. C and D have no record of it, so both sign, though every service kept the rule above. So **the Safe's threshold must be more than half its owners**: 2 of 3, 3 of 4, 3 of 5, not 2 of 4 or 3 of 6. Then every set that signs a withdrawal for the new order holds an owner that signed it for the old one, and that owner refuses with `already_signed`. The deploy, the rotation, `deploy-mainnet.sh safe` and the orchestrator refuse a Safe whose threshold is half its owners or fewer. The orchestrator refuses it at startup and again for each coupon, as the owners can change while it runs. Only `UNSAFE_ALLOW_ONE_PARTY_SIGNER=yes` lets it start regardless, which it logs.

**A change of owners must keep that.** Owners that signed a withdrawal can leave, and owners that never signed it can join. Take a Safe of 2 of 3, owners A, B and C, where A and B sign W. A is removed and D added, still 2 of 3, and now C and D can sign W for a new order. So before the owners sign an owner or threshold change in the Safe app, each service of the owners after the change takes in the records of every service of the owners before it, and keeps them as its own. A record a service takes in can only make it refuse, never sign. Nothing in the orchestrator or on chain checks that this was done, and the orchestrator could not be trusted to: the chain's own check, which refuses a used nonce on any claim order, is what holds the funds if the procedure slips.

### The startup probe

At startup the orchestrator sends one request with `"withdrawal": null`. Its words are fixed, so the service checks them without Holochain:

| # | value |
|---|---|
| 0 | the Safe's address, left-padded: the coupon pays the Safe itself |
| 1 | `0xffffffee00000000000000000000000000000000000000000000000000000001`: 1 wei |
| 2 | `0x000000007fffffffffffffffffffffffffffffffffffffffffffffffffffffff`: the latest expiry a float holds |
| 3–7 | the deploy record's order, as for a withdrawal |
| 8 | `0x7031e3d46970cee5696244e787b00837a2271c3769d176fc13934b96fe76265b`: keccak256 of `bridge-orchestrator startup probe` |
| 9 | the chain ID, as for a withdrawal |

The orchestrator simulates a claim with M owner signatures of the probe, which must succeed, and with M-1, which must fail with Raindex's `InvalidSignature(0)`, the Safe refusing the signatures; any other revert stops the startup. Nothing is sent to the chain. A signed probe is a real coupon, but it pays 1 wei of HOT to the Safe, once. If the Safe's owners ever claim it, its fixed nonce is used and the claim order answers `Nonce already used`. The orchestrator takes that answer as the order accepting the Safe: the nonce is the claim expression's last check, after the signer and every other word, and Raindex checks the signatures before the expression runs. A service that gets a request with no withdrawal whose words differ refuses with `probe_mismatch`.

## What the orchestrator does

- **At startup**, it reads the Safe's threshold M and its N owners, and refuses to start if M is half of N or fewer ([one order per withdrawal](#one-order-per-withdrawal)). It asks every owner's service `GET /signer` at once, each within 5 seconds, and refuses to start if a service answers for another owner, Safe or chain, or if an owner it names is not an owner of the Safe. A service that does not answer is logged and left out of the probe. The first cycle asks it again. Startup passes while the owners that can sign are at least M. Then it runs the probe, which ends once M owners have signed it.
- **For each withdrawal**, it reads the Safe's threshold M and its owners from the chain (an RPC read has 30 seconds, as every read of the chain does; past that the withdrawal stays parked for the cycle), refuses a threshold of half the owners or fewer before it asks any owner, then asks every owner's service at once. Each has 20 seconds. A service that does not answer in time is not asked again for the rest of that cycle while the other owners are at least M, so it costs one timeout a cycle rather than one for each withdrawal; the next cycle asks it again. It checks every answer: 65 bytes, a signature by that owner over the coupon's SafeMessage hash, and the owner still one of the Safe's. It takes the M lowest owner addresses among those that signed, sorts them, joins them, and asks the Safe's own `isValidSignature`, on chain, whether it accepts them. Only then does the coupon go out.
- **With fewer than M signatures**, or a Safe that does not accept them, the withdrawal stays parked. It is logged once, with each owner's reason, and asked again on the next cycle, every `BRIDGE_CYCLE_INTERVAL_MS` (3 minutes by default). There is no retry within a cycle.
- **The same withdrawal can be asked more than once while it is parked**: after a cycle where fewer than M signed, or where the RAVE that delivers its coupon failed. A service signs it again for the same order hash if the checks pass. For another order hash it refuses with `already_signed` until an operator clears it ([one order per withdrawal](#one-order-per-withdrawal)).
- **Logs** name a service by its host and port, never its URL path, which may hold a credential.

## Open questions

- **Authentication** between the orchestrator and the services. Options: mutual TLS, a bearer token in a header (the orchestrator sends none today; it supports only a token in the URL path, which it never logs), or a private network such as WireGuard. A service should not be on the open internet without one of these.
- **Key custody** in each service: an HSM, a cloud KMS, or a Ledger. The service signs a 32-byte hash (or the typed data above), so any of them works.
- **Who the owners are.** N about 3 at launch, maybe 5 later; M to be agreed, more than half of N ([one order per withdrawal](#one-order-per-withdrawal)): 2 of 3, then 3 of 5. Owners change through an ordinary Safe owner change, which the owners sign in the Safe app. The claim order does not change. A coupon whose signatures came from a removed owner must be signed again.
- **The values of `EXPIRY_SECONDS` and `EXPIRY_TOLERANCE_SECONDS`**, if not the defaults in [the expiry](#the-expiry), and **a cap per coupon or per day**, as a limit on what M compromised owners could take at once.
- **What happens while services are down.** Withdrawals stay parked while fewer than M sign; a limit on how long is policy.
