use crate::config::Network;
use crate::signer::{safe_domain_separator, ClaimOrder, CouponSigner, SignedCoupon, SignerKind};
use alloy::primitives::{keccak256, Address, Bytes, B256, U256};
use alloy::providers::{Provider, ProviderBuilder};
use alloy::sol;
use alloy::sol_types::{Panic, Revert, SolCall, SolError, SolValue};
use alloy::transports::{RpcError, TransportError, TransportErrorKind};
use anyhow::{anyhow, bail, Result};
use std::error::Error;
use std::time::Duration;

sol! {
    struct IOV2 {
        address token;
        bytes32 vaultId;
    }

    struct EvaluableV4 {
        address interpreter;
        address store;
        bytes bytecode;
    }

    struct OrderV4 {
        address owner;
        EvaluableV4 evaluable;
        IOV2[] validInputs;
        IOV2[] validOutputs;
        bytes32 nonce;
    }

    struct SignedContextV1 {
        address signer;
        bytes32[] context;
        bytes signature;
    }

    struct TakeOrderConfigV4 {
        OrderV4 order;
        uint256 inputIOIndex;
        uint256 outputIOIndex;
        SignedContextV1[] signedContext;
    }

    /// Every amount is a decimal float, a bytes32.
    struct TakeOrdersConfigV5 {
        bytes32 minimumIO;
        bytes32 maximumIO;
        bytes32 maximumIORatio;
        bool IOIsInput;
        TakeOrderConfigV4[] orders;
        bytes data;
    }

    error MinimumIO(bytes32 minimumIO, bytes32 actualIO);

    #[sol(rpc)]
    interface IHoloLockVault {
        function token() external view returns (address);
        function orderbook() external view returns (address);
        function vaultId() external view returns (bytes32);
    }

    #[sol(rpc)]
    interface IRaindexV6 {
        function orderExists(bytes32 orderHash) external view returns (bool);
        function takeOrders4(TakeOrdersConfigV5 calldata config)
            external
            returns (bytes32 totalTakerInput, bytes32 totalTakerOutput);
    }

    /// What a Safe answers about itself.
    #[sol(rpc)]
    interface ISafe {
        function getThreshold() external view returns (uint256);
        function getOwners() external view returns (address[] memory);
        function domainSeparator() external view returns (bytes32);
    }
}

pub const RPC_TIMEOUT: Duration = Duration::from_secs(30);

/// The claim order's io-ratio, `1e-30` in src/holo-claim.rain, as the float the
/// parser makes of it: coefficient 1, exponent -30 (`CLAIM_IO_RATIO` in
/// src/Constants.sol). A claim passes it as its maximum ratio.
pub const CLAIM_IO_RATIO: B256 = B256::new([
    0xff, 0xff, 0xff, 0xe2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 1,
]);

/// The claim order's nonce, `CLAIM_ORDER_NONCE` in src/Constants.sol.
pub const CLAIM_ORDER_NONCE: B256 = B256::ZERO;

/// Refuses to run the bridge unless the RPC answers for `network`, the vault and
/// claim order the configuration names are the ones deployed there, the signers
/// this orchestrator signs for are the ones the order lists and can sign, and the
/// order takes coupons that CLAIM_THRESHOLD of them sign. Every mismatch names
/// its variable.
pub async fn check(
    network: Network,
    rpc_url: &str,
    vault: Address,
    signer: &CouponSigner,
) -> Result<()> {
    check_within(RPC_TIMEOUT, network, rpc_url, vault, signer).await
}

async fn check_within(
    timeout: Duration,
    network: Network,
    rpc_url: &str,
    vault: Address,
    signer: &CouponSigner,
) -> Result<()> {
    tokio::time::timeout(timeout, read_and_compare(network, rpc_url, vault, signer))
        .await
        .map_err(|_| {
            anyhow!(
                "{} did not answer within {timeout:?}",
                network.rpc_url_var()
            )
        })?
}

async fn read_and_compare(
    network: Network,
    rpc_url: &str,
    vault: Address,
    signer: &CouponSigner,
) -> Result<()> {
    let order = signer.order();
    let rpc_var = network.rpc_url_var();
    let vault_var = network.lock_vault_var();
    let url = rpc_url
        .parse()
        .map_err(|_| anyhow!("{rpc_var} is not a URL"))?;
    let provider = ProviderBuilder::new().on_http(url);
    let read_failed = |what: &str, err: TransportError| rpc_failure(rpc_var, what, &err);

    let chain_id = provider
        .get_chain_id()
        .await
        .map_err(|e| read_failed("eth_chainId", e))?;
    if chain_id != network.chain_id() {
        bail!(
            "{rpc_var} answers for chain {chain_id}, and NETWORK={} is chain {}",
            network.name(),
            network.chain_id()
        );
    }

    let code = provider
        .get_code_at(vault)
        .await
        .map_err(|e| read_failed("eth_getCode", e))?;
    if code.is_empty() {
        bail!("{vault_var} {vault} has no contract on chain {chain_id}");
    }

    let lock_vault = IHoloLockVault::new(vault, &provider);
    let call_failed = |what: &str, err: alloy::contract::Error| match err {
        alloy::contract::Error::TransportError(e) => rpc_failure(rpc_var, what, &e),
        other => anyhow!("{vault_var} {vault}: {what} failed: {other}"),
    };
    let token = lock_vault
        .token()
        .call()
        .await
        .map_err(|e| call_failed("token()", e))?
        ._0;
    let orderbook = lock_vault
        .orderbook()
        .call()
        .await
        .map_err(|e| call_failed("orderbook()", e))?
        ._0;
    let vault_id = lock_vault
        .vaultId()
        .call()
        .await
        .map_err(|e| call_failed("vaultId()", e))?
        ._0;

    let mut faults = Vec::new();
    if token != order.token {
        faults.push(format!(
            "TOKEN_ADDRESS {} is not the vault's token {token}",
            order.token
        ));
    }
    if vault_id != order.vault_id {
        faults.push(format!(
            "VAULT_ID {} is not the vault's vaultId {vault_id}",
            order.vault_id
        ));
    }
    if order.order_owner != vault {
        faults.push(format!(
            "ORDER_OWNER {} is not the vault {vault_var} {vault}",
            order.order_owner
        ));
    }
    if order_hash(&claim_order(order)) != order.order_hash {
        faults.push(
            "ORDER_HASH is not the hash of the order that ORDER_OWNER, TOKEN_ADDRESS, VAULT_ID, CLAIM_INTERPRETER, CLAIM_STORE, CLAIM_BYTECODE and CLAIM_INPUT_TOKEN describe"
                .to_string(),
        );
    }
    if orderbook != order.orderbook {
        faults.push(format!(
            "ORDERBOOK_ADDRESS {} is not the vault's orderbook {orderbook}",
            order.orderbook
        ));
    } else {
        let exists = IRaindexV6::new(orderbook, &provider)
            .orderExists(order.order_hash)
            .call()
            .await
            .map_err(|e| call_failed("orderExists(ORDER_HASH)", e))?
            ._0;
        if !exists {
            faults.push(format!(
                "ORDER_HASH {} is not an order on ORDERBOOK_ADDRESS {orderbook}",
                order.order_hash
            ));
        }
    }
    if !faults.is_empty() {
        bail!("{}", faults.join("; "));
    }

    check_signers(&provider, network, signer, rpc_var).await?;
    probe(&provider, signer, rpc_var).await
}

/// Every signer CLAIM_SIGNERS lists must be one Raindex V6 can check, so none
/// is a key with an EIP-7702 delegation. Each this orchestrator signs for must
/// be what it signs as: a key with no contract, a Safe whose threshold and owners
/// are the keys held here, or a signer service that answers for it. A signer
/// service that does not answer is logged, and the check passes while the
/// signers that can sign are at least CLAIM_THRESHOLD: a withdrawal stays parked
/// while fewer sign.
async fn check_signers<T, P>(
    provider: &P,
    network: Network,
    signer: &CouponSigner,
    rpc_var: &str,
) -> Result<()>
where
    T: alloy::transports::Transport + Clone,
    P: Provider<T>,
{
    let order = signer.order();
    let mut codes = Vec::with_capacity(order.signers.len());
    for listed in &order.signers {
        let code = provider
            .get_code_at(*listed)
            .await
            .map_err(|e| rpc_failure(rpc_var, "eth_getCode(CLAIM_SIGNERS)", &e))?;
        if is_delegated_key(&code) {
            bail!(
                "CLAIM_SIGNERS lists {listed}, which has an EIP-7702 delegation: Raindex V6 asks the delegate contract for a coupon's signature in place of the key, so the key's coupons are refused. Use a key with no delegation"
            );
        }
        codes.push((*listed, code));
    }
    let code_of = |address: Address| {
        codes
            .iter()
            .find(|(listed, _)| *listed == address)
            .map(|(_, code)| code.clone())
            .unwrap_or_default()
    };

    let mut able = Vec::new();
    for one in signer.signers() {
        let address = one.address();
        match one.kind() {
            SignerKind::Key => {
                if !code_of(address).is_empty() {
                    bail!(
                        "CLAIM_SIGNERS lists {address}, a contract, such as a Safe, and SIGNER_PRIVATE_KEY holds a key that signs as {address}, so it cannot sign for it. For a Safe, set SAFE_SIGNER and SAFE_OWNER_KEYS to the keys of its threshold of owners instead"
                    );
                }
                able.push(format!("{address}, a key held here"));
            }
            SignerKind::SafeOwners { owners } => {
                if code_of(address).is_empty() {
                    bail!(
                        "SAFE_SIGNER {address} has no contract, so it is a key, not a Safe, and SAFE_OWNER_KEYS signs for a Safe. For a key, put it in SIGNER_PRIVATE_KEY instead"
                    );
                }
                check_safe(provider, network, address, &owners, rpc_var).await?;
                able.push(format!(
                    "{address}, a Safe whose {} owner keys are held here",
                    owners.len()
                ));
            }
            SignerKind::Service(service) => match service.identity().await {
                Ok((answered, chain_id)) => {
                    service.require_identity(answered, chain_id)?;
                    able.push(format!("{address}, a signer service at {}", service.host()));
                }
                Err(err) => tracing::warn!(
                    event = "startup.signer_service_down",
                    signer = %address,
                    "{err:#}: its seat is filled by the others until it answers"
                ),
            },
        }
    }
    let threshold = order.threshold;
    if able.len() < threshold {
        bail!(
            "{} of the claim order's signers can sign now, and each coupon needs CLAIM_THRESHOLD={threshold}: {}",
            able.len(),
            if able.is_empty() {
                "none".to_string()
            } else {
                able.join("; ")
            }
        );
    }
    tracing::info!(
        event = "startup.signers",
        threshold,
        signers = order.signers.len(),
        "the claim order takes coupons that {threshold} of its {} signers sign. This orchestrator signs for {}: {}",
        order.signers.len(),
        able.len(),
        able.join("; ")
    );
    if signer.local_signers() >= threshold {
        tracing::warn!(
            event = "startup.one_party",
            "this orchestrator holds the keys for {} seats of the {threshold} each coupon needs, so it alone can sign every coupon: one party, not {threshold} (docs/signer-service.md)",
            signer.local_signers()
        );
    }
    Ok(())
}

/// What the claim order answered a simulated claim.
#[derive(Debug, PartialEq)]
enum ProbeOutcome {
    /// It paid, or would have but for the vault's balance (MinimumIO).
    Accepted,
    /// It read a seat past those the claim carries: Panic 0x32.
    TooFewSeats,
    /// "Wrong signer": a seat's signer is not one it lists.
    WrongSigner,
    /// Any other refusal, as its 4-byte selector.
    Refused(String),
}

/// Simulates the claim with coupons signed here: with M seats, which the order
/// must take, and with M-1, which it must refuse for reading seat M-1, so its
/// threshold is CLAIM_THRESHOLD. With fewer than M signers here, with as many
/// as there are, which it must refuse the same way, having found each of them a
/// listed signer. With none here, nothing is simulated: a signer service signs
/// only withdrawals.
async fn probe<T, P>(provider: &P, signer: &CouponSigner, rpc_var: &str) -> Result<()>
where
    T: alloy::transports::Transport + Clone,
    P: Provider<T>,
{
    let order = signer.order();
    let threshold = order.threshold;
    let local = signer.local_signers();
    if local == 0 {
        tracing::info!(
            event = "startup.probe_skipped",
            "no signer signs here, and a signer service signs only withdrawals: the claim order's acceptance of its signers is not simulated"
        );
        return Ok(());
    }
    let refused = |outcome: ProbeOutcome, named: &str| -> anyhow::Error {
        match outcome {
            ProbeOutcome::WrongSigner => anyhow!(
                "the claim order ORDER_HASH does not accept coupons from {named}: it answered \"Wrong signer\""
            ),
            ProbeOutcome::Refused(code) => {
                anyhow!("the claim order ORDER_HASH refused a coupon from {named} with error 0x{code}")
            }
            ProbeOutcome::Accepted => anyhow!(
                "the claim order ORDER_HASH took a coupon from {named}, fewer than CLAIM_THRESHOLD={threshold}: its threshold is lower"
            ),
            ProbeOutcome::TooFewSeats => anyhow!(
                "the claim order ORDER_HASH reads more seats than the {threshold} of CLAIM_THRESHOLD: it refused a coupon from {named} as too few signers"
            ),
        }
    };
    let seats = local.min(threshold);
    let coupon = signer.probe_coupon(seats).await?;
    let named = seat_names(&coupon);
    let outcome = simulate(provider, order, coupon, rpc_var).await?;
    if seats < threshold {
        if outcome != ProbeOutcome::TooFewSeats {
            return Err(refused(outcome, &named));
        }
        tracing::info!(
            event = "startup.probe",
            "the claim order took {named} as listed signers and needs more: the other {} of its {threshold} seats come from signer services",
            threshold - seats
        );
        return Ok(());
    }
    if outcome != ProbeOutcome::Accepted {
        return Err(refused(outcome, &named));
    }
    if threshold > 1 {
        let fewer = signer.probe_coupon(threshold - 1).await?;
        let named = seat_names(&fewer);
        match simulate(provider, order, fewer, rpc_var).await? {
            ProbeOutcome::TooFewSeats => {}
            outcome => return Err(refused(outcome, &named)),
        }
    }
    Ok(())
}

fn seat_names(coupon: &SignedCoupon) -> String {
    let signers: Vec<String> = coupon
        .seats
        .iter()
        .map(|seat| seat.signer.to_string())
        .collect();
    match signers.len() {
        1 => format!("CLAIM_SIGNERS {}", signers[0]),
        n => format!("{n} of CLAIM_SIGNERS ({})", signers.join(", ")),
    }
}

async fn simulate<T, P>(
    provider: &P,
    order: &ClaimOrder,
    coupon: SignedCoupon,
    rpc_var: &str,
) -> Result<ProbeOutcome>
where
    T: alloy::transports::Transport + Clone,
    P: Provider<T>,
{
    let from = order.signers[0];
    let call = take_one(order, coupon);
    tracing::debug!(
        event = "startup.probe",
        calldata = %Bytes::from(IRaindexV6::takeOrders4Call { config: call.clone() }.abi_encode()),
        "simulating the claim order probe"
    );
    let taken = IRaindexV6::new(order.orderbook, provider)
        .takeOrders4(call)
        .from(from)
        .call()
        .await;
    outcome(taken.map(|_| ()), rpc_var)
}

/// What a simulated claim's answer says. A transport failure, or an answer that
/// is not takeOrders4's, is an error.
fn outcome(
    taken: std::result::Result<(), alloy::contract::Error>,
    rpc_var: &str,
) -> Result<ProbeOutcome> {
    let what = "the claim order probe (takeOrders4)";
    let payload = match taken {
        Ok(()) => return Ok(ProbeOutcome::Accepted),
        Err(alloy::contract::Error::TransportError(RpcError::ErrorResp(payload))) => payload,
        Err(alloy::contract::Error::TransportError(e)) => {
            return Err(rpc_failure(rpc_var, what, &e))
        }
        Err(_) => bail!("{what} answered with data that is not takeOrders4's result"),
    };
    let Some(revert) = payload.as_revert_data() else {
        return Err(rpc_failure(rpc_var, what, &RpcError::ErrorResp(payload)));
    };
    if MinimumIO::abi_decode(&revert, true).is_ok() {
        return Ok(ProbeOutcome::Accepted);
    }
    if Panic::abi_decode(&revert, true).is_ok_and(|panic| panic.code == U256::from(0x32)) {
        return Ok(ProbeOutcome::TooFewSeats);
    }
    if Revert::abi_decode(&revert, true).is_ok_and(|r| r.reason == "Wrong signer") {
        return Ok(ProbeOutcome::WrongSigner);
    }
    Ok(ProbeOutcome::Refused(hex::encode(
        &revert[..revert.len().min(4)],
    )))
}

/// SAFE_SIGNER `safe` must be a Safe on `network`'s chain whose threshold is
/// the number of keys SAFE_OWNER_KEYS holds, each the key of one of its owners,
/// and whose EIP-712 domain is the one the owners sign under: otherwise its
/// `isValidSignature` refuses every coupon.
async fn check_safe<T, P>(
    provider: &P,
    network: Network,
    safe: Address,
    held: &[Address],
    rpc_var: &str,
) -> Result<()>
where
    T: alloy::transports::Transport + Clone,
    P: Provider<T>,
{
    let contract = ISafe::new(safe, provider);
    let not_a_safe = |what: &str, err: alloy::contract::Error| match err {
        alloy::contract::Error::TransportError(e) => rpc_failure(rpc_var, what, &e),
        _ => anyhow!("SAFE_SIGNER {safe} is a contract but not a Safe: it did not answer {what}"),
    };
    let threshold = contract
        .getThreshold()
        .call()
        .await
        .map_err(|e| not_a_safe("getThreshold()", e))?
        ._0;
    let owners = contract
        .getOwners()
        .call()
        .await
        .map_err(|e| not_a_safe("getOwners()", e))?
        ._0;
    let domain = contract
        .domainSeparator()
        .call()
        .await
        .map_err(|e| not_a_safe("domainSeparator()", e))?
        ._0;
    let chain_id = network.chain_id();
    if domain != safe_domain_separator(chain_id, safe) {
        bail!(
            "SAFE_SIGNER {safe} does not sign under the EIP-712 domain of a Safe 1.3.0 or later on chain {chain_id}, so its owners' signatures would not be over the hash it checks"
        );
    }
    let threshold = usize::try_from(threshold).unwrap_or(usize::MAX);
    if held.len() != threshold {
        bail!(
            "SAFE_OWNER_KEYS holds {} keys, and SAFE_SIGNER {safe} is a Safe of threshold {threshold}: give the keys of that many of its owners",
            held.len()
        );
    }
    let listed = owners
        .iter()
        .map(|owner| owner.to_string())
        .collect::<Vec<_>>()
        .join(", ");
    for owner in held {
        if !owners.contains(owner) {
            bail!(
                "SAFE_OWNER_KEYS holds the key of {owner}, which is not an owner of SAFE_SIGNER {safe}: its owners are {listed}"
            );
        }
    }
    tracing::info!(
        event = "startup.safe_signer",
        safe = %safe,
        threshold,
        owners = %listed,
        "SAFE_SIGNER {safe} is a Safe of threshold {threshold}: this orchestrator holds the keys of {} of its owners and signs as all of them, which is one party filling one seat, not {threshold} (docs/signer-service.md)",
        held.len()
    );
    Ok(())
}

/// An account with an EIP-7702 delegation. OrderBookV3 checked such a signer's
/// coupons by their ECDSA signature; Raindex V6 (OpenZeppelin 5's SignatureChecker)
/// asks any account with code, a delegation included, through EIP-1271 only, so a
/// delegated key's coupons are refused.
fn is_delegated_key(code: &Bytes) -> bool {
    code.len() == 23 && code.starts_with(&[0xef, 0x01, 0x00])
}

/// The OrderV4 the vault added, as script/ClaimOrderScript.sol adds it.
fn claim_order(order: &ClaimOrder) -> OrderV4 {
    let io = |token| IOV2 {
        token,
        vaultId: order.vault_id,
    };
    OrderV4 {
        owner: order.order_owner,
        evaluable: EvaluableV4 {
            interpreter: order.interpreter,
            store: order.store,
            bytecode: order.bytecode.clone(),
        },
        validInputs: vec![io(order.input_token)],
        validOutputs: vec![io(order.token)],
        nonce: CLAIM_ORDER_NONCE,
    }
}

fn order_hash(order: &OrderV4) -> B256 {
    keccak256(order.abi_encode())
}

/// The claim as the website sends it: takeOrders4 for exactly the coupon's
/// amount, the taker's input being the order's output, with one signed context
/// per seat.
fn take_one(order: &ClaimOrder, probe: SignedCoupon) -> TakeOrdersConfigV5 {
    let amount = probe.context[1];
    TakeOrdersConfigV5 {
        minimumIO: amount,
        maximumIO: amount,
        maximumIORatio: CLAIM_IO_RATIO,
        IOIsInput: true,
        orders: vec![TakeOrderConfigV4 {
            order: claim_order(order),
            inputIOIndex: alloy::primitives::U256::ZERO,
            outputIOIndex: alloy::primitives::U256::ZERO,
            signedContext: probe
                .seats
                .into_iter()
                .map(|seat| SignedContextV1 {
                    signer: seat.signer,
                    context: probe.context.clone(),
                    signature: seat.signature.into(),
                })
                .collect(),
        }],
        data: Bytes::new(),
    }
}

/// The cause of a failed read, in words of our own: a provider's URL can hold its
/// API key, reqwest names the URL in its message, and the provider's own answer can
/// echo either. Only reqwest's underlying causes, the HTTP status and the JSON-RPC
/// error code are kept.
pub(crate) fn rpc_failure(rpc_var: &str, what: &str, err: &TransportError) -> anyhow::Error {
    let cause = match err {
        RpcError::Transport(TransportErrorKind::Custom(inner)) => {
            match inner.downcast_ref::<reqwest::Error>() {
                Some(request) => causes(request),
                None => "the transport failed".to_string(),
            }
        }
        RpcError::Transport(TransportErrorKind::HttpError(http)) => {
            format!("the RPC answered HTTP {}", http.status)
        }
        RpcError::Transport(_) => "the transport failed".to_string(),
        RpcError::ErrorResp(payload) => {
            format!("the RPC answered with error code {}", payload.code)
        }
        RpcError::NullResp => "the RPC answered with no result".to_string(),
        RpcError::DeserError { .. } => "the RPC's answer could not be read".to_string(),
        RpcError::SerError(_) | RpcError::LocalUsageError(_) | RpcError::UnsupportedFeature(_) => {
            "the request could not be made".to_string()
        }
    };
    anyhow!("{rpc_var}: {what} failed: {cause}")
}

fn causes(err: &reqwest::Error) -> String {
    let mut chain = Vec::new();
    let mut source = err.source();
    while let Some(cause) = source {
        chain.push(cause.to_string());
        source = cause.source();
    }
    if chain.is_empty() {
        "the request failed".to_string()
    } else {
        chain.join(": ")
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::fake_rpc::{read_request, serve};
    use crate::signer::{
        amount_word, context_digest, safe_message_hash, CouponKey, SafeOwners, Seat, SignerService,
    };
    use alloy::primitives::{address, PrimitiveSignature};
    use alloy::signers::local::PrivateKeySigner;
    use alloy::sol_types::SolCall;

    sol! {
        error InvalidSignature(uint256 i);
    }
    use serde_json::{json, Value};
    use tokio::io::AsyncWriteExt;
    use tokio::net::TcpListener;

    const VAULT: Address = address!("E3E064e3C2EEf66cb93dA8D8114F5084E92F48D6");
    const HOT: Address = address!("6c6EE5e31d828De241282B9606C8e98Ea48526E2");
    const ORDERBOOK: Address = address!("37FC0EFec37D19f8A221aa4F8F7600C9ba2AcD20");
    const OTHER: Address = address!("1111111111111111111111111111111111111111");
    const KEY: &str = "0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a";
    const CONTRACT: &str = "0x608060405260043610";
    const DELEGATED: &str = "0xef01001111111111111111111111111111111111111111";

    fn vault_id() -> B256 {
        "0xeede83a4244afae4fef82c8f5b97df1f18bfe3193e65ba02052e37f6171b334b"
            .parse()
            .unwrap()
    }

    fn key() -> PrivateKeySigner {
        KEY.parse().unwrap()
    }

    /// A claim order whose one signer is `key()`, its hash rebuilt from its values.
    fn order() -> ClaimOrder {
        order_of(&[key().address()], 1)
    }

    /// A claim order of `threshold` of `signers`, its hash rebuilt from its values.
    fn order_of(signers: &[Address], threshold: usize) -> ClaimOrder {
        let mut order = ClaimOrder {
            order_hash: B256::ZERO,
            order_owner: VAULT,
            orderbook: ORDERBOOK,
            token: HOT,
            vault_id: vault_id(),
            signers: signers.to_vec(),
            threshold,
            interpreter: address!("4c52eee7Fb6aeD0F1a30130d96d02409D9d886cf"),
            store: address!("1Aa775533E28B1D843e1A589034984E3a62005DC"),
            bytecode: Bytes::from_static(&[0x00, 0xab]),
            input_token: address!("1234567890123456789012345678901234567890"),
        };
        order.order_hash = order_hash(&claim_order(&order));
        order
    }

    fn signer_for(order: ClaimOrder) -> CouponSigner {
        CouponSigner::for_order(key(), order)
    }

    /// The wei a coupon's amount word carries: its exponent must be -18.
    fn wei_of(word: B256) -> U256 {
        assert_eq!(
            &word.0[..4],
            &[0xff, 0xff, 0xff, 0xee],
            "the amount word's exponent"
        );
        U256::from_be_bytes(word.0) & ((U256::from(1) << 224) - U256::from(1))
    }

    /// What a JSON-RPC endpoint answers about one chain: the vault deployed with
    /// `token`, `orderbook` and `vault_id`, the orders that orderbook holds, and
    /// the claim order's signers and threshold as its expression has them.
    #[derive(Clone)]
    struct Chain {
        chain_id: u64,
        vault_deployed: bool,
        token: Address,
        orderbook: Address,
        vault_id: B256,
        orders: Vec<B256>,
        valid_signers: Vec<Address>,
        threshold: usize,
        /// The code at each account other than the vault: none unless named.
        codes: Vec<(Address, &'static str)>,
        vault_balance: U256,
        /// A Safe among the accounts, when there is one.
        safe: Option<FakeSafe>,
    }

    /// A Safe: its address, threshold, owners, and the domain separator it
    /// answers, a Safe 1.3+'s on the chain unless given.
    #[derive(Clone)]
    struct FakeSafe {
        address: Address,
        threshold: u64,
        owners: Vec<Address>,
        domain: Option<B256>,
    }

    type Answer = std::result::Result<String, Value>;

    fn reverted(data: Vec<u8>) -> Answer {
        Err(
            json!({"code": 3, "message": "execution reverted", "data": format!("0x{}", hex::encode(data))}),
        )
    }

    fn reason(reason: &str) -> Answer {
        reverted(
            Revert {
                reason: reason.to_string(),
            }
            .abi_encode(),
        )
    }

    impl Chain {
        fn of(network: Network) -> Self {
            Self {
                chain_id: network.chain_id(),
                vault_deployed: true,
                token: HOT,
                orderbook: ORDERBOOK,
                vault_id: vault_id(),
                orders: vec![order().order_hash],
                valid_signers: vec![key().address()],
                threshold: 1,
                codes: Vec::new(),
                vault_balance: U256::from(10),
                safe: None,
            }
        }

        /// This chain holding `order`, whose signers and threshold its
        /// expression has.
        fn holding(self, order: &ClaimOrder) -> Self {
            Self {
                orders: vec![order.order_hash],
                valid_signers: order.signers.clone(),
                threshold: order.threshold,
                ..self
            }
        }

        fn with_code(mut self, account: Address, code: &'static str) -> Self {
            self.codes.push((account, code));
            self
        }

        /// This chain with SAFE a Safe of `threshold` of `owners`.
        fn with_safe(self, threshold: u64, owners: &[PrivateKeySigner]) -> Self {
            Self {
                safe: Some(FakeSafe {
                    address: SAFE,
                    threshold,
                    owners: owners.iter().map(|key| key.address()).collect(),
                    domain: None,
                }),
                ..self.with_code(SAFE, "0x6080")
            }
        }

        fn code_at(&self, account: Address) -> &'static str {
            self.codes
                .iter()
                .rev()
                .find(|(at, _)| *at == account)
                .map_or("0x", |(_, code)| code)
        }

        fn answer(&self, method: &str, params: &Value) -> Answer {
            let empty = Ok("0x".to_string());
            match method {
                "eth_chainId" => Ok(format!("{:#x}", self.chain_id)),
                "eth_getCode" if self.vault_deployed && address_at(&params[0]) == VAULT => {
                    Ok("0x6080".to_string())
                }
                "eth_getCode" if address_at(&params[0]) != VAULT => {
                    Ok(self.code_at(address_at(&params[0])).to_string())
                }
                "eth_getCode" => empty,
                "eth_call" => {
                    let call = &params[0];
                    let to = address_at(&call["to"]);
                    let input = call["input"].as_str().or(call["data"].as_str()).unwrap();
                    let input = hex::decode(input.trim_start_matches("0x")).unwrap();
                    let selector: [u8; 4] = input[..4].try_into().unwrap();
                    let encoded = if to == VAULT && self.vault_deployed {
                        match selector {
                            IHoloLockVault::tokenCall::SELECTOR => self.token.abi_encode(),
                            IHoloLockVault::orderbookCall::SELECTOR => self.orderbook.abi_encode(),
                            IHoloLockVault::vaultIdCall::SELECTOR => self.vault_id.abi_encode(),
                            _ => return empty,
                        }
                    } else if to == self.orderbook
                        && selector == IRaindexV6::orderExistsCall::SELECTOR
                    {
                        let asked = IRaindexV6::orderExistsCall::abi_decode(&input, true)
                            .unwrap()
                            .orderHash;
                        self.orders.contains(&asked).abi_encode()
                    } else if to == self.orderbook
                        && selector == IRaindexV6::takeOrders4Call::SELECTOR
                    {
                        return self.take_orders(&input);
                    } else if let Some(safe) = self.safe.as_ref().filter(|safe| to == safe.address)
                    {
                        match selector {
                            ISafe::getThresholdCall::SELECTOR => {
                                U256::from(safe.threshold).abi_encode()
                            }
                            ISafe::getOwnersCall::SELECTOR => safe.owners.abi_encode(),
                            ISafe::domainSeparatorCall::SELECTOR => safe
                                .domain
                                .unwrap_or_else(|| safe_domain_separator(self.chain_id, to))
                                .abi_encode(),
                            _ => return empty,
                        }
                    } else {
                        return empty;
                    };
                    Ok(format!("0x{}", hex::encode(encoded)))
                }
                other => panic!("the check sent {other}"),
            }
        }

        /// takeOrders4 as RaindexV6 runs the claim order: each seat's signature
        /// first, then the expression's signer checks, seat by seat to the
        /// threshold, then the vault's balance.
        fn take_orders(&self, input: &[u8]) -> Answer {
            let config = IRaindexV6::takeOrders4Call::abi_decode(input, true)
                .unwrap()
                .config;
            let take = &config.orders[0];
            let seats = &take.signedContext;
            for (i, seat) in seats.iter().enumerate() {
                assert_eq!(
                    seat.context, seats[0].context,
                    "every seat signs one coupon"
                );
                let digest = context_digest(&seat.context);
                let valid = match self
                    .safe
                    .as_ref()
                    .filter(|safe| safe.address == seat.signer)
                {
                    Some(safe) => {
                        safe.accepts(self.chain_id, seat.signer, &digest, &seat.signature)
                    }
                    None => {
                        PrimitiveSignature::try_from(seat.signature.as_ref())
                            .unwrap()
                            .recover_address_from_prehash(&digest)
                            .unwrap()
                            == seat.signer
                    }
                };
                if !valid {
                    return reverted(InvalidSignature { i: U256::from(i) }.abi_encode());
                }
            }
            assert!(
                self.orders.contains(&order_hash(&take.order)),
                "the probe named an order the orderbook does not hold"
            );
            assert!(
                config.IOIsInput,
                "a claim takes the order's output as its input"
            );
            assert_eq!(
                config.maximumIORatio, CLAIM_IO_RATIO,
                "the claim's maximum ratio"
            );
            for i in 0..self.threshold {
                let Some(seat) = seats.get(i) else {
                    return reverted(
                        Panic {
                            code: U256::from(0x32),
                        }
                        .abi_encode(),
                    );
                };
                if !self.valid_signers.contains(&seat.signer) {
                    return reason("Wrong signer");
                }
            }
            for i in 0..self.threshold {
                for j in i + 1..self.threshold {
                    if seats[i].signer == seats[j].signer {
                        return reason("Duplicate signer");
                    }
                }
            }
            if self.vault_balance < wei_of(config.minimumIO) {
                return reverted(
                    MinimumIO {
                        minimumIO: config.minimumIO,
                        actualIO: B256::ZERO,
                    }
                    .abi_encode(),
                );
            }
            Ok(format!(
                "0x{}",
                hex::encode((config.minimumIO, B256::ZERO).abi_encode_params())
            ))
        }
    }

    impl FakeSafe {
        /// As Safe 1.4.1's checkNSignatures over the SafeMessage of `digest`:
        /// `threshold` owner signatures of 65 bytes, in ascending owner order,
        /// each an owner's.
        fn accepts(&self, chain_id: u64, safe: Address, digest: &B256, signature: &[u8]) -> bool {
            let hash = safe_message_hash(chain_id, safe, digest);
            if signature.len() != 65 * self.threshold as usize {
                return false;
            }
            let mut last = Address::ZERO;
            for part in signature.chunks(65) {
                let Ok(recovered) = PrimitiveSignature::try_from(part)
                    .and_then(|s| s.recover_address_from_prehash(&hash))
                else {
                    return false;
                };
                if recovered <= last || !self.owners.contains(&recovered) {
                    return false;
                }
                last = recovered;
            }
            true
        }
    }

    fn address_at(value: &Value) -> Address {
        value.as_str().unwrap().parse().unwrap()
    }

    /// Answers every request with `status` and `body`, whatever it asks.
    async fn serve_answer(status: &'static str, body: String) -> String {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let url = format!("http://{}/v3/{SECRET}", listener.local_addr().unwrap());
        tokio::spawn(async move {
            while let Ok((mut socket, _)) = listener.accept().await {
                read_request(&mut socket).await;
                let response = format!(
                    "HTTP/1.1 {status}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
                    body.len()
                );
                socket.write_all(response.as_bytes()).await.unwrap();
            }
        });
        url
    }

    const SECRET: &str = "secret-api-key";

    #[tokio::test]
    async fn names_a_failed_answer_in_words_of_its_own() {
        let leaky = format!("https://rpc.example/v3/{SECRET} refused the body {SECRET}");
        let answers = [
            (
                "200 OK",
                json!({"jsonrpc": "2.0", "id": 0, "error": {"code": -32000, "message": leaky, "data": leaky}}).to_string(),
                "ETH_RPC_URL: eth_chainId failed: the RPC answered with error code -32000",
            ),
            (
                "401 Unauthorized",
                leaky.clone(),
                "ETH_RPC_URL: eth_chainId failed: the RPC answered HTTP 401",
            ),
            (
                "200 OK",
                leaky.clone(),
                "ETH_RPC_URL: eth_chainId failed: the RPC's answer could not be read",
            ),
        ];
        for (status, body, expected) in answers {
            let url = serve_answer(status, body).await;

            let err = check(Network::Mainnet, &url, VAULT, &signer_for(order()))
                .await
                .expect_err("a failed answer passed the check");

            assert_eq!(format!("{err:#}"), expected);
        }
    }

    async fn check_against(network: Network, chain: Chain, order: &ClaimOrder) -> Result<()> {
        check_with(network, chain, &signer_for(order.clone())).await
    }

    async fn check_with(network: Network, chain: Chain, signer: &CouponSigner) -> Result<()> {
        let url =
            serve(move |method, params| chain.answer(method, params).map(Value::String)).await;
        check(network, &url, VAULT, signer).await
    }

    async fn refusal_with(network: Network, chain: Chain, signer: &CouponSigner) -> String {
        format!(
            "{:#}",
            check_with(network, chain, signer)
                .await
                .expect_err("the check passed")
        )
    }

    /// Anvil's accounts 1, 2 and 3, the owners of the Safe of threshold 2 at
    /// SAFE in test/TestSafeCouponSignature.t.sol.
    const SAFE: Address = address!("3838Fc4E0cba211c3D6D202539bB2dc2B72C7a22");
    const OWNER_KEYS: [&str; 3] = [
        "0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d",
        "0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a",
        "0x7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6",
    ];

    fn owners() -> Vec<PrivateKeySigner> {
        OWNER_KEYS.iter().map(|key| key.parse().unwrap()).collect()
    }

    /// The claim order with SAFE as its one signer, a chain where SAFE is a Safe
    /// of `threshold` with `owners()`, and the signer holding `held` of their keys.
    fn safe_setup(network: Network, threshold: u64, held: &[usize]) -> (Chain, CouponSigner) {
        let order = order_of(&[SAFE], 1);
        let chain = Chain::of(network)
            .holding(&order)
            .with_safe(threshold, &owners());
        let keys = held.iter().map(|i| owners()[*i].clone()).collect();
        let signer = CouponSigner::for_order(
            SafeOwners::new(SAFE, network.chain_id(), keys).unwrap(),
            order,
        );
        (chain, signer)
    }

    /// The Safe's isValidSignature checks the owners' signatures over the
    /// SafeMessage hash, as the probe has it do through takeOrders4.
    #[tokio::test]
    async fn passes_a_safe_signer_whose_threshold_of_owner_keys_it_holds() {
        for network in [Network::BaseSepolia, Network::Mainnet] {
            let (chain, signer) = safe_setup(network, 2, &[2, 0]);
            check_with(network, chain, &signer).await.unwrap();
        }
    }

    #[tokio::test]
    async fn refuses_safe_owner_keys_whose_count_is_not_the_safes_threshold() {
        let (chain, signer) = safe_setup(Network::Mainnet, 3, &[0, 1]);

        assert_eq!(
            refusal_with(Network::Mainnet, chain, &signer).await,
            format!("SAFE_OWNER_KEYS holds 2 keys, and SAFE_SIGNER {SAFE} is a Safe of threshold 3: give the keys of that many of its owners")
        );
    }

    #[tokio::test]
    async fn refuses_a_safe_owner_key_that_is_not_an_owner() {
        let (chain, signer) = safe_setup(Network::Mainnet, 2, &[0, 1]);
        let stranger = PrivateKeySigner::random();
        let chain = chain.with_safe(
            2,
            &[owners()[0].clone(), stranger.clone(), owners()[2].clone()],
        );
        let listed = [
            owners()[0].address(),
            stranger.address(),
            owners()[2].address(),
        ]
        .map(|owner| owner.to_string())
        .join(", ");

        assert_eq!(
            refusal_with(Network::Mainnet, chain, &signer).await,
            format!(
                "SAFE_OWNER_KEYS holds the key of {}, which is not an owner of SAFE_SIGNER {SAFE}: its owners are {listed}",
                owners()[1].address()
            )
        );
    }

    #[tokio::test]
    async fn refuses_a_safe_with_another_eip712_domain() {
        let (mut chain, signer) = safe_setup(Network::Mainnet, 2, &[0, 1]);
        chain.safe.as_mut().unwrap().domain = Some(safe_domain_separator(84_532, SAFE));

        assert_eq!(
            refusal_with(Network::Mainnet, chain, &signer).await,
            format!("SAFE_SIGNER {SAFE} does not sign under the EIP-712 domain of a Safe 1.3.0 or later on chain 1, so its owners' signatures would not be over the hash it checks")
        );
    }

    #[tokio::test]
    async fn refuses_a_contract_safe_signer_that_is_not_a_safe() {
        let (mut chain, signer) = safe_setup(Network::Mainnet, 2, &[0, 1]);
        chain.safe = None;

        assert_eq!(
            refusal_with(Network::Mainnet, chain, &signer).await,
            format!(
                "SAFE_SIGNER {SAFE} is a contract but not a Safe: it did not answer getThreshold()"
            )
        );
    }

    #[tokio::test]
    async fn refuses_safe_owner_keys_for_a_signer_that_is_a_key() {
        let (mut chain, signer) = safe_setup(Network::Mainnet, 2, &[0, 1]);
        chain.safe = None;
        let chain = chain.with_code(SAFE, "0x");

        assert_eq!(
            refusal_with(Network::Mainnet, chain, &signer).await,
            format!("SAFE_SIGNER {SAFE} has no contract, so it is a key, not a Safe, and SAFE_OWNER_KEYS signs for a Safe. For a key, put it in SIGNER_PRIVATE_KEY instead")
        );
    }

    /// A Safe refuses a signature its owners did not give over the hash it
    /// checks: the probe reports the InvalidSignature Raindex V6 reverts with.
    /// Here the keys sign under another chain's domain, which no setting can
    /// cause, as the Safe's chain and the signer's are both NETWORK's.
    #[tokio::test]
    async fn a_safe_refusing_the_probes_signature_is_reported() {
        let (chain, _) = safe_setup(Network::Mainnet, 2, &[0, 1]);
        let keys = vec![owners()[0].clone(), owners()[1].clone()];
        let signer = CouponSigner::for_order(
            SafeOwners::new(SAFE, 84_532, keys).unwrap(),
            order_of(&[SAFE], 1),
        );

        assert_eq!(
            refusal_with(Network::Mainnet, chain, &signer).await,
            format!("the claim order ORDER_HASH refused a coupon from CLAIM_SIGNERS {SAFE} with error 0x{}", hex::encode(InvalidSignature::SELECTOR))
        );
    }

    /// `order` changed by `change`, with its hash rebuilt, and a chain that holds it.
    fn changed(change: impl FnOnce(&mut ClaimOrder)) -> (ClaimOrder, Chain) {
        let mut order = order();
        change(&mut order);
        order.order_hash = order_hash(&claim_order(&order));
        let chain = Chain {
            orders: vec![order.order_hash],
            ..Chain::of(Network::BaseSepolia)
        };
        (order, chain)
    }

    async fn refusal(network: Network, chain: Chain, order: &ClaimOrder) -> String {
        format!(
            "{:#}",
            check_against(network, chain, order)
                .await
                .expect_err("the check passed")
        )
    }

    #[tokio::test]
    async fn passes_when_the_chain_holds_the_configured_vault_and_order() {
        for network in [Network::BaseSepolia, Network::Mainnet] {
            check_against(network, Chain::of(network), &order())
                .await
                .unwrap();
        }
    }

    #[tokio::test]
    async fn refuses_an_rpc_that_answers_for_the_other_network() {
        assert_eq!(
            refusal(Network::Mainnet, Chain::of(Network::BaseSepolia), &order()).await,
            "ETH_RPC_URL answers for chain 84532, and NETWORK=mainnet is chain 1"
        );
        assert_eq!(
            refusal(Network::BaseSepolia, Chain::of(Network::Mainnet), &order()).await,
            "BASE_SEPOLIA_RPC_URL answers for chain 1, and NETWORK=base-sepolia is chain 84532"
        );
    }

    #[tokio::test]
    async fn refuses_a_vault_with_no_contract() {
        let chain = Chain {
            vault_deployed: false,
            ..Chain::of(Network::Mainnet)
        };

        assert_eq!(
            refusal(Network::Mainnet, chain, &order()).await,
            format!("MAINNET_LOCK_VAULT_ADDRESS {VAULT} has no contract on chain 1")
        );
    }

    #[tokio::test]
    async fn names_each_value_the_vault_does_not_hold() {
        let one = B256::with_last_byte(1);
        let differing = [
            (
                Chain {
                    token: OTHER,
                    ..Chain::of(Network::Mainnet)
                },
                format!("TOKEN_ADDRESS {HOT} is not the vault's token {OTHER}"),
            ),
            (
                Chain {
                    vault_id: one,
                    ..Chain::of(Network::Mainnet)
                },
                format!("VAULT_ID {} is not the vault's vaultId {one}", vault_id()),
            ),
            (
                Chain {
                    orderbook: OTHER,
                    ..Chain::of(Network::Mainnet)
                },
                format!("ORDERBOOK_ADDRESS {ORDERBOOK} is not the vault's orderbook {OTHER}"),
            ),
        ];
        for (chain, expected) in differing {
            assert_eq!(refusal(Network::Mainnet, chain, &order()).await, expected);
        }
    }

    #[tokio::test]
    async fn refuses_an_order_owner_that_is_not_the_vault() {
        let (order, chain) = changed(|order| order.order_owner = OTHER);

        assert_eq!(
            refusal(Network::BaseSepolia, chain, &order).await,
            format!("ORDER_OWNER {OTHER} is not the vault BASE_SEPOLIA_LOCK_VAULT_ADDRESS {VAULT}")
        );
    }

    #[tokio::test]
    async fn refuses_an_order_hash_the_orderbook_does_not_hold() {
        let chain = Chain {
            orders: vec![],
            ..Chain::of(Network::Mainnet)
        };

        assert_eq!(
            refusal(Network::Mainnet, chain, &order()).await,
            format!(
                "ORDER_HASH {} is not an order on ORDERBOOK_ADDRESS {ORDERBOOK}",
                order().order_hash
            )
        );
    }

    #[tokio::test]
    async fn names_every_mismatch_in_one_refusal() {
        let chain = Chain {
            token: OTHER,
            orders: vec![],
            ..Chain::of(Network::Mainnet)
        };
        let order = ClaimOrder {
            order_owner: OTHER,
            ..order()
        };

        let message = refusal(Network::Mainnet, chain, &order).await;

        for variable in ["TOKEN_ADDRESS", "ORDER_OWNER", "ORDER_HASH"] {
            assert!(message.contains(variable), "{message}");
        }
    }

    #[tokio::test]
    async fn refuses_an_rpc_that_never_answers() {
        let silent = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let url = format!("http://{}/", silent.local_addr().unwrap());
        let held = tokio::spawn(async move {
            let mut open = Vec::new();
            while let Ok((socket, _)) = silent.accept().await {
                open.push(socket);
            }
        });

        let err = tokio::time::timeout(
            Duration::from_secs(10),
            check_within(
                Duration::from_millis(200),
                Network::BaseSepolia,
                &url,
                VAULT,
                &signer_for(order()),
            ),
        )
        .await
        .expect("the check waited on a silent RPC with no end")
        .expect_err("a silent RPC passed the check");
        held.abort();

        assert_eq!(
            format!("{err:#}"),
            "BASE_SEPOLIA_RPC_URL did not answer within 200ms"
        );
    }

    #[tokio::test]
    async fn refuses_an_rpc_it_cannot_reach_without_naming_its_url() {
        let closed = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let url = format!("http://{}/v3/secret-api-key", closed.local_addr().unwrap());
        drop(closed);

        let err = check(Network::Mainnet, &url, VAULT, &signer_for(order()))
            .await
            .expect_err("an unreachable RPC passed the check");
        let message = format!("{err:#}");

        assert!(
            message.starts_with("ETH_RPC_URL: eth_chainId failed: "),
            "{message}"
        );
        assert!(!message.contains("secret-api-key"), "{message}");
    }

    #[tokio::test]
    async fn refuses_order_values_that_do_not_hash_to_order_hash() {
        let order = ClaimOrder {
            store: OTHER,
            ..order()
        };

        assert_eq!(
            refusal(Network::Mainnet, Chain::of(Network::Mainnet), &order).await,
            "ORDER_HASH is not the hash of the order that ORDER_OWNER, TOKEN_ADDRESS, VAULT_ID, CLAIM_INTERPRETER, CLAIM_STORE, CLAIM_BYTECODE and CLAIM_INPUT_TOKEN describe"
        );
    }

    /// The order hash test vector: test/TestCouponSignature.t.sol hashes the same
    /// OrderV4 with Solidity's abi.encode, and ui/src/lib/network.test.ts with viem.
    #[test]
    fn hashes_the_claim_order_as_raindex_does() {
        let vector = ClaimOrder::vector();

        assert_eq!(
            order_hash(&claim_order(&vector)),
            "0xaa24ef105ecbfc39695b240de6baeb09278fd4ebf75674b29bcbd2c7ef72ff0b"
                .parse::<B256>()
                .unwrap()
        );
    }

    #[tokio::test]
    async fn refuses_a_key_the_claim_order_does_not_accept() {
        for network in [Network::BaseSepolia, Network::Mainnet] {
            let chain = Chain {
                valid_signers: vec![OTHER],
                ..Chain::of(network)
            };

            assert_eq!(
                refusal(network, chain, &order()).await,
                format!(
                    "the claim order ORDER_HASH does not accept coupons from CLAIM_SIGNERS {}: it answered \"Wrong signer\"",
                    key().address()
                )
            );
        }
    }

    #[tokio::test]
    async fn passes_a_claim_order_that_accepts_the_key_while_its_vault_is_empty() {
        let chain = Chain {
            vault_balance: U256::ZERO,
            ..Chain::of(Network::Mainnet)
        };

        check_against(Network::Mainnet, chain, &order())
            .await
            .unwrap();
    }

    #[tokio::test]
    async fn refuses_a_key_for_a_listed_signer_that_is_a_contract() {
        for network in [Network::BaseSepolia, Network::Mainnet] {
            let chain = Chain::of(network).with_code(key().address(), CONTRACT);

            assert_eq!(
                refusal(network, chain, &order()).await,
                format!(
                    "CLAIM_SIGNERS lists {0}, a contract, such as a Safe, and SIGNER_PRIVATE_KEY holds a key that signs as {0}, so it cannot sign for it. For a Safe, set SAFE_SIGNER and SAFE_OWNER_KEYS to the keys of its threshold of owners instead",
                    key().address()
                )
            );
        }
    }

    /// Anvil's public accounts carry such a delegation on mainnet, which is how
    /// this was found: Raindex V6 refused their coupons with InvalidSignature.
    /// A listed signer whose key is held elsewhere is refused all the same.
    #[tokio::test]
    async fn refuses_a_listed_signer_that_is_a_key_with_an_eip_7702_delegation() {
        let chain = Chain::of(Network::Mainnet).with_code(key().address(), DELEGATED);
        assert_eq!(
            refusal(Network::Mainnet, chain, &order()).await,
            format!(
                "CLAIM_SIGNERS lists {}, which has an EIP-7702 delegation: Raindex V6 asks the delegate contract for a coupon's signature in place of the key, so the key's coupons are refused. Use a key with no delegation",
                key().address()
            )
        );

        let two = order_of(&[key().address(), OTHER], 1);
        let chain = Chain::of(Network::Mainnet)
            .holding(&two)
            .with_code(OTHER, DELEGATED);
        assert!(refusal(Network::Mainnet, chain, &two)
            .await
            .starts_with(&format!(
                "CLAIM_SIGNERS lists {OTHER}, which has an EIP-7702 delegation"
            )));
    }

    fn keys() -> Vec<PrivateKeySigner> {
        owners()
    }

    /// A 2-of-3 claim order, with this orchestrator holding the keys of `held`.
    fn two_of_three(held: &[usize]) -> (ClaimOrder, CouponSigner) {
        let order = order_of(&keys().iter().map(|k| k.address()).collect::<Vec<_>>(), 2);
        let signers: Vec<Box<dyn CouponKey>> = held
            .iter()
            .map(|i| Box::new(keys()[*i].clone()) as Box<dyn CouponKey>)
            .collect();
        (order.clone(), CouponSigner::for_signers(signers, order))
    }

    /// The order takes two of the keys, and refuses one for reading the second
    /// seat: its threshold is CLAIM_THRESHOLD.
    #[tokio::test]
    async fn passes_two_of_three_keys_held_here() {
        let (order, signer) = two_of_three(&[0, 2]);
        let chain = Chain::of(Network::Mainnet).holding(&order);

        check_with(Network::Mainnet, chain, &signer).await.unwrap();
    }

    #[tokio::test]
    async fn refuses_an_order_that_takes_fewer_signatures_than_claim_threshold() {
        let (order, signer) = two_of_three(&[0, 1]);
        let chain = Chain {
            threshold: 1,
            ..Chain::of(Network::Mainnet).holding(&order)
        };

        assert_eq!(
            refusal_with(Network::Mainnet, chain, &signer).await,
            format!(
                "the claim order ORDER_HASH took a coupon from CLAIM_SIGNERS {}, fewer than CLAIM_THRESHOLD=2: its threshold is lower",
                keys()[0].address()
            )
        );
    }

    #[tokio::test]
    async fn refuses_an_order_that_needs_more_signatures_than_claim_threshold() {
        let (order, signer) = two_of_three(&[0, 1]);
        let chain = Chain {
            threshold: 3,
            ..Chain::of(Network::Mainnet).holding(&order)
        };

        assert_eq!(
            refusal_with(Network::Mainnet, chain, &signer).await,
            format!(
                "the claim order ORDER_HASH reads more seats than the 2 of CLAIM_THRESHOLD: it refused a coupon from 2 of CLAIM_SIGNERS ({}, {}) as too few signers",
                keys()[0].address(),
                keys()[1].address()
            )
        );
    }

    #[tokio::test]
    async fn refuses_signers_the_order_does_not_list() {
        let (order, signer) = two_of_three(&[0, 1]);
        let chain = Chain {
            valid_signers: vec![keys()[0].address(), keys()[2].address()],
            ..Chain::of(Network::Mainnet).holding(&order)
        };

        assert!(refusal_with(Network::Mainnet, chain, &signer)
            .await
            .ends_with("it answered \"Wrong signer\""));
    }

    /// A signer service for `signer` on mainnet, as docs/signer-service.md has
    /// it, answering `GET /signer` with `signer` on `chain_id`.
    async fn service_for(signer: Address, chain_id: u64) -> Box<dyn CouponKey> {
        let url = serve_answer(
            "200 OK",
            json!({"signer": signer, "chainId": chain_id}).to_string(),
        )
        .await;
        Box::new(SignerService::new(signer, 1, &url).unwrap())
    }

    /// A service the check cannot reach.
    async fn service_down(signer: Address) -> Box<dyn CouponKey> {
        let closed = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let url = format!("http://{}/", closed.local_addr().unwrap());
        drop(closed);
        Box::new(SignerService::new(signer, 1, &url).unwrap())
    }

    /// One key here and one signer service: the probe's one seat is taken as a
    /// listed signer, and the order reads a second.
    #[tokio::test]
    async fn passes_a_key_here_and_a_signer_service_for_two_of_three() {
        let (order, _) = two_of_three(&[]);
        let signer = CouponSigner::for_signers(
            vec![
                Box::new(keys()[0].clone()),
                service_for(keys()[1].address(), 1).await,
            ],
            order.clone(),
        );
        let chain = Chain::of(Network::Mainnet).holding(&order);

        check_with(Network::Mainnet, chain, &signer).await.unwrap();
    }

    #[tokio::test]
    async fn refuses_one_key_here_and_one_signer_for_an_order_of_one() {
        let (order, _) = two_of_three(&[]);
        let signer = CouponSigner::for_signers(
            vec![
                Box::new(keys()[0].clone()),
                service_for(keys()[1].address(), 1).await,
            ],
            order.clone(),
        );
        let chain = Chain {
            threshold: 1,
            ..Chain::of(Network::Mainnet).holding(&order)
        };

        assert!(refusal_with(Network::Mainnet, chain, &signer)
            .await
            .ends_with("fewer than CLAIM_THRESHOLD=2: its threshold is lower"));
    }

    /// With only signer services, nothing is simulated: they sign withdrawals
    /// alone.
    #[tokio::test]
    async fn passes_signer_services_alone_without_a_probe() {
        let (order, _) = two_of_three(&[]);
        let signer = CouponSigner::for_signers(
            vec![
                service_for(keys()[1].address(), 1).await,
                service_for(keys()[2].address(), 1).await,
            ],
            order.clone(),
        );
        let chain = Chain {
            threshold: 99,
            ..Chain::of(Network::Mainnet).holding(&order)
        };

        check_with(Network::Mainnet, chain, &signer).await.unwrap();
    }

    #[tokio::test]
    async fn a_signer_service_that_is_down_is_left_out_while_enough_others_can_sign() {
        let (order, _) = two_of_three(&[]);
        let chain = Chain::of(Network::Mainnet).holding(&order);
        let signer = CouponSigner::for_signers(
            vec![
                Box::new(keys()[0].clone()),
                Box::new(keys()[1].clone()),
                service_down(keys()[2].address()).await,
            ],
            order.clone(),
        );
        check_with(Network::Mainnet, chain.clone(), &signer)
            .await
            .unwrap();

        let signer = CouponSigner::for_signers(
            vec![
                Box::new(keys()[0].clone()),
                service_down(keys()[2].address()).await,
            ],
            order,
        );
        assert_eq!(
            refusal_with(Network::Mainnet, chain, &signer).await,
            format!(
                "1 of the claim order's signers can sign now, and each coupon needs CLAIM_THRESHOLD=2: {}, a key held here",
                keys()[0].address()
            )
        );
    }

    #[tokio::test]
    async fn refuses_a_signer_service_that_answers_for_another_signer() {
        let (order, _) = two_of_three(&[]);
        let signer = CouponSigner::for_signers(
            vec![
                Box::new(keys()[0].clone()),
                service_for(keys()[1].address(), 84_532).await,
            ],
            order.clone(),
        );
        let message = refusal_with(
            Network::Mainnet,
            Chain::of(Network::Mainnet).holding(&order),
            &signer,
        )
        .await;

        assert!(
            message.ends_with(&format!(
                "signs for {0} on chain 84532, and SIGNER_SERVICES names it for {0} on chain 1",
                keys()[1].address()
            )),
            "{message}"
        );
    }

    #[test]
    fn the_probe_claims_one_wei_at_the_claim_orders_ratio_with_a_signed_context_per_seat() {
        let probe = SignedCoupon {
            seats: vec![
                Seat {
                    signer: key().address(),
                    signature: vec![1],
                },
                Seat {
                    signer: OTHER,
                    signature: vec![2],
                },
            ],
            context: vec![B256::ZERO, amount_word(U256::from(1)).unwrap()],
        };

        let config = take_one(&order(), probe.clone());

        assert_eq!(wei_of(config.minimumIO), U256::from(1));
        assert_eq!(config.maximumIO, config.minimumIO);
        assert_eq!(config.maximumIORatio, CLAIM_IO_RATIO);
        assert!(config.IOIsInput);
        let signed = &config.orders[0].signedContext;
        assert_eq!(signed.len(), 2);
        for (context, seat) in signed.iter().zip(&probe.seats) {
            assert_eq!(context.signer, seat.signer);
            assert_eq!(context.signature.to_vec(), seat.signature);
            assert_eq!(context.context, probe.context);
        }
        assert_eq!(
            CLAIM_IO_RATIO,
            "0xffffffe200000000000000000000000000000000000000000000000000000001"
                .parse::<B256>()
                .unwrap()
        );
    }

    /// The claim calldata test vector: test/TestCouponSignature.t.sol encodes the
    /// same takeOrders4 call with abi.encodeCall, and ui/src/lib/claim.test.ts sends it.
    #[test]
    fn encodes_the_claim_as_forge_does() {
        let signer = address!("3C44CdDdB6a900fa2b585dd299e03d12FA4293BC");
        let order = ClaimOrder {
            order_hash: "0xaa24ef105ecbfc39695b240de6baeb09278fd4ebf75674b29bcbd2c7ef72ff0b"
                .parse()
                .unwrap(),
            signers: vec![signer],
            ..ClaimOrder::vector()
        };
        let words: Vec<B256> = [
            "0x0000000000000000000000001111111111111111111111111111111111111111",
            "0xffffffee000000000000000000000000000000000000000014d1120d7b160000",
            "0x0000000000000000000000000000000000000000000000000000000068581c00",
            "0xaa24ef105ecbfc39695b240de6baeb09278fd4ebf75674b29bcbd2c7ef72ff0b",
            "0x000000000000000000000000e3e064e3c2eef66cb93da8d8114f5084e92f48d6",
            "0x00000000000000000000000037fc0efec37d19f8a221aa4f8f7600c9ba2acd20",
            "0x0000000000000000000000006c6ee5e31d828de241282b9606c8e98ea48526e2",
            "0xeede83a4244afae4fef82c8f5b97df1f18bfe3193e65ba02052e37f6171b334b",
            "0x12c911abe545a1669fcbcdaeeede5352ee5a6743f59dbacdc0251b1e4c2f7b77",
        ]
        .iter()
        .map(|word| word.parse().unwrap())
        .collect();
        let signature = hex::decode("f3a686a6e1eccbfba52fbcde8a66bd2eca7bfd5b88bb326cb5486f6c4596e5bf7abe61d43b8e825201362259d527971715ee2d362460c97006ca29cb1355515a1b").unwrap();
        let coupon = SignedCoupon {
            seats: vec![Seat { signer, signature }],
            context: words,
        };

        let calldata = IRaindexV6::takeOrders4Call {
            config: take_one(&order, coupon),
        }
        .abi_encode();

        assert_eq!(
            keccak256(&calldata),
            "0x9c90a13c518aa17629ca92bb5947f54e0fcfb1c0ef65376c17d8ea02e7763522"
                .parse::<B256>()
                .unwrap()
        );
    }

    #[test]
    fn reads_each_answer_to_the_probe() {
        let answered = |data: Vec<u8>| {
            let answer = json!({"code": 3, "message": "execution reverted", "data": format!("0x{}", hex::encode(data))});
            outcome(
                Err(alloy::contract::Error::TransportError(RpcError::ErrorResp(
                    serde_json::from_value(answer).unwrap(),
                ))),
                "ETH_RPC_URL",
            )
            .unwrap()
        };
        let panic = |code: u64| {
            Panic {
                code: U256::from(code),
            }
            .abi_encode()
        };

        assert_eq!(
            outcome(Ok(()), "ETH_RPC_URL").unwrap(),
            ProbeOutcome::Accepted
        );
        assert_eq!(
            answered(
                MinimumIO {
                    minimumIO: B256::ZERO,
                    actualIO: B256::ZERO
                }
                .abi_encode()
            ),
            ProbeOutcome::Accepted
        );
        assert_eq!(answered(panic(0x32)), ProbeOutcome::TooFewSeats);
        assert_eq!(
            answered(panic(0x11)),
            ProbeOutcome::Refused("4e487b71".to_string())
        );
        assert_eq!(
            answered(
                Revert {
                    reason: "Wrong signer".to_string()
                }
                .abi_encode()
            ),
            ProbeOutcome::WrongSigner
        );
        assert_eq!(
            answered(
                Revert {
                    reason: "Order expired".to_string()
                }
                .abi_encode()
            ),
            ProbeOutcome::Refused("08c379a0".to_string())
        );
        assert_eq!(answered(vec![]), ProbeOutcome::Refused(String::new()));
    }
}
