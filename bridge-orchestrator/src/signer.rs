use crate::config::{log_testnet_defaults, with_network_defaults, Network};
use alloy::primitives::{address, keccak256, Address, Bytes, PrimitiveSignature, B256, U256};
use alloy::signers::local::PrivateKeySigner;
use alloy::signers::Signer;
use alloy::sol_types::SolValue;
use anyhow::{Context, Result};
use holo_hash::{ActionHash, ActionHashB64};
use serde::Deserialize;
use serde_json::json;
use std::env;
use std::future::Future;
use std::num::NonZeroU64;
use std::pin::Pin;
use std::str::FromStr;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

/// The coupon signer whose private key is committed in `src/Constants.sol`.
pub const TEST_SIGNER: Address = address!("8E72b7568738da52ca3DCd9b24E178127A4E7d37");

const CLAIM_ORDER_VARIABLES: [&str; 11] = [
    "ORDER_HASH",
    "ORDER_OWNER",
    "ORDERBOOK_ADDRESS",
    "TOKEN_ADDRESS",
    "VAULT_ID",
    "CLAIM_SIGNERS",
    "CLAIM_THRESHOLD",
    "CLAIM_INTERPRETER",
    "CLAIM_STORE",
    "CLAIM_BYTECODE",
    "CLAIM_INPUT_TOKEN",
];

const MAX_EXPIRY_SECONDS: u64 = 365 * 24 * 60 * 60;

/// HOT's decimals on Ethereum, which the coupon's amount float carries as its
/// exponent.
const HOT_DECIMALS: u32 = 18;

/// The most signers a claim order lists: compose-rainlang.mjs writes one input of
/// a Rainlang word per signer, and a word takes at most 15.
const MAX_CLAIM_SIGNERS: usize = 15;

/// How long a signer has to answer one coupon. One that has not answered is
/// left out of it, as one that refused is.
pub const SIGN_TIMEOUT: Duration = Duration::from_secs(20);

pub(crate) fn env_variables() -> impl Iterator<Item = &'static str> {
    CLAIM_ORDER_VARIABLES.into_iter().chain([
        "SIGNER_PRIVATE_KEY",
        "SAFE_OWNER_KEYS",
        "SAFE_SIGNER",
        "SIGNER_SERVICES",
        "EXPIRY_SECONDS",
    ])
}

/// A Safe coupon signer's threshold is at least 2, so that one key alone
/// signs nothing, and the website reads at most 20 owner signatures.
const MIN_SAFE_OWNER_KEYS: usize = 2;
const MAX_SAFE_OWNER_KEYS: usize = 20;

const DEFAULT_EXPIRY_SECONDS: NonZeroU64 = match NonZeroU64::new(604_800) {
    Some(seconds) => seconds,
    None => unreachable!(),
};

/// The claim order coupons are signed for, as the deploy record prints it.
#[derive(Debug, Clone, PartialEq)]
pub struct ClaimOrder {
    pub order_hash: B256,
    pub order_owner: Address,
    pub orderbook: Address,
    pub token: Address,
    pub vault_id: B256,
    /// The N signers the order's expression lists, in the deploy record's order.
    pub signers: Vec<Address>,
    /// M: how many of `signers` must sign each coupon.
    pub threshold: usize,
    pub interpreter: Address,
    pub store: Address,
    /// The order's expression, parsed: Raindex V6 orders carry their bytecode.
    pub bytecode: Bytes,
    pub input_token: Address,
}

/// One signer's part of a coupon: a signed context of the claim, whose signer the
/// order reads as `signer<i>()` for seat i.
#[derive(Debug, Clone, PartialEq)]
pub struct Seat {
    pub signer: Address,
    pub signature: Vec<u8>,
}

/// A coupon: the nine context words, and the seats of the signers who signed
/// them, each over the same digest.
#[derive(Debug, Clone)]
pub struct SignedCoupon {
    pub seats: Vec<Seat>,
    pub context: Vec<B256>,
}

/// What a signer is asked to sign: the coupon's nine words and their digest,
/// and the withdrawal it pays, which a signer service checks on Holochain
/// before it signs. The startup probe pays no withdrawal.
#[derive(Debug, Clone)]
pub struct SignRequest {
    pub digest: B256,
    pub context: Vec<B256>,
    pub withdrawal: Option<ActionHash>,
}

pub type Signing<'a> = Pin<Box<dyn Future<Output = Result<Vec<u8>>> + Send + 'a>>;

/// Where a signer signs.
pub enum SignerKind<'a> {
    /// Here, with a key this process holds.
    Key,
    /// Here, as a Safe, with the keys of `owners`, which this process holds.
    SafeOwners { owners: Vec<Address> },
    /// At an independent party's signer service, which checks the withdrawal
    /// itself before it signs (docs/signer-service.md).
    Service(&'a SignerService),
}

/// One of the claim order's signers. Raindex checks a seat's signature of the
/// coupon's digest with OpenZeppelin's `SignatureChecker`: a key's 65-byte
/// signature, or what a contract's EIP-1271 `isValidSignature` accepts.
pub trait CouponKey: Send + Sync {
    fn address(&self) -> Address;
    fn sign<'a>(&'a self, request: &'a SignRequest) -> Signing<'a>;
    fn kind(&self) -> SignerKind<'_> {
        SignerKind::Key
    }
}

/// A key's 65-byte signature of `hash`: r, s, then v as 27 or 28.
async fn sign_hash(key: &PrivateKeySigner, hash: &B256) -> Result<Vec<u8>> {
    let signature = key.sign_hash(hash).await?;
    let mut bytes = Vec::with_capacity(65);
    bytes.extend_from_slice(&signature.r().to_be_bytes::<32>());
    bytes.extend_from_slice(&signature.s().to_be_bytes::<32>());
    bytes.push(if signature.v() { 28 } else { 27 });
    Ok(bytes)
}

impl CouponKey for PrivateKeySigner {
    fn address(&self) -> Address {
        Signer::address(self)
    }

    fn sign<'a>(&'a self, request: &'a SignRequest) -> Signing<'a> {
        Box::pin(sign_hash(self, &request.digest))
    }
}

/// The keys of `threshold` owners of a Safe, signing coupons for it. Raindex
/// V6 asks the Safe's EIP-1271 `isValidSignature(digest, signature)`, which
/// its CompatibilityFallbackHandler answers by checking each owner's signature
/// of the SafeMessage of the digest: the EIP-712 hash, under the Safe's domain
/// on this chain, of `SafeMessage(bytes message)` with the digest as the
/// message. The signature is each owner's 65-byte signature of that hash, in
/// ascending owner order, as the Safe requires.
///
/// This holds every key in one process: it is one party signing as the Safe,
/// however many owners it holds, and fills one seat of the claim order's M.
#[derive(Debug)]
pub struct SafeOwners {
    safe: Address,
    chain_id: u64,
    keys: Vec<PrivateKeySigner>,
}

impl SafeOwners {
    /// `keys`, sorted by address, for `safe` on chain `chain_id`. Refuses fewer
    /// than 2 keys, more than 20, or one key twice.
    pub fn new(safe: Address, chain_id: u64, mut keys: Vec<PrivateKeySigner>) -> Result<Self> {
        anyhow::ensure!(
            (MIN_SAFE_OWNER_KEYS..=MAX_SAFE_OWNER_KEYS).contains(&keys.len()),
            "SAFE_OWNER_KEYS holds {} keys: a Safe coupon signer needs the keys of its threshold of owners, 2 to 20",
            keys.len()
        );
        keys.sort_by_key(Signer::address);
        if let Some(pair) = keys
            .windows(2)
            .find(|pair| Signer::address(&pair[0]) == Signer::address(&pair[1]))
        {
            anyhow::bail!(
                "SAFE_OWNER_KEYS holds the key of {} twice",
                Signer::address(&pair[0])
            );
        }
        Ok(Self {
            safe,
            chain_id,
            keys,
        })
    }

    /// The hash the owners sign: the SafeMessage of `digest`.
    pub fn message_hash(&self, digest: &B256) -> B256 {
        safe_message_hash(self.chain_id, self.safe, digest)
    }
}

impl CouponKey for SafeOwners {
    fn address(&self) -> Address {
        self.safe
    }

    fn sign<'a>(&'a self, request: &'a SignRequest) -> Signing<'a> {
        Box::pin(async move {
            let hash = self.message_hash(&request.digest);
            let mut bytes = Vec::with_capacity(65 * self.keys.len());
            for key in &self.keys {
                bytes.extend_from_slice(&sign_hash(key, &hash).await?);
            }
            Ok(bytes)
        })
    }

    fn kind(&self) -> SignerKind<'_> {
        SignerKind::SafeOwners {
            owners: self.keys.iter().map(Signer::address).collect(),
        }
    }
}

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
/// abi.encode(digest))`.
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

/// One of the claim order's signers, signing at an independent party's signer
/// service, which holds its key, or its Safe's owner keys, and checks each
/// withdrawal on Holochain before it signs (docs/signer-service.md). The
/// orchestrator sends the withdrawal and the coupon's words, and takes back the
/// signer's signature. It never sends the startup probe, which pays no
/// withdrawal.
pub struct SignerService {
    signer: Address,
    chain_id: u64,
    /// The service's base URL, `/sign` and `/signer` under it.
    url: String,
    client: reqwest::Client,
}

/// A signer service's answer to `POST /sign`.
#[derive(Deserialize)]
struct Signed {
    signer: Address,
    signature: Bytes,
}

/// A signer service's answer to `GET /signer`.
#[derive(Deserialize)]
struct Identity {
    signer: Address,
    #[serde(rename = "chainId")]
    chain_id: u64,
}

/// A signer service's refusal, `409 { "refused": "..." }`, which is for people.
#[derive(Deserialize)]
struct Refused {
    refused: String,
}

impl SignerService {
    pub fn new(signer: Address, chain_id: u64, url: &str) -> Result<Self> {
        let parsed = reqwest::Url::parse(url)
            .ok()
            .filter(|url| matches!(url.scheme(), "http" | "https") && url.host_str().is_some())
            .with_context(|| {
                format!(
                    "SIGNER_SERVICES names {url:?} for {signer}, which is not an http or https URL"
                )
            })?;
        anyhow::ensure!(
            parsed.query().is_none() && parsed.fragment().is_none(),
            "SIGNER_SERVICES names a URL with a query or fragment for {signer}: name the service's base URL"
        );
        let client = reqwest::Client::builder()
            .timeout(SIGN_TIMEOUT)
            .build()
            .context("the HTTP client for SIGNER_SERVICES")?;
        Ok(Self {
            signer,
            chain_id,
            url: url.trim_end_matches('/').to_string(),
            client,
        })
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
    /// and a refusal reason, so mainnet takes https or this machine only.
    fn is_plain_http_off_host(&self) -> bool {
        reqwest::Url::parse(&self.url).is_ok_and(|url| {
            url.scheme() == "http"
                && !matches!(url.host_str(), Some("127.0.0.1" | "localhost" | "[::1]"))
        })
    }

    /// `GET /signer`, which must answer for this signer on this chain.
    #[cfg(test)]
    pub async fn identity_check(&self) -> Result<()> {
        let (signer, chain_id) = self.identity().await?;
        self.require_identity(signer, chain_id)
    }

    /// Refuses a service that answers for another signer or chain than
    /// SIGNER_SERVICES names it for: a mistake in the configuration.
    pub fn require_identity(&self, signer: Address, chain_id: u64) -> Result<()> {
        anyhow::ensure!(
            signer == self.signer && chain_id == self.chain_id,
            "the signer service at {} signs for {signer} on chain {chain_id}, and SIGNER_SERVICES names it for {} on chain {}",
            self.host(),
            self.signer,
            self.chain_id
        );
        Ok(())
    }

    /// The signer and chain the service answers `GET /signer` with.
    pub async fn identity(&self) -> Result<(Address, u64)> {
        let answer = self
            .client
            .get(format!("{}/signer", self.url))
            .send()
            .await
            .map_err(|err| self.unreachable(&err))?;
        let status = answer.status();
        anyhow::ensure!(
            status.is_success(),
            "the signer service for {} at {} answered GET /signer with HTTP {}",
            self.signer,
            self.host(),
            status.as_u16()
        );
        let identity: Identity = answer.json().await.map_err(|_| {
            anyhow::anyhow!(
                "the signer service for {} at {} answered GET /signer with something other than {{\"signer\", \"chainId\"}}",
                self.signer,
                self.host()
            )
        })?;
        Ok((identity.signer, identity.chain_id))
    }

    fn unreachable(&self, err: &reqwest::Error) -> anyhow::Error {
        let what = if err.is_timeout() {
            format!("did not answer within {SIGN_TIMEOUT:?}")
        } else {
            "could not be reached".to_string()
        };
        anyhow::anyhow!(
            "the signer service for {} at {} {what}",
            self.signer,
            self.host()
        )
    }

    async fn request_signature(&self, request: &SignRequest) -> Result<Vec<u8>> {
        let Some(withdrawal) = &request.withdrawal else {
            anyhow::bail!(
                "the signer service for {} signs coupons for withdrawals, and this pays none",
                self.signer
            );
        };
        let body = json!({
            "withdrawal": ActionHashB64::from(withdrawal.clone()).to_string(),
            "context": request.context.iter().map(|word| word.to_string()).collect::<Vec<_>>(),
            "signer": self.signer,
            "chainId": self.chain_id,
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
            let reason = answer
                .json::<Refused>()
                .await
                .map(|refused| refused.refused.chars().take(200).collect::<String>())
                .unwrap_or_else(|_| "no reason given".to_string());
            anyhow::bail!(
                "the signer service for {} at {} refused: {reason}",
                self.signer,
                self.host()
            );
        }
        anyhow::ensure!(
            status.is_success(),
            "the signer service for {} at {} answered HTTP {}",
            self.signer,
            self.host(),
            status.as_u16()
        );
        let signed: Signed = answer.json().await.map_err(|_| {
            anyhow::anyhow!(
                "the signer service for {} at {} answered with something other than {{\"signer\", \"signature\"}}",
                self.signer,
                self.host()
            )
        })?;
        anyhow::ensure!(
            signed.signer == self.signer,
            "the signer service for {} at {} answered for {}",
            self.signer,
            self.host(),
            signed.signer
        );
        // A key's signature is checked here, as Raindex will check it. A Safe's
        // is its owners', which only its isValidSignature on chain checks.
        if signed.signature.len() == 65 {
            let recovered = PrimitiveSignature::try_from(signed.signature.as_ref())
                .ok()
                .and_then(|signature| signature.recover_address_from_prehash(&request.digest).ok());
            anyhow::ensure!(
                recovered == Some(self.signer),
                "the signer service for {} at {} answered a signature that is not {}'s over the coupon",
                self.signer,
                self.host(),
                self.signer
            );
        }
        anyhow::ensure!(
            !signed.signature.is_empty(),
            "the signer service for {} at {} answered an empty signature",
            self.signer,
            self.host()
        );
        Ok(signed.signature.to_vec())
    }
}

impl CouponKey for SignerService {
    fn address(&self) -> Address {
        self.signer
    }

    fn sign<'a>(&'a self, request: &'a SignRequest) -> Signing<'a> {
        Box::pin(self.request_signature(request))
    }

    fn kind(&self) -> SignerKind<'_> {
        SignerKind::Service(self)
    }
}

/// Signs coupons for the claim order: each coupon carries the seats of M of its N
/// signers. The signers this orchestrator signs for are `signers`, in the deploy
/// record's order: keys and Safes whose keys it holds, and signer services.
pub struct CouponSigner {
    signers: Vec<Box<dyn CouponKey>>,
    order: ClaimOrder,
    expiry_seconds: NonZeroU64,
}

impl CouponSigner {
    pub fn from_env(network: Network) -> Result<Self> {
        Self::from_settings(network, |key| env::var(key).ok())
    }

    fn from_settings(network: Network, setting: impl Fn(&str) -> Option<String>) -> Result<Self> {
        log_testnet_defaults(network, &setting, &CLAIM_ORDER_VARIABLES);
        let setting = with_network_defaults(network, setting);
        let mut faults = Vec::new();
        let order_hash = parsed(&setting, "ORDER_HASH", "a 32-byte hash", &mut faults);
        let order_owner = parsed(&setting, "ORDER_OWNER", "an address", &mut faults);
        let orderbook = parsed(&setting, "ORDERBOOK_ADDRESS", "an address", &mut faults);
        let token = parsed(&setting, "TOKEN_ADDRESS", "an address", &mut faults);
        let vault_id = parsed(&setting, "VAULT_ID", "a 32-byte vault ID", &mut faults);
        let listed = claim_signers(network, &setting, &mut faults);
        let interpreter = parsed(&setting, "CLAIM_INTERPRETER", "an address", &mut faults);
        let store = parsed(&setting, "CLAIM_STORE", "an address", &mut faults);
        let bytecode = parsed(&setting, "CLAIM_BYTECODE", "hex bytecode", &mut faults);
        let input_token = parsed(&setting, "CLAIM_INPUT_TOKEN", "an address", &mut faults);
        let expiry_seconds = match setting("EXPIRY_SECONDS") {
            None => Some(DEFAULT_EXPIRY_SECONDS),
            Some(raw) => match raw.parse::<NonZeroU64>() {
                Ok(seconds) if seconds.get() <= MAX_EXPIRY_SECONDS => Some(seconds),
                _ => {
                    faults.push(format!(
                        "EXPIRY_SECONDS={raw} is not a number of seconds from 1 to {MAX_EXPIRY_SECONDS}"
                    ));
                    None
                }
            },
        };
        let signers = signers_from(network, &setting, listed.as_ref(), &mut faults);

        let order = match (
            order_hash,
            order_owner,
            orderbook,
            token,
            vault_id,
            listed,
            interpreter,
            store,
            bytecode,
            input_token,
        ) {
            (
                Some(order_hash),
                Some(order_owner),
                Some(orderbook),
                Some(token),
                Some(vault_id),
                Some((signers, threshold)),
                Some(interpreter),
                Some(store),
                Some(bytecode),
                Some(input_token),
            ) => Some(ClaimOrder {
                order_hash,
                order_owner,
                orderbook,
                token,
                vault_id,
                signers,
                threshold,
                interpreter,
                store,
                bytecode,
                input_token,
            }),
            _ => None,
        };
        match (order, expiry_seconds) {
            (Some(order), Some(expiry_seconds)) if faults.is_empty() => Ok(Self {
                signers,
                order,
                expiry_seconds,
            }),
            _ => anyhow::bail!("{}", faults.join("; ")),
        }
    }

    pub fn order(&self) -> &ClaimOrder {
        &self.order
    }

    /// The order's signers this orchestrator signs for, in the deploy record's
    /// order.
    pub fn signers(&self) -> impl Iterator<Item = &dyn CouponKey> {
        self.signers.iter().map(|signer| signer.as_ref())
    }

    /// The signers that sign here, with keys this process holds, in order: the
    /// startup probe can be signed by them alone.
    pub fn local_signers(&self) -> usize {
        self.signers
            .iter()
            .filter(|signer| !matches!(signer.kind(), SignerKind::Service(_)))
            .count()
    }

    /// The claim coupon for the withdrawal whose transaction ID is `withdrawal`.
    pub async fn coupon(&self, terms: Payout, withdrawal: &ActionHash) -> Result<String> {
        let now = SystemTime::now().duration_since(UNIX_EPOCH)?.as_secs();
        self.coupon_at(terms, withdrawal, now).await
    }

    async fn coupon_at(&self, terms: Payout, withdrawal: &ActionHash, now: u64) -> Result<String> {
        let context = self.context(
            terms.recipient,
            terms.wei,
            U256::from(now) + U256::from(self.expiry_seconds.get()),
            withdrawal_nonce(withdrawal),
        )?;
        let request = SignRequest {
            digest: context_digest(&context),
            context,
            withdrawal: Some(withdrawal.clone()),
        };
        let seats = self.seats(&request, &self.signers).await?;
        Ok(serialize(&SignedCoupon {
            seats,
            context: request.context,
        }))
    }

    /// A coupon for one wei to the first signer, which expires at the latest
    /// second a float of exponent 0 can hold, with a nonce no withdrawal has,
    /// signed by the first `seats` signers that sign here. Simulated, it shows
    /// whether the claim order accepts them, and how many it needs.
    pub async fn probe_coupon(&self, seats: usize) -> Result<SignedCoupon> {
        let nonce = keccak256(b"bridge-orchestrator startup probe");
        let local: Vec<&Box<dyn CouponKey>> = self
            .signers
            .iter()
            .filter(|signer| !matches!(signer.kind(), SignerKind::Service(_)))
            .take(seats)
            .collect();
        anyhow::ensure!(
            local.len() == seats,
            "the probe asks {seats} signers that sign here, and there are {}",
            local.len()
        );
        let recipient = self.order.signers[0];
        let context = self.context(recipient, U256::from(1), MAX_EXPIRY, nonce)?;
        let request = SignRequest {
            digest: context_digest(&context),
            context,
            withdrawal: None,
        };
        let mut signed = Vec::with_capacity(local.len());
        for signer in local {
            signed.push(Seat {
                signer: signer.address(),
                signature: signer.sign(&request).await?,
            });
        }
        Ok(SignedCoupon {
            seats: signed,
            context: request.context,
        })
    }

    fn context(
        &self,
        recipient: Address,
        amount: U256,
        expiry: U256,
        nonce: B256,
    ) -> Result<Vec<B256>> {
        let order = &self.order;
        Ok(vec![
            pad_address(recipient),
            amount_word(amount)?,
            B256::from(expiry),
            order.order_hash,
            pad_address(order.order_owner),
            pad_address(order.orderbook),
            pad_address(order.token),
            order.vault_id,
            nonce,
        ])
    }

    /// Asks every one of `signers` at once, and takes the first M that sign, in
    /// the deploy record's order. Fewer than M is an error naming why each other
    /// did not sign: the withdrawal stays parked until M sign.
    async fn seats(
        &self,
        request: &SignRequest,
        signers: &[Box<dyn CouponKey>],
    ) -> Result<Vec<Seat>> {
        let threshold = self.order.threshold;
        let answers = futures::future::join_all(signers.iter().map(|signer| async move {
            let answer = tokio::time::timeout(SIGN_TIMEOUT, signer.sign(request)).await;
            (signer.address(), answer)
        }))
        .await;
        let mut seats = Vec::with_capacity(threshold);
        let mut failures = Vec::new();
        for (signer, answer) in answers {
            match answer {
                Ok(Ok(signature)) if seats.len() < threshold => {
                    seats.push(Seat { signer, signature })
                }
                Ok(Ok(_)) => {}
                Ok(Err(err)) => failures.push(format!("{err:#}")),
                Err(_) => failures.push(format!("{signer} did not sign within {SIGN_TIMEOUT:?}")),
            }
        }
        anyhow::ensure!(
            seats.len() == threshold,
            "{} of the {} signers asked signed, and a coupon needs CLAIM_THRESHOLD={threshold}: {}",
            seats.len(),
            signers.len(),
            failures.join("; ")
        );
        Ok(seats)
    }
}

/// CLAIM_SIGNERS and CLAIM_THRESHOLD, the claim order's N signers and the M of
/// them each coupon needs, as the deploy record prints them. On base-sepolia,
/// with neither set, the test signer alone. CLAIM_SIGNER, the one signer before
/// M-of-N, is refused rather than ignored.
fn claim_signers(
    network: Network,
    setting: &impl Fn(&str) -> Option<String>,
    faults: &mut Vec<String>,
) -> Option<(Vec<Address>, usize)> {
    if setting("CLAIM_SIGNER").is_some() {
        faults.push(
            "CLAIM_SIGNER is replaced by CLAIM_SIGNERS, the claim order's signers separated by commas, and CLAIM_THRESHOLD, how many of them sign each coupon, which the deploy record prints: unset it"
                .to_string(),
        );
    }
    let (raw_signers, raw_threshold) = (setting("CLAIM_SIGNERS"), setting("CLAIM_THRESHOLD"));
    let (raw_signers, raw_threshold) = match (raw_signers, raw_threshold) {
        (None, None) if network == Network::BaseSepolia => {
            tracing::info!(
                event = "config.testnet_defaults",
                "using TestNet's coupon signer: the test signer {TEST_SIGNER} alone"
            );
            return Some((vec![TEST_SIGNER], 1));
        }
        (Some(signers), Some(threshold)) => (signers, threshold),
        (signers, threshold) => {
            if signers.is_none() {
                faults.push("CLAIM_SIGNERS is required".to_string());
            }
            if threshold.is_none() {
                faults.push("CLAIM_THRESHOLD is required".to_string());
            }
            return None;
        }
    };
    let signers: Option<Vec<Address>> = raw_signers
        .split(',')
        .map(|signer| {
            signer
                .trim()
                .parse::<Address>()
                .ok()
                .filter(|a| !a.is_zero())
        })
        .collect();
    let Some(signers) = signers else {
        faults.push(format!(
            "CLAIM_SIGNERS={raw_signers} is not a list of nonzero addresses separated by commas"
        ));
        return None;
    };
    let mut ok = true;
    if signers.len() > MAX_CLAIM_SIGNERS {
        faults.push(format!(
            "CLAIM_SIGNERS lists {} signers, and a claim order lists at most {MAX_CLAIM_SIGNERS}",
            signers.len()
        ));
        ok = false;
    }
    if let Some(twice) = signers
        .iter()
        .enumerate()
        .find_map(|(i, signer)| signers[..i].contains(signer).then_some(signer))
    {
        faults.push(format!("CLAIM_SIGNERS lists {twice} twice"));
        ok = false;
    }
    if network == Network::Mainnet && signers.contains(&TEST_SIGNER) {
        faults.push(format!(
            "CLAIM_SIGNERS lists the test signer {TEST_SIGNER}, whose key is public: mainnet refuses it"
        ));
        ok = false;
    }
    let threshold = match raw_threshold.parse::<usize>() {
        Ok(threshold) if (1..=signers.len()).contains(&threshold) => Some(threshold),
        _ => {
            faults.push(format!(
                "CLAIM_THRESHOLD={raw_threshold} is not a number of signers from 1 to the {} CLAIM_SIGNERS lists",
                signers.len()
            ));
            None
        }
    };
    match threshold {
        Some(threshold) if ok => Some((signers, threshold)),
        _ => None,
    }
}

/// The signers this orchestrator signs for: the keys in SIGNER_PRIVATE_KEY; the
/// Safe SAFE_SIGNER, whose owner keys SAFE_OWNER_KEYS holds; and the signer
/// services SIGNER_SERVICES names, as `signer=URL` separated by commas. Each
/// must be a signer the order lists, none signed for twice, and together at
/// least its threshold. In the order `listed` names them.
fn signers_from(
    network: Network,
    setting: &impl Fn(&str) -> Option<String>,
    listed: Option<&(Vec<Address>, usize)>,
    faults: &mut Vec<String>,
) -> Vec<Box<dyn CouponKey>> {
    let mut signers: Vec<(&'static str, Box<dyn CouponKey>)> = Vec::new();
    let faults_before = faults.len();
    let keys = setting("SIGNER_PRIVATE_KEY");
    let owner_keys = setting("SAFE_OWNER_KEYS");
    let services = setting("SIGNER_SERVICES");
    if keys.is_none() && owner_keys.is_none() && services.is_none() {
        faults.push(NO_SIGNER.to_string());
        return Vec::new();
    }

    if let Some(raw) = keys {
        let parsed: std::result::Result<Vec<PrivateKeySigner>, _> = raw
            .split(',')
            .map(|key| key.trim().parse::<PrivateKeySigner>())
            .collect();
        match parsed {
            Err(_) => faults.push(
                "SIGNER_PRIVATE_KEY is not a secp256k1 private key, or several separated by commas"
                    .to_string(),
            ),
            Ok(keys) => {
                for key in keys {
                    if network == Network::Mainnet && Signer::address(&key) == TEST_SIGNER {
                        faults.push(format!(
                            "SIGNER_PRIVATE_KEY is the test signer {TEST_SIGNER}, whose key is public: mainnet refuses it"
                        ));
                    }
                    signers.push(("SIGNER_PRIVATE_KEY", Box::new(key)));
                }
            }
        }
    }

    if let Some(raw) = owner_keys {
        let safe = match (setting("SAFE_SIGNER"), listed) {
            (Some(raw), _) => match raw.parse::<Address>() {
                Ok(safe) => Some(safe),
                Err(_) => {
                    faults.push(format!("SAFE_SIGNER={raw} is not an address"));
                    None
                }
            },
            (None, Some((only, _))) if only.len() == 1 => Some(only[0]),
            (None, Some(_)) => {
                faults.push(
                    "SAFE_SIGNER is required with SAFE_OWNER_KEYS: the Safe of CLAIM_SIGNERS whose owner keys they are"
                        .to_string(),
                );
                None
            }
            (None, None) => None,
        };
        let keys: std::result::Result<Vec<PrivateKeySigner>, _> = raw
            .split(',')
            .map(|key| key.trim().parse::<PrivateKeySigner>())
            .collect();
        match keys {
            Err(_) => faults.push(
                "SAFE_OWNER_KEYS is not a list of secp256k1 private keys separated by commas"
                    .to_string(),
            ),
            Ok(keys) => {
                if network == Network::Mainnet
                    && keys.iter().any(|key| Signer::address(key) == TEST_SIGNER)
                {
                    faults.push(format!(
                        "SAFE_OWNER_KEYS holds the test signer {TEST_SIGNER}, whose key is public: mainnet refuses it"
                    ));
                }
                match SafeOwners::new(safe.unwrap_or(Address::ZERO), network.chain_id(), keys) {
                    Ok(owners) if safe.is_some() => signers.push(("SAFE_SIGNER", Box::new(owners))),
                    Ok(_) => {}
                    Err(err) => faults.push(format!("{err:#}")),
                }
            }
        }
    } else if setting("SAFE_SIGNER").is_some() {
        faults.push("SAFE_SIGNER is set and SAFE_OWNER_KEYS is not: SAFE_SIGNER names the Safe they sign for".to_string());
    }

    if let Some(raw) = services {
        for entry in raw.split(',').map(str::trim) {
            let Some((signer, url)) = entry.split_once('=') else {
                faults.push(format!(
                    "SIGNER_SERVICES holds {entry:?}, and each entry is <signer address>=<service URL>"
                ));
                continue;
            };
            let Ok(signer) = signer.trim().parse::<Address>() else {
                faults.push(format!(
                    "SIGNER_SERVICES holds {signer:?} as a signer, which is not an address"
                ));
                continue;
            };
            match SignerService::new(signer, network.chain_id(), url.trim()) {
                Ok(service) if network == Network::Mainnet && service.is_plain_http_off_host() => {
                    faults.push(format!(
                        "SIGNER_SERVICES names a plain http URL at {} for {signer}: mainnet takes https, or http on this machine",
                        service.host()
                    ));
                }
                Ok(service) => signers.push(("SIGNER_SERVICES", Box::new(service))),
                Err(err) => faults.push(format!("{err:#}")),
            }
        }
    }

    let Some((listed, threshold)) = listed else {
        return Vec::new();
    };
    for (i, (variable, signer)) in signers.iter().enumerate() {
        let address = signer.address();
        if !listed.contains(&address) {
            faults.push(format!(
                "{variable} signs for {address}, which CLAIM_SIGNERS does not list"
            ));
        }
        if let Some((first, _)) = signers[..i].iter().find(|(_, s)| s.address() == address) {
            faults.push(format!(
                "{address} is signed for twice, by {first} and {variable}"
            ));
        }
    }
    // A malformed source is named on its own: counting the rest would only repeat it.
    if signers.len() < *threshold && faults.len() == faults_before {
        faults.push(format!(
            "this orchestrator signs for {} of CLAIM_SIGNERS, and each coupon needs CLAIM_THRESHOLD={threshold}: add signer services (SIGNER_SERVICES) or keys",
            signers.len()
        ));
    }
    let mut signers: Vec<Box<dyn CouponKey>> =
        signers.into_iter().map(|(_, signer)| signer).collect();
    signers.sort_by_key(|signer| {
        listed
            .iter()
            .position(|address| *address == signer.address())
            .unwrap_or(usize::MAX)
    });
    signers
}

const NO_SIGNER: &str = "SIGNER_PRIVATE_KEY is required, or SAFE_OWNER_KEYS for a Safe signer, or SIGNER_SERVICES for signer services";

/// The largest integer a float of exponent 0 holds: its coefficient is an int224.
const MAX_EXPIRY: U256 = U256::from_limbs([u64::MAX, u64::MAX, u64::MAX, u64::MAX >> 33]);

/// The coupon as the website reads it: each seat's signer and signature, in
/// seat order, then each context word as a decimal number, all separated by
/// commas. One seat is `signer,signature,c0..c8`.
fn serialize(coupon: &SignedCoupon) -> String {
    let seats: Vec<String> = coupon
        .seats
        .iter()
        .map(|seat| format!("{:?},0x{}", seat.signer, hex::encode(&seat.signature)))
        .collect();
    let context: Vec<String> = coupon
        .context
        .iter()
        .map(|word| U256::from_be_bytes(word.0).to_string())
        .collect();
    format!("{},{}", seats.join(","), context.join(","))
}

/// The amount word of a coupon: the decimal float Raindex V6 pays out, with the
/// wei as its coefficient and -18 as its exponent, so 0xffffffee followed by the
/// wei in the low 224 bits. Converting back loses nothing. A float's
/// coefficient is an int224, which no HOT amount comes near.
pub(crate) fn amount_word(wei: U256) -> Result<B256> {
    anyhow::ensure!(
        wei <= MAX_EXPIRY,
        "the amount {wei} wei is too large for a decimal float"
    );
    let exponent = (-(HOT_DECIMALS as i32)) as u32;
    let word = (U256::from(exponent) << 224) | wei;
    Ok(B256::from(word))
}

#[cfg(test)]
impl ClaimOrder {
    /// The claim order the coupon test vector names: test/TestCouponSignature.t.sol.
    pub fn vector() -> Self {
        Self {
            order_hash: "0x5eeff397dac16f82057e20da98cf183daf95a0695980a196270e9e0922a275f9"
                .parse()
                .unwrap(),
            order_owner: address!("E3E064e3C2EEf66cb93dA8D8114F5084E92F48D6"),
            orderbook: address!("37FC0EFec37D19f8A221aa4F8F7600C9ba2AcD20"),
            token: address!("6c6EE5e31d828De241282B9606C8e98Ea48526E2"),
            vault_id: "0xeede83a4244afae4fef82c8f5b97df1f18bfe3193e65ba02052e37f6171b334b"
                .parse()
                .unwrap(),
            signers: vec![TEST_SIGNER],
            threshold: 1,
            interpreter: address!("4c52eee7Fb6aeD0F1a30130d96d02409D9d886cf"),
            store: address!("1Aa775533E28B1D843e1A589034984E3a62005DC"),
            bytecode: Bytes::from_static(&[0x00, 0xab]),
            input_token: address!("1234567890123456789012345678901234567890"),
        }
    }
}

#[cfg(test)]
impl CouponSigner {
    pub fn with_key(key: impl CouponKey + 'static) -> Self {
        Self::for_order(key, ClaimOrder::vector())
    }

    pub fn for_order(key: impl CouponKey + 'static, order: ClaimOrder) -> Self {
        Self::for_signers(vec![Box::new(key)], order)
    }

    pub fn for_signers(signers: Vec<Box<dyn CouponKey>>, order: ClaimOrder) -> Self {
        Self {
            signers,
            order,
            expiry_seconds: DEFAULT_EXPIRY_SECONDS,
        }
    }
}

/// What each signer signs: the EIP-191 hash of the packed words, as Raindex's
/// LibContext.build checks it.
pub(crate) fn context_digest(context: &[B256]) -> B256 {
    let packed: Vec<u8> = context.iter().flat_map(|word| word.0).collect();
    keccak256(
        [
            b"\x19Ethereum Signed Message:\n32".as_slice(),
            keccak256(&packed).as_slice(),
        ]
        .concat(),
    )
}

fn parsed<T: FromStr>(
    setting: &impl Fn(&str) -> Option<String>,
    key: &str,
    what: &str,
    faults: &mut Vec<String>,
) -> Option<T> {
    match setting(key) {
        None => {
            faults.push(format!("{key} is required"));
            None
        }
        Some(raw) => match raw.parse() {
            Ok(value) => Some(value),
            Err(_) => {
                faults.push(format!("{key}={raw} is not {what}"));
                None
            }
        },
    }
}

/// keccak256 of the withdrawal's 39-byte action hash. The claim order refuses a
/// nonce it has already seen, so every coupon signed for one withdrawal shares a
/// nonce and at most one of them can be claimed.
fn withdrawal_nonce(withdrawal: &ActionHash) -> B256 {
    keccak256(withdrawal.get_raw_39())
}

fn pad_address(addr: Address) -> B256 {
    addr.into_word()
}

#[derive(Debug)]
pub struct Payout {
    recipient: Address,
    wei: U256,
}

impl Payout {
    /// `amount` is HOT as a decimal. HOT has 18 decimals on Ethereum.
    pub fn new(recipient: &str, amount: &str) -> Result<Self> {
        let recipient = recipient
            .parse()
            .with_context(|| format!("the recipient {recipient:?} is not an address"))?;
        let wei = hot_in_wei(amount)
            .with_context(|| format!("the amount {amount:?} is not a HOT amount"))?;
        anyhow::ensure!(!wei.is_zero(), "the amount is zero");
        Ok(Self { recipient, wei })
    }
}

fn hot_in_wei(amount: &str) -> Option<U256> {
    let (whole, fraction) = amount.split_once('.').unwrap_or((amount, "0"));
    let is_digits = |part: &str| !part.is_empty() && part.bytes().all(|byte| byte.is_ascii_digit());
    if !is_digits(whole) || !is_digits(fraction) || fraction.len() > 18 {
        return None;
    }
    let ten = U256::from(10);
    whole
        .parse::<U256>()
        .ok()?
        .checked_mul(ten.pow(U256::from(18)))?
        .checked_add(fraction.parse::<U256>().ok()? * ten.pow(U256::from(18 - fraction.len())))
}

#[cfg(test)]
mod tests;
