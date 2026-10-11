# The coupon signer service

**Not built.** This is the interface a Safe owner's signer service would have, and the open questions, so that the coupon signer Safe can become M-of-N. Today the orchestrator signs as the Safe with every owner key it holds (`SAFE_OWNER_KEYS`), which is one party.

## Why each owner must check for itself

A coupon pays HOT out of the vault to the address it names, for the amount it names, once. Whoever signs coupons can pay out the vault's HOT, up to what claims take. With one key, or with one process holding every owner key, one compromise is enough. With M owners each checking the burn on Holochain before signing, M compromises are needed, or M honest owners agreeing on a withdrawal the Unyt network recorded.

So an owner must never sign what it is sent. It must sign only what it has checked against its own view of the Unyt network and of the deploy record.

## What an owner receives

A signing request, from the orchestrator, for one withdrawal:

| field | content |
|---|---|
| `withdrawal` | the withdrawal's Holochain transaction ID, as the orchestrator keys it (`tx.id`, an `ActionHash`, 39 bytes raw) |
| `context` | the coupon's nine words, as bridge-orchestrator/src/signer.rs writes them: recipient, amount (the wei with exponent -18, `0xffffffee` then the wei), expiry, order hash, order owner, RaindexV6, HOT, vault ID, nonce |
| `digest` | the EIP-191 hash of the packed words, which Raindex checks |
| `safe` | the signer Safe, and the chain ID, so the owner computes the SafeMessage hash itself |

The orchestrator may also send what it read: the withdrawal's recipient and amount. The owner uses that for logging only, never as evidence.

## What an owner checks, on Holochain and against the record, before it signs

Each check is against the owner's own sources: its own Holochain node, or one it trusts, and a copy of the deploy record it was given out of band, never the request.

1. **The burn is real.** The transaction ID names a spend on the Unyt network that the owner's node holds. It is a parked spend whose counterparty role is `withdrawer`, in the bridging agent's lane for HOT: the one spend the bridge's template pays a withdrawal from. A coupon for a spend in any other role, or for an ID the node does not hold, is refused. This is what the orchestrator checks today in `bridge-orchestrator/src/orchestrator.rs` (`bridging_spend`), and what each owner must check on its own.
2. **The amount.** The coupon's amount word unpacks to exactly the spend's amount in the HOT unit, `HOT_UNIT_INDEX`, as wei: coefficient the wei, exponent -18. Not more, and not another unit.
3. **The recipient.** Word 0 is the `withdraw_to_address` the spend's attached payload names, and nothing else.
4. **The expiry.** Word 2 is in the future, and no further than the agreed `EXPIRY_SECONDS` from now, so that a coupon cannot be kept for years.
5. **The nonce.** Word 8 is `keccak256` of the transaction ID's 39 raw bytes. So every coupon for one withdrawal shares a nonce, and the claim order lets one of them claim. An owner may sign the same withdrawal more than once, as the orchestrator re-issues coupons after a rotation; it must refuse a nonce that is not the withdrawal's, as that would let one burn be claimed twice.
6. **The order.** Words 3 to 7 are the deploy record's `ORDER_HASH`, `ORDER_OWNER` (the vault), `ORDERBOOK_ADDRESS` (RaindexV6), `TOKEN_ADDRESS` (HOT) and `VAULT_ID`, and the Safe is the record's `CLAIM_SIGNER`. A coupon for another order, vault or token is refused.
7. **The digest.** The owner recomputes the EIP-191 hash of the nine words it checked, ignores the digest it was sent, computes the SafeMessage hash of its own digest for the Safe on the chain, and signs that hash and nothing else. No blind signing of a hash.

Then it answers with its owner address and its 65-byte signature. The orchestrator collects the threshold of answers, sorts them by owner address, joins them, and names the Safe as the coupon's signer, as `SafeOwners` in bridge-orchestrator/src/signer.rs does with the keys it holds.

An owner that finds any check failing refuses, says which, and alerts a person: a refused request means the orchestrator and the owner disagree about the network, which is either a bug or an attack.

## Interface

```
POST /sign
{
  "withdrawal": "uhCkk...",                   the transaction ID, base64 as holo_hash writes it
  "context": ["0x...", ... nine 32-byte words ...],
  "safe": "0x...", "chainId": 1
}

200 { "owner": "0x...", "signature": "0x..." }   65 bytes, v 27 or 28 over the SafeMessage hash
409 { "refused": "the amount 40 HOT is not the spend's 30 HOT" }
```

Transport, authentication between the orchestrator and the services, and whether a service holds its key in a keystore, an HSM or a Ledger are open. The signature is the only thing that crosses; a refusal reason is for people.

## Open questions

- **Who the owners are, and who runs their services.** Each owner is a service with its own Holochain node and its own key. Holo, Unyt, and Coasys as a possible owner are each a separate conversation.
- **The threshold.** 2 of 3 is what the rehearsal proves. The Safe's threshold is also the number of signatures each coupon carries, which the website reads up to 20 of.
- **Launch with a Safe, or a key first.** The deploy takes either as `VALID_SIGNER`. Launching with a Safe whose owner keys the orchestrator holds adds no protection yet, but spares a rotation, and its coupons' re-issue, once the services exist. Launching with a key and rotating later is what `rotate-claim-signer.sh` is for.
- **Who builds the service.** It reads the Unyt network as the orchestrator does; the orchestrator's `bridging_spend` and `Payout` are the checks, in Rust.
- **What the orchestrator does while an owner is down.** Withdrawals stay parked, as they do today when it cannot sign; a cap on how long is policy.
- **A cap per coupon or per day**, checked by each owner, as a limit on what M compromised parties could take at once.
