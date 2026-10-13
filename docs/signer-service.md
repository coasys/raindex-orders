# The coupon signer service

**The service is not built. The orchestrator's side of it is.** The claim order takes coupons that M of its N signers sign ([enable-multisig.md](./enable-multisig.md)). A signer service is one of those N, run by an independent party, which checks each withdrawal itself before it signs. The orchestrator asks the services that `SIGNER_SERVICES` names, as below. Today no service exists, so the orchestrator signs with keys it holds (`SIGNER_PRIVATE_KEY`, or `SAFE_OWNER_KEYS` for a Safe), which is one party however many keys it holds.

## Why each signer must check for itself

A coupon pays HOT out of the vault to the address it names, for the amount it names, once. Whoever can produce M signatures can pay out the vault's HOT, up to what claims take. With one key, or with one process holding M keys, one compromise is enough. With M services each checking the burn on Holochain before signing, M compromises are needed, or M honest parties agreeing on a withdrawal the Unyt network recorded.

So a service must never sign what it is sent. It must sign only what it has checked against its own view of the Unyt network and of the deploy record.

## What a service holds

One signer of `CLAIM_SIGNERS`: a key with no EIP-7702 delegation, or a Safe whose owner keys it holds. A Safe held by one service is still one party. It fills one seat, as a key does.

## What a service receives

`POST <url>/sign`, from the orchestrator, for one withdrawal:

| field | content |
|---|---|
| `withdrawal` | the withdrawal's Holochain transaction ID, as the orchestrator keys it (`tx.id`, an `ActionHash`), base64 as holo_hash writes it |
| `context` | the coupon's nine words, as 32-byte hex, as bridge-orchestrator/src/signer.rs writes them: recipient, amount (the wei with exponent -18, `0xffffffee` then the wei), expiry, order hash, order owner, RaindexV6, HOT, vault ID, nonce |
| `signer` | the signer the orchestrator asks this service to sign as |
| `chainId` | the chain the claim order is on |

It is not sent the digest: it computes the digest from the words it checked. The orchestrator never sends a service its startup probe, which pays no withdrawal.

## What a service checks, on Holochain and against the record, before it signs

Each check is against the service's own sources: its own Holochain node, or one it trusts, and a copy of the deploy record it was given out of band, never the request.

1. **The burn is real.** The transaction ID names a spend on the Unyt network that the service's node holds. It is a parked spend whose counterparty role is `withdrawer`, in the bridging agent's lane for HOT: the one spend the bridge's template pays a withdrawal from. A coupon for a spend in any other role, or for an ID the node does not hold, is refused. This is what the orchestrator checks in `bridge-orchestrator/src/orchestrator.rs` (`bridging_spend`), and what each service must check on its own.
2. **The amount.** The coupon's amount word unpacks to exactly the spend's amount in the HOT unit, `HOT_UNIT_INDEX`, as wei: coefficient the wei, exponent -18. Not more, and not another unit.
3. **The recipient.** Word 0 is the `withdraw_to_address` that the spend's attached payload names, and nothing else.
4. **The expiry.** Word 2 is in the future, and no further than the agreed `EXPIRY_SECONDS` from now, so that a coupon cannot be kept for years.
5. **The nonce.** Word 8 is `keccak256` of the transaction ID's 39 raw bytes. So every coupon for one withdrawal shares a nonce, and the claim order lets one of them claim. A service may sign the same withdrawal more than once, as the orchestrator asks again when fewer than M signed, and re-issues coupons after a rotation. It must refuse a nonce that is not the withdrawal's, as that would let one burn be claimed twice.
6. **The order.** Words 3 to 7 are the deploy record's `ORDER_HASH`, `ORDER_OWNER` (the vault), `ORDERBOOK_ADDRESS` (RaindexV6), `TOKEN_ADDRESS` (HOT) and `VAULT_ID`, `signer` is one of the record's `CLAIM_SIGNERS` and the one this service holds, and `chainId` is the record's chain. A coupon for another order, vault, token, signer or chain is refused.
7. **The digest.** The service computes the EIP-191 hash of the nine words it checked. A key signs that hash. A Safe's owners each sign the SafeMessage hash of it for the Safe on the chain, and their signatures are sorted by owner address and joined. No blind signing of a hash.

A service that finds any check failing refuses, says which, and alerts a person: a refused request means the orchestrator and the service disagree about the network, which is either a bug or an attack.

## Interface

```
GET <url>/signer
200 { "signer": "0x...", "chainId": 1 }      who this service signs as, and on which chain

POST <url>/sign
{
  "withdrawal": "uhCkk...",
  "context": ["0x...", ... nine 32-byte words ...],
  "signer": "0x...", "chainId": 1
}

200 { "signer": "0x...", "signature": "0x..." }   a key's 65 bytes, r s v with v 27 or 28; or a Safe's owner signatures
409 { "refused": "the amount 40 HOT is not the spend's 30 HOT" }
```

`SIGNER_SERVICES` names each service by its signer: `<signer>=<base URL>`, separated by commas. On mainnet the URL must be https, or http to this machine. What the orchestrator does with each service:

- **At startup** it asks `GET /signer`, and refuses to start if the service answers for another signer or chain. A service that does not answer is logged, and startup passes while the signers that can sign are at least M.
- **For each withdrawal** it asks every signer at once, the services among them, and gives each 20 seconds. It refuses an answer for another signer, and a 65-byte signature that does not recover to the signer over the coupon's digest; a Safe's signature only its `isValidSignature` checks, on chain. It takes the first M that sign, in `CLAIM_SIGNERS` order. A refusal's reason, up to 200 characters, goes to its log.
- **With fewer than M signatures** the withdrawal stays parked, and is asked again on the next cycle.

Authentication between the orchestrator and the services, and whether a service holds its key in a keystore, an HSM or a Ledger, are open. A credential in the URL's path is never logged: the orchestrator logs a service's host and port only. The signature is the only thing that crosses; a refusal reason is for people.

## Open questions

- **Who the signers are, and who runs their services.** Each is a service with its own Holochain node and its own key. Holo, Unyt, and Coasys as a possible signer are each a separate conversation.
- **The shape.** 2 of 3 is what the rehearsal proves. The deployed Rainlang takes at most 3 of 15 or 4 of 8 ([enable-multisig.md](./enable-multisig.md#two-limits-of-the-deployed-rainlang)).
- **Launch with services, or with keys first.** Launching with keys the orchestrator holds adds no protection, and moving to services later is a new claim order, through `rotate-claim-signer.sh`, and its coupons' re-issue. Launching with a service's signer listed from the start spares that rotation.
- **Who builds the service.** It reads the Unyt network as the orchestrator does; the orchestrator's `bridging_spend` and `Payout` are the checks, in Rust.
- **What happens while a service is down.** Withdrawals stay parked while fewer than M sign; a cap on how long is policy.
- **A cap per coupon or per day**, checked by each service, as a limit on what M compromised parties could take at once.
