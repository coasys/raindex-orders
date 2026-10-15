//! A Safe as the claim order's coupon signer: its owners sign the SafeMessage
//! hash of each coupon, here with keys this process holds or at their own signer
//! services, and the Safe's EIP-1271 `isValidSignature` checks M of them
//! (docs/signer-service.md).

use super::{SignRequest, Signing, SIGN_TIMEOUT};
use crate::config::Network;
use alloy::primitives::{keccak256, Address, Bytes, PrimitiveSignature, B256, U256};
use alloy::providers::{ProviderBuilder, RootProvider};
use alloy::signers::local::PrivateKeySigner;
use alloy::signers::Signer;
use alloy::sol;
use alloy::sol_types::SolValue;
use alloy::transports::http::{Client, Http};
use anyhow::{anyhow, Context, Result};
use holo_hash::ActionHashB64;
use serde::Deserialize;
use serde_json::json;

sol! {
    /// What a Safe answers about itself, and the EIP-1271 check its
    /// CompatibilityFallbackHandler answers for it.
    #[sol(rpc)]
    interface ISafe {
        function getThreshold() external view returns (uint256);
        function getOwners() external view returns (address[] memory);
        function domainSeparator() external view returns (bytes32);
        function isValidSignature(bytes32 dataHash, bytes calldata signature) external view returns (bytes4);
    }
}

/// EIP-1271's answer for a valid signature.
pub const EIP1271_MAGIC_VALUE: [u8; 4] = [0x16, 0x26, 0xba, 0x7e];

/// A Safe coupon signer has at least 2 owners to ask, its threshold being 2 or
/// more, and the website reads at most 20 owner signatures.
const MIN_OWNERS: usize = 2;
const MAX_OWNERS: usize = 20;

/// A Safe's EIP-712 domain separator, as Safe 1.3.0 and later compute it:
/// `EIP712Domain(uint256 chainId,address verifyingContract)`.
pub fn safe_domain_separator(chain_id: u64, safe: Address) -> B256 {
    keccak256(
        (
            keccak256(b"EIP712Domain(uint256 chainId,address verifyingContract)"),
            U256::from(chain_id),
            safe,
        )
            .abi_encode(),
    )
}

/// The hash a Safe's CompatibilityFallbackHandler has its owners sign for
/// `isValidSignature(digest, signature)` to accept: `getMessageHashForSafe(safe,
/// abi.encode(digest))`, the EIP-712 hash of `SafeMessage(bytes message)` with the
/// digest's 32 bytes as the message, under the Safe's domain.
pub fn safe_message_hash(chain_id: u64, safe: Address, digest: &B256) -> B256 {
    let message = keccak256(
        (
            keccak256(b"SafeMessage(bytes message)"),
            keccak256(digest.abi_encode()),
        )
            .abi_encode(),
    );
    keccak256(
        [
            &[0x19, 0x01][..],
            safe_domain_separator(chain_id, safe).as_slice(),
            message.as_slice(),
        ]
        .concat(),
    )
}

/// One owner of the Safe, signing here with its key or at its signer service.
pub enum Owner {
    Key(PrivateKeySigner),
    Service(OwnerService),
}

impl Owner {
    pub fn address(&self) -> Address {
        match self {
            Owner::Key(key) => Signer::address(key),
            Owner::Service(service) => service.owner,
        }
    }

    /// The owner and where it signs, for logs: here, or the service's host.
    pub fn name(&self) -> String {
        match self {
            Owner::Key(_) => format!("{} (a key held here)", self.address()),
            Owner::Service(service) => {
                format!("{} (signer service at {})", self.address(), service.host())
            }
        }
    }

    async fn sign(&self, request: &OwnerRequest<'_>) -> Result<Vec<u8>> {
        match self {
            Owner::Key(key) => {
                let signature = key.sign_hash(&request.safe_message_hash).await?;
                let mut bytes = Vec::with_capacity(65);
                bytes.extend_from_slice(&signature.r().to_be_bytes::<32>());
                bytes.extend_from_slice(&signature.s().to_be_bytes::<32>());
                bytes.push(if signature.v() { 28 } else { 27 });
                Ok(bytes)
            }
            Owner::Service(service) => service.request_signature(request).await,
        }
    }
}

/// What one owner is asked to sign for one coupon.
pub struct OwnerRequest<'a> {
    pub safe: Address,
    pub chain_id: u64,
    pub sign: &'a SignRequest,
    pub safe_message_hash: B256,
}

/// One owner's signature, checked: it recovers to the owner over the coupon's
/// SafeMessage hash, and the owner is one of the Safe's.
#[derive(Debug, Clone, PartialEq)]
pub struct OwnerSignature {
    pub owner: Address,
    pub signature: [u8; 65],
}

/// The Safe CLAIM_SIGNER and the owners this orchestrator asks to sign for it.
/// Each coupon asks every owner at once, checks each answer, and takes the M
/// lowest owner addresses that signed, M being the Safe's threshold read for that
/// coupon, sorted as the Safe requires. Then it asks the Safe's own
/// `isValidSignature`, so a coupon the Safe would refuse is never handed out.
///
/// Owner keys held here are one party, however many: protection comes from
/// owners at independent signer services, each checking the withdrawal on its
/// own Holochain node before it signs.
pub struct SafeOwners {
    safe: Address,
    chain_id: u64,
    owners: Vec<Owner>,
    rpc_url: String,
    /// UNSAFE_ALLOW_ONE_PARTY_SIGNER=yes: on mainnet, start even when this
    /// process alone can sign as the Safe, or holds owner keys of a Safe that is
    /// also the vault admin.
    one_party_allowed: bool,
}

impl std::fmt::Debug for SafeOwners {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("SafeOwners")
            .field("safe", &self.safe)
            .field("chain_id", &self.chain_id)
            .field("owners", &self.addresses())
            .finish()
    }
}

/// What a Safe answers now: its threshold and owners.
pub struct SafeState {
    pub threshold: usize,
    pub owners: Vec<Address>,
}

impl SafeOwners {
    /// `owners` of `safe` on chain `chain_id`, read and checked through
    /// `rpc_url`. Refuses fewer than 2 owners, more than 20, or one twice.
    pub fn new(safe: Address, chain_id: u64, owners: Vec<Owner>, rpc_url: String) -> Result<Self> {
        let keys = owners.iter().filter(|o| matches!(o, Owner::Key(_))).count();
        if keys == owners.len() {
            anyhow::ensure!(
                (MIN_OWNERS..=MAX_OWNERS).contains(&keys),
                "SAFE_OWNER_KEYS holds {keys} keys: a Safe coupon signer needs the keys of its threshold of owners, 2 to 20, or SAFE_OWNER_SERVICES"
            );
        } else {
            anyhow::ensure!(
                (MIN_OWNERS..=MAX_OWNERS).contains(&owners.len()),
                "SAFE_OWNER_KEYS and SAFE_OWNER_SERVICES name {} owners: a Safe coupon signer asks at least its threshold of owners, 2 to 20",
                owners.len()
            );
        }
        for (i, owner) in owners.iter().enumerate() {
            let address = owner.address();
            if let Some(first) = owners[..i].iter().find(|o| o.address() == address) {
                anyhow::bail!(match (first, owner) {
                    (Owner::Key(_), Owner::Key(_)) => format!("SAFE_OWNER_KEYS holds the key of {address} twice"),
                    (Owner::Service(_), Owner::Service(_)) =>
                        format!("SAFE_OWNER_SERVICES names {address} twice"),
                    _ => format!(
                        "{address} is in both SAFE_OWNER_KEYS and SAFE_OWNER_SERVICES: each owner signs in one place"
                    ),
                });
            }
        }
        Ok(Self {
            safe,
            chain_id,
            owners,
            rpc_url,
            one_party_allowed: false,
        })
    }

    /// These owners, with UNSAFE_ALLOW_ONE_PARTY_SIGNER=yes when `allowed`.
    pub fn allowing_one_party(self, allowed: bool) -> Self {
        Self {
            one_party_allowed: allowed,
            ..self
        }
    }

    /// Whether UNSAFE_ALLOW_ONE_PARTY_SIGNER=yes is set.
    pub fn one_party_allowed(&self) -> bool {
        self.one_party_allowed
    }

    pub fn safe(&self) -> Address {
        self.safe
    }

    pub fn owners(&self) -> &[Owner] {
        &self.owners
    }

    pub fn addresses(&self) -> Vec<Address> {
        self.owners.iter().map(Owner::address).collect()
    }

    /// The owners whose keys this process holds.
    pub fn local_keys(&self) -> usize {
        self.owners
            .iter()
            .filter(|o| matches!(o, Owner::Key(_)))
            .count()
    }

    /// The hash the owners sign for `digest`: its SafeMessage hash.
    pub fn message_hash(&self, digest: &B256) -> B256 {
        safe_message_hash(self.chain_id, self.safe, digest)
    }

    fn provider(&self) -> Result<RootProvider<Http<Client>>> {
        let url = self
            .rpc_url
            .parse()
            .map_err(|_| anyhow!("the RPC URL for CLAIM_SIGNER {} is not a URL", self.safe))?;
        Ok(ProviderBuilder::new().on_http(url))
    }

    /// The Safe's threshold and owners, as it answers them now.
    pub async fn state(&self) -> Result<SafeState> {
        let provider = self.provider()?;
        let contract = ISafe::new(self.safe, &provider);
        let failed = |what: &str| format!("CLAIM_SIGNER {}: {what} failed", self.safe);
        let threshold = contract
            .getThreshold()
            .call()
            .await
            .map_err(|_| anyhow!(failed("getThreshold()")))?
            ._0;
        let owners = contract
            .getOwners()
            .call()
            .await
            .map_err(|_| anyhow!(failed("getOwners()")))?
            ._0;
        Ok(SafeState {
            threshold: usize::try_from(threshold).unwrap_or(usize::MAX),
            owners,
        })
    }

    /// Whether the Safe's `isValidSignature(digest, signature)` answers the
    /// EIP-1271 magic value: what Raindex V6 asks it for a coupon.
    pub async fn accepts(&self, digest: &B256, signature: &[u8]) -> Result<bool> {
        let provider = self.provider()?;
        let answer = ISafe::new(self.safe, &provider)
            .isValidSignature(*digest, Bytes::copy_from_slice(signature))
            .call()
            .await;
        match answer {
            Ok(answer) => Ok(answer._0.0 == EIP1271_MAGIC_VALUE),
            Err(alloy::contract::Error::TransportError(
                alloy::transports::RpcError::ErrorResp(_),
            )) => Ok(false),
            Err(_) => Err(anyhow!(
                "CLAIM_SIGNER {}: isValidSignature(...) could not be asked",
                self.safe
            )),
        }
    }

    /// Asks every owner at once to sign `request`'s SafeMessage hash, each within
    /// SIGN_TIMEOUT, and checks each answer against the Safe's owners now. Returns
    /// the Safe's state and, for each owner, its checked signature or why not.
    pub async fn collect(
        &self,
        request: &SignRequest,
    ) -> Result<(SafeState, Vec<(Address, Result<OwnerSignature>)>)> {
        let state = self.state().await?;
        let owner_request = OwnerRequest {
            safe: self.safe,
            chain_id: self.chain_id,
            sign: request,
            safe_message_hash: self.message_hash(&request.digest),
        };
        let owner_request = &owner_request;
        let state_ref = &state;
        let answers = futures::future::join_all(self.owners.iter().map(|owner| async move {
            let address = owner.address();
            let answer = match tokio::time::timeout(SIGN_TIMEOUT, owner.sign(owner_request)).await {
                Ok(Ok(signature)) => checked(
                    self.safe,
                    address,
                    &signature,
                    &owner_request.safe_message_hash,
                    &state_ref.owners,
                )
                .with_context(|| owner.name()),
                Ok(Err(err)) => Err(err.context(owner.name())),
                Err(_) => Err(anyhow!(
                    "{} did not sign within {SIGN_TIMEOUT:?}",
                    owner.name()
                )),
            };
            (address, answer)
        }))
        .await;
        Ok((state, answers))
    }

    /// The Safe's signature of `request`: M owner signatures, the M lowest owner
    /// addresses of those that signed, ascending, which the Safe has accepted.
    /// Fewer than M is an error naming why each other owner did not sign.
    pub async fn sign_request(&self, request: &SignRequest) -> Result<Vec<u8>> {
        let (state, answers) = self.collect(request).await?;
        let threshold = state.threshold;
        let mut signed = Vec::new();
        let mut failures = Vec::new();
        for (_, answer) in answers {
            match answer {
                Ok(signature) => signed.push(signature),
                Err(err) => failures.push(format!("{err:#}")),
            }
        }
        anyhow::ensure!(
            threshold >= 1 && signed.len() >= threshold,
            "{} of the {} owners asked signed, and CLAIM_SIGNER {} needs {threshold}: {}",
            signed.len(),
            self.owners.len(),
            self.safe,
            failures.join("; ")
        );
        for failure in &failures {
            tracing::warn!(
                event = "coupon.owner_did_not_sign",
                safe = %self.safe,
                "an owner of CLAIM_SIGNER did not sign a coupon, which {threshold} others signed: {failure}"
            );
        }
        let signature = joined(signed, threshold);
        anyhow::ensure!(
            self.accepts(&request.digest, &signature).await?,
            "CLAIM_SIGNER {} refused the signatures of {threshold} of its owners: its isValidSignature did not accept them",
            self.safe
        );
        Ok(signature)
    }
}

/// The `threshold` lowest owners of `signed`, ascending, their signatures joined
/// as the Safe reads them.
pub fn joined(mut signed: Vec<OwnerSignature>, threshold: usize) -> Vec<u8> {
    signed.sort_by_key(|s| s.owner);
    signed.dedup_by_key(|s| s.owner);
    signed
        .iter()
        .take(threshold)
        .flat_map(|s| s.signature)
        .collect()
}

/// `signature` as an owner's signature the Safe reads: 65 bytes r, s, v, by
/// `owner`, over `hash` (v 27 or 28; 0 or 1 is taken as those) or over its
/// EIP-191 message hash (v 31 or 32, Safe's eth_sign form), and `owner` one of
/// `owners`.
fn checked(
    safe: Address,
    owner: Address,
    signature: &[u8],
    hash: &B256,
    owners: &[Address],
) -> Result<OwnerSignature> {
    let mut bytes: [u8; 65] = signature.try_into().map_err(|_| {
        anyhow!(
            "answered {} bytes, not a 65-byte signature",
            signature.len()
        )
    })?;
    if bytes[64] < 2 {
        bytes[64] += 27;
    }
    let (v, signed) = match bytes[64] {
        27 | 28 => (bytes[64], *hash),
        31 | 32 => (
            bytes[64] - 4,
            keccak256(
                [
                    b"\x19Ethereum Signed Message:\n32".as_slice(),
                    hash.as_slice(),
                ]
                .concat(),
            ),
        ),
        other => anyhow::bail!("answered a signature whose v is {other}, not 27 or 28"),
    };
    let mut plain = bytes;
    plain[64] = v;
    let recovered = PrimitiveSignature::try_from(plain.as_slice())
        .ok()
        .and_then(|s| s.recover_address_from_prehash(&signed).ok());
    anyhow::ensure!(
        recovered == Some(owner),
        "answered a signature that is not {owner}'s over the coupon's SafeMessage hash {hash}"
    );
    anyhow::ensure!(
        owners.contains(&owner),
        "{owner} is not an owner of CLAIM_SIGNER {safe} now"
    );
    Ok(OwnerSignature {
        owner,
        signature: bytes,
    })
}

/// One owner of the Safe, signing at an independent party's signer service,
/// which holds the owner's key and checks each withdrawal on its own Holochain
/// node before it signs (docs/signer-service.md). The service is sent the
/// coupon's words and the withdrawal, and answers the owner's signature of the
/// coupon's SafeMessage hash.
pub struct OwnerService {
    owner: Address,
    url: String,
    client: reqwest::Client,
}

/// A signer service's answer to `POST /sign`.
#[derive(Deserialize)]
struct Signed {
    owner: Address,
    signature: Bytes,
}

/// A signer service's answer to `GET /signer`.
#[derive(Debug, Deserialize)]
pub struct Identity {
    pub owner: Address,
    pub safe: Address,
    #[serde(rename = "chainId")]
    pub chain_id: u64,
}

/// A signer service's refusal, `409 { "code": "...", "reason": "..." }`.
#[derive(Deserialize)]
struct Refused {
    code: String,
    #[serde(default)]
    reason: String,
}

impl OwnerService {
    pub fn new(network: Network, owner: Address, url: &str) -> Result<Self> {
        let parsed = reqwest::Url::parse(url)
            .ok()
            .filter(|url| matches!(url.scheme(), "http" | "https") && url.host_str().is_some())
            .with_context(|| {
                format!(
                    "SAFE_OWNER_SERVICES names a URL for {owner} that is not an http or https URL"
                )
            })?;
        anyhow::ensure!(
            parsed.query().is_none() && parsed.fragment().is_none(),
            "SAFE_OWNER_SERVICES names a URL with a query or fragment for {owner}: name the service's base URL"
        );
        let client = reqwest::Client::builder()
            .timeout(SIGN_TIMEOUT)
            .build()
            .context("the HTTP client for SAFE_OWNER_SERVICES")?;
        let service = Self {
            owner,
            url: url.trim_end_matches('/').to_string(),
            client,
        };
        anyhow::ensure!(
            network != Network::Mainnet || !service.is_plain_http_off_host(),
            "SAFE_OWNER_SERVICES names a plain http URL at {} for {owner}: mainnet takes https, or http on this machine",
            service.host()
        );
        Ok(service)
    }

    /// Where the service is, for logs: its host and port, never its path, which
    /// may carry a credential.
    pub fn host(&self) -> String {
        reqwest::Url::parse(&self.url)
            .ok()
            .and_then(|url| {
                url.host_str().map(|host| match url.port() {
                    Some(port) => format!("{host}:{port}"),
                    None => host.to_string(),
                })
            })
            .unwrap_or_default()
    }

    /// Whether the URL is plain http to another machine: a signature crosses it,
    /// so mainnet takes https or this machine only.
    fn is_plain_http_off_host(&self) -> bool {
        reqwest::Url::parse(&self.url).is_ok_and(|url| {
            url.scheme() == "http"
                && !matches!(url.host_str(), Some("127.0.0.1" | "localhost" | "[::1]"))
        })
    }

    fn unreachable(&self, err: &reqwest::Error) -> anyhow::Error {
        if err.is_timeout() {
            anyhow!("did not answer within {SIGN_TIMEOUT:?}")
        } else {
            anyhow!("could not be reached")
        }
    }

    /// `GET /signer`: the owner, Safe and chain the service signs for.
    pub async fn identity(&self) -> Result<Identity> {
        let answer = self
            .client
            .get(format!("{}/signer", self.url))
            .send()
            .await
            .map_err(|err| self.unreachable(&err))?;
        let status = answer.status();
        anyhow::ensure!(
            status.is_success(),
            "answered GET /signer with HTTP {}",
            status.as_u16()
        );
        answer.json().await.map_err(|_| {
            anyhow!("answered GET /signer with something other than {{\"owner\", \"safe\", \"chainId\"}}")
        })
    }

    async fn request_signature(&self, request: &OwnerRequest<'_>) -> Result<Vec<u8>> {
        let body = json!({
            "safe": request.safe,
            "chainId": request.chain_id,
            "owner": self.owner,
            "withdrawal": request
                .sign
                .withdrawal
                .as_ref()
                .map(|w| ActionHashB64::from(w.clone()).to_string()),
            "context": request.sign.context.iter().map(|word| word.to_string()).collect::<Vec<_>>(),
            "couponDigest": request.sign.digest,
            "safeMessageHash": request.safe_message_hash,
        });
        let answer = self
            .client
            .post(format!("{}/sign", self.url))
            .json(&body)
            .send()
            .await
            .map_err(|err| self.unreachable(&err))?;
        let status = answer.status();
        if status == reqwest::StatusCode::CONFLICT {
            let refused = answer
                .json::<Refused>()
                .await
                .map(|r| {
                    let reason: String = r.reason.chars().take(200).collect();
                    let code: String = r.code.chars().take(40).collect();
                    if reason.is_empty() {
                        code
                    } else {
                        format!("{code}: {reason}")
                    }
                })
                .unwrap_or_else(|_| "no reason given".to_string());
            anyhow::bail!("refused: {refused}");
        }
        anyhow::ensure!(status.is_success(), "answered HTTP {}", status.as_u16());
        let signed: Signed = answer.json().await.map_err(|_| {
            anyhow!("answered with something other than {{\"owner\", \"signature\"}}")
        })?;
        anyhow::ensure!(signed.owner == self.owner, "answered for {}", signed.owner);
        Ok(signed.signature.to_vec())
    }
}

impl super::CouponKey for SafeOwners {
    fn address(&self) -> Address {
        self.safe
    }

    fn sign<'a>(&'a self, request: &'a SignRequest) -> Signing<'a> {
        Box::pin(self.sign_request(request))
    }

    fn safe(&self) -> Option<&SafeOwners> {
        Some(self)
    }
}

#[cfg(test)]
pub(crate) mod tests;
