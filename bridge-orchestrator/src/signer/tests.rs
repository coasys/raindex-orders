use super::*;
use crate::config::test_settings;
use crate::fake_rpc::read_request;
use alloy::signers::SignerSync;
use holo_hash::ActionHashB64;
use serde_json::Value;
use std::sync::{Arc, Mutex};
use tokio::io::AsyncWriteExt;
use tokio::net::TcpListener;

const NOW: u64 = 1_750_000_000;
const TEST_SIGNER_KEY: &str = "0xdcbe53cbf4cbee212fe6339821058f2787c7726ae0684335118cdea2e8adaafd";

async fn coupon(signer: &CouponSigner, withdrawal: &ActionHash, now: u64) -> String {
    let terms = Payout::new("0x1111111111111111111111111111111111111111", "1.5").unwrap();
    signer.coupon_at(terms, withdrawal, now).await.unwrap()
}

/// A serialized coupon read back: its seats, then its nine words.
fn read(coupon: &str) -> (Vec<(Address, Vec<u8>)>, Vec<B256>) {
    let fields: Vec<&str> = coupon.split(',').collect();
    assert!(
        fields.len() >= 11 && (fields.len() - 9).is_multiple_of(2),
        "seats then c0..c8: {coupon}"
    );
    let (seats, words) = fields.split_at(fields.len() - 9);
    let seats = seats
        .chunks(2)
        .map(|seat| {
            (
                seat[0].parse().unwrap(),
                hex::decode(&seat[1][2..]).unwrap(),
            )
        })
        .collect();
    let words = words
        .iter()
        .map(|word| B256::from(word.parse::<U256>().unwrap()))
        .collect();
    (seats, words)
}

/// Context field 8, after the seats.
fn nonce(coupon: &str) -> String {
    let (_, words) = read(coupon);
    U256::from_be_bytes(words[8].0).to_string()
}

fn recover(signature: &[u8], hash: &B256) -> Address {
    PrimitiveSignature::try_from(signature)
        .unwrap()
        .recover_address_from_prehash(hash)
        .unwrap()
}

#[test]
fn a_payout_is_a_positive_hot_amount_to_an_address() {
    let to = "0x1111111111111111111111111111111111111111";
    let wei = |amount| Payout::new(to, amount).map(|payout| payout.wei).ok();
    assert_eq!(
        wei("1.5"),
        Some(U256::from(15) * U256::from(10).pow(U256::from(17)))
    );
    assert_eq!(
        wei("5"),
        Some(U256::from(5) * U256::from(10).pow(U256::from(18)))
    );
    assert_eq!(wei("0.000000000000000001"), Some(U256::from(1)));
    for refused in [
        "",
        ".",
        "5.",
        ".5",
        "0",
        "0.0",
        "-5",
        "0x10",
        "1.5.0",
        " 1",
        "1e18",
        "0.0000000000000000001",
        &"9".repeat(60),
    ] {
        assert_eq!(wei(refused), None, "{refused:?}");
    }
    assert_eq!(
        format!("{:#}", Payout::new("0xdead", "1").unwrap_err()),
        "the recipient \"0xdead\" is not an address: invalid string length"
    );
}

/// The amount word of the test vector: 1.5 HOT is the wei with exponent -18.
#[test]
fn the_amount_word_is_the_wei_with_exponent_minus_18() {
    let word = amount_word(U256::from(1_500_000_000_000_000_000u128)).unwrap();

    assert_eq!(
        word,
        "0xffffffee000000000000000000000000000000000000000014d1120d7b160000"
            .parse::<B256>()
            .unwrap()
    );
    assert_eq!(
        amount_word(U256::from(1)).unwrap(),
        "0xffffffee00000000000000000000000000000000000000000000000000000001"
            .parse::<B256>()
            .unwrap()
    );
    let too_large = (U256::from(1) << 223) + U256::from(1);
    assert!(amount_word(too_large).is_err());
    assert!(amount_word(U256::from(1) << 223).is_err());
    assert!(amount_word((U256::from(1) << 223) - U256::from(1)).is_ok());
}

#[tokio::test]
async fn withdrawals_signed_in_the_same_second_get_different_nonces() {
    let signer = CouponSigner::with_key(PrivateKeySigner::random());
    let first = coupon(&signer, &ActionHash::from_raw_32(vec![1; 32]), NOW).await;
    let second = coupon(&signer, &ActionHash::from_raw_32(vec![2; 32]), NOW).await;

    assert_ne!(nonce(&first), nonce(&second));
}

#[tokio::test]
async fn a_withdrawal_signed_again_keeps_its_nonce() {
    let signer = CouponSigner::with_key(PrivateKeySigner::random());
    let withdrawal: ActionHash =
        ActionHashB64::from_b64_str("uhCkkWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlrx-wQB")
            .unwrap()
            .into();

    let first = coupon(&signer, &withdrawal, NOW).await;
    let later = coupon(&signer, &withdrawal, NOW + 3600).await;

    assert_eq!(nonce(&first), nonce(&later));
    // keccak256 of the ID's 39 raw bytes, computed independently with viem.
    assert_eq!(
        nonce(&first),
        "35225625112360308450652048405547205103100380385573023600097326644231926170802"
    );
}

/// The coupon test vector: anvil's third account signs the vector's words,
/// and test/TestCouponSignature.t.sol signs the same with forge's `vm.sign`
/// and expects this signature. ui/src/lib/coupon.test.ts reads this coupon. A
/// coupon of one seat is the format the website read before M-of-N.
#[tokio::test]
async fn a_key_signs_the_coupon_the_claim_order_checks() {
    let key: PrivateKeySigner =
        "0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a"
            .parse()
            .unwrap();
    let signer = CouponSigner::with_key(key);

    let coupon = coupon(&signer, &ActionHash::from_raw_32(vec![7; 32]), NOW).await;

    assert_eq!(coupon, GOLDEN_COUPON);
    let (_, words) = read(&coupon);
    assert_eq!(
        context_digest(&words),
        "0xf32a9e86bb3d75c00acec45f208001679a5f2a7976c5ce3327b6de7cecb0781f"
            .parse::<B256>()
            .unwrap()
    );
}

const GOLDEN_COUPON: &str = "0x3c44cdddb6a900fa2b585dd299e03d12fa4293bc,0x452449c0ce920f0e30878832f19e55a7ad3c173dfb7074cef53cc1cc1db54cd43df1a26a92e096b59ba413f28cd2c0c1f4aa6276b56ea14eb612c07fcd76eb191b,97433442488726861213578988847752201310395502865,115792088752037155414859468704681636286916632540171964433728779348048145154048,1750604800,42941365433660945573526868378572896801276519612010928011051331832534249141753,1300945060633283894583661816534861012306758682838,319615586448914156470689800627502155326116515104,619044111217614189527117770386815914092009957090,108043606565222972236900316128309391016550688326814185311821020602083120460619,8496889498503184870230947373316602526857109467185425766089433217409414560631";

struct ContractSigner;

impl CouponKey for ContractSigner {
    fn address(&self) -> Address {
        address!("5afe5afe5afe5afe5afe5afe5afe5afe5afe5afe")
    }

    fn sign<'a>(&'a self, request: &'a SignRequest) -> Signing<'a> {
        Box::pin(async move { Ok([request.digest.as_slice(), request.digest.as_slice()].concat()) })
    }
}

#[tokio::test]
async fn a_contract_signer_names_itself_and_signs_the_same_digest() {
    let signer = CouponSigner::with_key(ContractSigner);
    let withdrawal = ActionHash::from_raw_32(vec![7; 32]);

    let (seats, words) = read(&coupon(&signer, &withdrawal, NOW).await);
    let digest = context_digest(&words);

    assert_eq!(seats.len(), 1);
    assert_eq!(seats[0].0, ContractSigner.address());
    assert_eq!(seats[0].1, [digest.as_slice(), digest.as_slice()].concat());
}

/// Anvil's accounts 1, 2 and 3: the owners of the Safe of threshold 2 at
/// SAFE on mainnet in test/TestSafeCouponSignature.t.sol.
const OWNER_KEYS: [&str; 3] = [
    "0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d",
    "0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a",
    "0x7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6",
];
const SAFE: Address = address!("3838Fc4E0cba211c3D6D202539bB2dc2B72C7a22");

fn owner_key(i: usize) -> PrivateKeySigner {
    OWNER_KEYS[i].parse().unwrap()
}

/// A claim order whose signers are `signers` and threshold `threshold`.
fn order_of(signers: &[Address], threshold: usize) -> ClaimOrder {
    ClaimOrder {
        signers: signers.to_vec(),
        threshold,
        ..ClaimOrder::vector()
    }
}

/// Two keys of a 2-of-3 claim order sign a coupon: each seat's signature
/// recovers to its signer over the one digest, in CLAIM_SIGNERS order.
#[tokio::test]
async fn m_signers_each_sign_the_same_words_in_the_order_the_record_lists_them() {
    let (a, b, c) = (owner_key(0), owner_key(1), owner_key(2));
    let order = order_of(&[c.address(), a.address(), b.address()], 2);
    let signers: Vec<Box<dyn CouponKey>> = vec![Box::new(c.clone()), Box::new(a.clone())];
    let signer = CouponSigner::for_signers(signers, order);

    let (seats, words) = read(&coupon(&signer, &ActionHash::from_raw_32(vec![7; 32]), NOW).await);
    let digest = context_digest(&words);

    assert_eq!(seats.len(), 2);
    assert_eq!(seats[0].0, c.address());
    assert_eq!(seats[1].0, a.address());
    for (signer, signature) in &seats {
        assert_eq!(recover(signature, &digest), *signer);
    }
}

/// A signer that never signs, for the coupons that need its seat.
struct Refusing(Address);

impl CouponKey for Refusing {
    fn address(&self) -> Address {
        self.0
    }

    fn sign<'a>(&'a self, _: &'a SignRequest) -> Signing<'a> {
        Box::pin(async move { anyhow::bail!("{} refused", self.0) })
    }
}

/// A signer that does not answer.
struct Silent(Address);

impl CouponKey for Silent {
    fn address(&self) -> Address {
        self.0
    }

    fn sign<'a>(&'a self, _: &'a SignRequest) -> Signing<'a> {
        Box::pin(std::future::pending())
    }
}

#[tokio::test]
async fn a_coupon_is_signed_while_m_of_the_signers_sign() {
    let (a, b) = (owner_key(0), owner_key(1));
    let down = address!("0000000000000000000000000000000000000d0e");
    let order = order_of(&[down, a.address(), b.address()], 2);
    let signers: Vec<Box<dyn CouponKey>> = vec![
        Box::new(Refusing(down)),
        Box::new(a.clone()),
        Box::new(b.clone()),
    ];
    let signer = CouponSigner::for_signers(signers, order);

    let (seats, _) = read(&coupon(&signer, &ActionHash::from_raw_32(vec![7; 32]), NOW).await);

    assert_eq!(
        seats.iter().map(|(signer, _)| *signer).collect::<Vec<_>>(),
        vec![a.address(), b.address()]
    );
}

#[tokio::test]
async fn fewer_than_m_signing_is_an_error_naming_why_each_other_did_not() {
    let a = owner_key(0);
    let down = address!("0000000000000000000000000000000000000d0e");
    let order = order_of(&[a.address(), down], 2);
    let signer = CouponSigner::for_signers(vec![Box::new(a), Box::new(Refusing(down))], order);
    let terms = Payout::new("0x1111111111111111111111111111111111111111", "1").unwrap();

    let err = signer
        .coupon_at(terms, &ActionHash::from_raw_32(vec![7; 32]), NOW)
        .await
        .unwrap_err();

    assert_eq!(
        format!("{err:#}"),
        format!(
            "1 of the 2 signers asked signed, and a coupon needs CLAIM_THRESHOLD=2: {down} refused"
        )
    );
}

#[tokio::test(start_paused = true)]
async fn a_signer_that_does_not_answer_is_left_out_after_the_timeout() {
    let a = owner_key(0);
    let silent = address!("0000000000000000000000000000000000005107");
    let order = order_of(&[silent, a.address()], 2);
    let signer = CouponSigner::for_signers(vec![Box::new(Silent(silent)), Box::new(a)], order);
    let terms = Payout::new("0x1111111111111111111111111111111111111111", "1").unwrap();

    let err = signer
        .coupon_at(terms, &ActionHash::from_raw_32(vec![7; 32]), NOW)
        .await
        .unwrap_err();

    assert!(
        format!("{err:#}").ends_with(&format!("{silent} did not sign within 20s")),
        "{err:#}"
    );
}

/// The vector's claim order as a deploy record names it, with the test
/// signer's key.
const VECTOR_SIGNER_SETTINGS: [(&str, &str); 12] = [
    (
        "ORDER_HASH",
        "0x5eeff397dac16f82057e20da98cf183daf95a0695980a196270e9e0922a275f9",
    ),
    ("ORDER_OWNER", "0xE3E064e3C2EEf66cb93dA8D8114F5084E92F48D6"),
    (
        "ORDERBOOK_ADDRESS",
        "0x37FC0EFec37D19f8A221aa4F8F7600C9ba2AcD20",
    ),
    (
        "TOKEN_ADDRESS",
        "0x6c6EE5e31d828De241282B9606C8e98Ea48526E2",
    ),
    (
        "VAULT_ID",
        "0xeede83a4244afae4fef82c8f5b97df1f18bfe3193e65ba02052e37f6171b334b",
    ),
    (
        "CLAIM_SIGNERS",
        "0x8E72b7568738da52ca3DCd9b24E178127A4E7d37",
    ),
    ("CLAIM_THRESHOLD", "1"),
    (
        "CLAIM_INTERPRETER",
        "0x4c52eee7Fb6aeD0F1a30130d96d02409D9d886cf",
    ),
    ("CLAIM_STORE", "0x1Aa775533E28B1D843e1A589034984E3a62005DC"),
    ("CLAIM_BYTECODE", "0x00ab"),
    (
        "CLAIM_INPUT_TOKEN",
        "0x1234567890123456789012345678901234567890",
    ),
    ("SIGNER_PRIVATE_KEY", TEST_SIGNER_KEY),
];

fn settings_with(changes: &[(&'static str, Option<&str>)]) -> impl Fn(&str) -> Option<String> {
    let mut set: Vec<(&'static str, String)> = VECTOR_SIGNER_SETTINGS
        .iter()
        .map(|(key, value)| (*key, value.to_string()))
        .collect();
    for (key, value) in changes {
        set.retain(|(set_key, _)| set_key != key);
        if let Some(value) = value {
            set.push((key, value.to_string()));
        }
    }
    let set: Vec<(&str, &str)> = set
        .iter()
        .map(|(key, value)| (*key, value.as_str()))
        .collect();
    test_settings(&set)
}

fn refusal(network: Network, setting: impl Fn(&str) -> Option<String>) -> String {
    match CouponSigner::from_settings(network, setting) {
        Ok(_) => panic!("the signer settings were accepted"),
        Err(err) => format!("{err:#}"),
    }
}

fn addresses_of(signer: &CouponSigner) -> Vec<Address> {
    signer.signers().map(|signer| signer.address()).collect()
}

#[test]
fn the_settings_parse_into_the_claim_order() {
    let signer = CouponSigner::from_settings(Network::BaseSepolia, settings_with(&[])).unwrap();

    assert_eq!(signer.order(), &ClaimOrder::vector());
    assert_eq!(addresses_of(&signer), vec![TEST_SIGNER]);
    assert_eq!(signer.expiry_seconds, DEFAULT_EXPIRY_SECONDS);
}

const MAINNET_KEY: &str = "0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a";
const MAINNET_SIGNER: &str = "0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC";

/// The vector's settings with a key and signer mainnet takes, then `changes`.
fn mainnet_settings_with(
    changes: &[(&'static str, Option<&str>)],
) -> impl Fn(&str) -> Option<String> {
    let mut all = vec![
        ("SIGNER_PRIVATE_KEY", Some(MAINNET_KEY)),
        ("CLAIM_SIGNERS", Some(MAINNET_SIGNER)),
    ];
    all.extend_from_slice(changes);
    settings_with(&all)
}

#[test]
fn mainnet_names_each_unset_signer_variable() {
    for (key, _) in VECTOR_SIGNER_SETTINGS {
        let message = refusal(Network::Mainnet, mainnet_settings_with(&[(key, None)]));
        if key == "SIGNER_PRIVATE_KEY" {
            assert_eq!(message, NO_SIGNER);
        } else {
            assert_eq!(message, format!("{key} is required"));
        }
    }
}

/// TestNet's values are the ones the same on every chain: the orderbook, the
/// interpreter, the store, the vault ID and the test signer alone. Its mock HOT,
/// vault and claim order are not deployed on Base Sepolia yet, so a
/// base-sepolia run names those as mainnet does.
#[test]
fn base_sepolia_takes_testnet_values_for_what_is_the_same_on_every_chain() {
    let key = test_settings(&[("SIGNER_PRIVATE_KEY", TEST_SIGNER_KEY)]);

    assert_eq!(
        refusal(Network::BaseSepolia, key),
        "ORDER_HASH is required; ORDER_OWNER is required; TOKEN_ADDRESS is required; CLAIM_BYTECODE is required; CLAIM_INPUT_TOKEN is required"
    );
    assert_eq!(
        refusal(Network::BaseSepolia, test_settings(&[])),
        format!("ORDER_HASH is required; ORDER_OWNER is required; TOKEN_ADDRESS is required; CLAIM_BYTECODE is required; CLAIM_INPUT_TOKEN is required; {NO_SIGNER}")
    );
    let given = settings_with(&[
        ("ORDERBOOK_ADDRESS", None),
        ("VAULT_ID", None),
        ("CLAIM_SIGNERS", None),
        ("CLAIM_THRESHOLD", None),
        ("CLAIM_INTERPRETER", None),
        ("CLAIM_STORE", None),
    ]);
    let signer = CouponSigner::from_settings(Network::BaseSepolia, given).unwrap();
    assert_eq!(signer.order(), &ClaimOrder::vector());
}

/// A base-sepolia run takes the test signer alone only with neither variable
/// set: three signers and no threshold is not 1 of 3.
#[test]
fn the_signers_and_the_threshold_are_set_together() {
    assert_eq!(
        refusal(
            Network::BaseSepolia,
            settings_with(&[("CLAIM_THRESHOLD", None)])
        ),
        "CLAIM_THRESHOLD is required"
    );
    assert_eq!(
        refusal(
            Network::BaseSepolia,
            settings_with(&[("CLAIM_SIGNERS", None)])
        ),
        "CLAIM_SIGNERS is required"
    );
}

#[test]
fn claim_signer_is_refused_and_named_with_its_replacement() {
    let message = refusal(
        Network::BaseSepolia,
        settings_with(&[("CLAIM_SIGNER", Some(MAINNET_SIGNER))]),
    );

    assert_eq!(message, "CLAIM_SIGNER is replaced by CLAIM_SIGNERS, the claim order's signers separated by commas, and CLAIM_THRESHOLD, how many of them sign each coupon, which the deploy record prints: unset it");
}

#[test]
fn each_fault_in_the_signer_list_and_threshold_is_named() {
    let refused = |signers: &str, threshold: &str| {
        refusal(
            Network::Mainnet,
            mainnet_settings_with(&[
                ("CLAIM_SIGNERS", Some(signers)),
                ("CLAIM_THRESHOLD", Some(threshold)),
            ]),
        )
    };
    let other = "0x1111111111111111111111111111111111111111";

    assert_eq!(
        refused("0xZZ", "1"),
        "CLAIM_SIGNERS=0xZZ is not a list of nonzero addresses separated by commas"
    );
    assert_eq!(
        refused(&format!("{MAINNET_SIGNER},0x0000000000000000000000000000000000000000"), "1"),
        format!("CLAIM_SIGNERS={MAINNET_SIGNER},0x0000000000000000000000000000000000000000 is not a list of nonzero addresses separated by commas")
    );
    assert_eq!(
        refused(
            &format!(
                "{MAINNET_SIGNER},{other},{}",
                other.to_uppercase().replace("0X", "0x")
            ),
            "2"
        ),
        format!(
            "CLAIM_SIGNERS lists {} twice",
            other.parse::<Address>().unwrap()
        )
    );
    for threshold in ["0", "3", "two", "-1"] {
        assert_eq!(
            refused(&format!("{MAINNET_SIGNER},{other}"), threshold),
            format!("CLAIM_THRESHOLD={threshold} is not a number of signers from 1 to the 2 CLAIM_SIGNERS lists")
        );
    }
    let sixteen: Vec<String> = (1..=16).map(|i| format!("0x{i:040x}")).collect();
    assert_eq!(
        refused(&format!("{MAINNET_SIGNER},{}", sixteen[1..].join(",")), "1"),
        "CLAIM_SIGNERS lists 16 signers, and a claim order lists at most 15"
    );
    assert_eq!(
        refused(&format!("{MAINNET_SIGNER},{TEST_SIGNER}"), "1"),
        format!("CLAIM_SIGNERS lists the test signer {TEST_SIGNER}, whose key is public: mainnet refuses it")
    );
}

#[test]
fn each_malformed_signer_variable_is_named() {
    for (key, _) in VECTOR_SIGNER_SETTINGS {
        let message = refusal(Network::BaseSepolia, settings_with(&[(key, Some("0xZZ"))]));
        assert!(message.starts_with(key), "{message}");
        assert!(!message.contains("is required"), "{message}");
    }
    for value in ["a week", "0", "31536001"] {
        let message = refusal(
            Network::BaseSepolia,
            settings_with(&[("EXPIRY_SECONDS", Some(value))]),
        );
        assert_eq!(
            message,
            format!("EXPIRY_SECONDS={value} is not a number of seconds from 1 to 31536000")
        );
    }
}

#[test]
fn every_fault_is_named_in_one_refusal() {
    let message = refusal(
        Network::Mainnet,
        mainnet_settings_with(&[
            ("ORDER_HASH", None),
            ("TOKEN_ADDRESS", Some("hot")),
            ("SIGNER_PRIVATE_KEY", None),
        ]),
    );

    assert_eq!(
        message,
        format!("ORDER_HASH is required; TOKEN_ADDRESS=hot is not an address; {NO_SIGNER}")
    );
}

#[test]
fn a_malformed_private_key_is_not_repeated() {
    let almost_a_key = &TEST_SIGNER_KEY[..TEST_SIGNER_KEY.len() - 2];
    let message = refusal(
        Network::BaseSepolia,
        settings_with(&[("SIGNER_PRIVATE_KEY", Some(almost_a_key))]),
    );

    assert_eq!(
        message,
        "SIGNER_PRIVATE_KEY is not a secp256k1 private key, or several separated by commas"
    );
    assert!(!message.contains(almost_a_key));
}

#[test]
fn mainnet_refuses_the_test_signer_and_base_sepolia_takes_it() {
    let message = refusal(Network::Mainnet, settings_with(&[]));
    assert!(
        message.contains("test signer 0x8E72b7568738da52ca3DCd9b24E178127A4E7d37"),
        "{message}"
    );
    assert!(CouponSigner::from_settings(Network::BaseSepolia, settings_with(&[])).is_ok());
    assert!(CouponSigner::from_settings(Network::Mainnet, mainnet_settings_with(&[])).is_ok());
}

/// The keys of two of a 2-of-3 order's signers, in SIGNER_PRIVATE_KEY.
#[test]
fn signer_private_key_holds_one_key_per_signer_it_signs_for() {
    let listed = [
        owner_key(2).address(),
        owner_key(0).address(),
        owner_key(1).address(),
    ]
    .map(|a| a.to_string())
    .join(",");
    let keys = format!("{}, {}", OWNER_KEYS[0], OWNER_KEYS[2]);
    let signer = CouponSigner::from_settings(
        Network::Mainnet,
        settings_with(&[
            ("CLAIM_SIGNERS", Some(&listed)),
            ("CLAIM_THRESHOLD", Some("2")),
            ("SIGNER_PRIVATE_KEY", Some(&keys)),
        ]),
    )
    .unwrap();

    assert_eq!(
        addresses_of(&signer),
        vec![owner_key(2).address(), owner_key(0).address()],
        "in CLAIM_SIGNERS order"
    );
    assert_eq!(signer.order().threshold, 2);
    assert_eq!(signer.local_signers(), 2);
}

#[test]
fn a_key_the_order_does_not_list_is_refused() {
    let message = refusal(
        Network::Mainnet,
        mainnet_settings_with(&[("SIGNER_PRIVATE_KEY", Some(OWNER_KEYS[0]))]),
    );

    assert_eq!(
        message,
        format!(
            "SIGNER_PRIVATE_KEY signs for {}, which CLAIM_SIGNERS does not list",
            owner_key(0).address()
        )
    );
}

#[test]
fn fewer_signers_than_the_threshold_are_refused() {
    let listed = format!("{MAINNET_SIGNER},{}", owner_key(0).address());

    assert_eq!(
        refusal(
            Network::Mainnet,
            mainnet_settings_with(&[
                ("CLAIM_SIGNERS", Some(&listed)),
                ("CLAIM_THRESHOLD", Some("2")),
            ]),
        ),
        "this orchestrator signs for 1 of CLAIM_SIGNERS, and each coupon needs CLAIM_THRESHOLD=2: add signer services (SIGNER_SERVICES) or keys"
    );
}

#[test]
fn a_signer_signed_for_twice_is_refused() {
    let both = format!("{MAINNET_KEY},{MAINNET_KEY}");

    assert_eq!(
        refusal(
            Network::Mainnet,
            mainnet_settings_with(&[("SIGNER_PRIVATE_KEY", Some(&both))])
        ),
        format!(
            "{} is signed for twice, by SIGNER_PRIVATE_KEY and SIGNER_PRIVATE_KEY",
            MAINNET_SIGNER.parse::<Address>().unwrap()
        )
    );
}

/// The vector produced by test/TestSafeCouponSignature.t.sol against the Safe
/// 1.4.1 contracts on a fork of mainnet: the hash the Safe's fallback handler
/// has the owners sign for the coupon vector's digest.
#[test]
fn the_safe_message_hash_is_what_the_fallback_handler_computes() {
    let digest: B256 = "0xf32a9e86bb3d75c00acec45f208001679a5f2a7976c5ce3327b6de7cecb0781f"
        .parse()
        .unwrap();

    assert_eq!(
        safe_message_hash(1, SAFE, &digest),
        "0xd02d17b3c4226662353fa285586b495d7fcf937967ac510d2ebf535047b68d34"
            .parse::<B256>()
            .unwrap()
    );
    assert_ne!(
        safe_message_hash(84_532, SAFE, &digest),
        safe_message_hash(1, SAFE, &digest)
    );
}

/// A Safe's seat names the Safe, and carries each owner's 65-byte signature of
/// the SafeMessage hash in ascending owner order, whatever order the keys were
/// given in.
#[tokio::test]
async fn owners_sign_the_safe_message_hash_in_ascending_owner_order() {
    let owners = SafeOwners::new(SAFE, 1, vec![owner_key(2), owner_key(0)]).unwrap();
    let signer = CouponSigner::with_key(owners);
    let withdrawal = ActionHash::from_raw_32(vec![7; 32]);

    let (seats, words) = read(&coupon(&signer, &withdrawal, NOW).await);
    let hash = safe_message_hash(1, SAFE, &context_digest(&words));

    assert_eq!(seats[0].0, SAFE);
    assert_eq!(seats[0].1.len(), 130);
    let recovered: Vec<Address> = seats[0]
        .1
        .chunks(65)
        .map(|part| recover(part, &hash))
        .collect();
    let mut expected = vec![owner_key(0).address(), owner_key(2).address()];
    expected.sort();
    assert_eq!(recovered, expected);
    let SignerKind::SafeOwners { owners } = signer.signers().next().unwrap().kind() else {
        panic!("not a Safe's owners");
    };
    assert_eq!(owners, expected, "the owners, sorted");
}

#[test]
fn safe_owner_keys_are_two_to_twenty_and_none_twice() {
    let refused =
        |keys: Vec<PrivateKeySigner>| format!("{:#}", SafeOwners::new(SAFE, 1, keys).unwrap_err());

    assert_eq!(
        refused(vec![owner_key(0)]),
        "SAFE_OWNER_KEYS holds 1 keys: a Safe coupon signer needs the keys of its threshold of owners, 2 to 20"
    );
    assert_eq!(
        refused((0..21).map(|_| PrivateKeySigner::random()).collect()),
        "SAFE_OWNER_KEYS holds 21 keys: a Safe coupon signer needs the keys of its threshold of owners, 2 to 20"
    );
    assert_eq!(
        refused(vec![owner_key(0), owner_key(1), owner_key(0)]),
        format!(
            "SAFE_OWNER_KEYS holds the key of {} twice",
            owner_key(0).address()
        )
    );
    assert!(SafeOwners::new(SAFE, 1, vec![owner_key(0), owner_key(1)]).is_ok());
}

/// The vector's settings with `keys` as SAFE_OWNER_KEYS for the Safe, `listed`
/// as CLAIM_SIGNERS, and no SIGNER_PRIVATE_KEY.
fn safe_settings(keys: &str, listed: &str, threshold: &str) -> impl Fn(&str) -> Option<String> {
    let (keys, listed, threshold) = (keys.to_string(), listed.to_string(), threshold.to_string());
    move |key| match key {
        "SIGNER_PRIVATE_KEY" => None,
        "SAFE_OWNER_KEYS" => Some(keys.clone()),
        "CLAIM_SIGNERS" => Some(listed.clone()),
        "CLAIM_THRESHOLD" => Some(threshold.clone()),
        other => settings_with(&[])(other),
    }
}

/// With one listed signer, SAFE_OWNER_KEYS signs for it, as before M-of-N.
#[test]
fn safe_owner_keys_sign_for_the_one_listed_safe() {
    let two = format!("{}, {}", OWNER_KEYS[1], OWNER_KEYS[0]);
    let signer = CouponSigner::from_settings(
        Network::Mainnet,
        safe_settings(&two, &SAFE.to_string(), "1"),
    )
    .unwrap();

    assert_eq!(addresses_of(&signer), vec![SAFE]);
    assert_eq!(signer.order().signers, vec![SAFE]);
}

/// A Safe as one of three signers, with a key: SAFE_SIGNER names which.
#[test]
fn safe_signer_names_the_listed_safe_the_owner_keys_sign_for() {
    let two = format!("{},{}", OWNER_KEYS[1], OWNER_KEYS[0]);
    let key = owner_key(2);
    let listed = format!("{},{SAFE},{MAINNET_SIGNER}", key.address());
    let both = |safe_signer: Option<&str>| {
        let base = safe_settings(&two, &listed, "2");
        let safe_signer = safe_signer.map(str::to_string);
        move |name: &str| match name {
            "SIGNER_PRIVATE_KEY" => Some(OWNER_KEYS[2].to_string()),
            "SAFE_SIGNER" => safe_signer.clone(),
            other => base(other),
        }
    };

    let signer =
        CouponSigner::from_settings(Network::Mainnet, both(Some(&SAFE.to_string()))).unwrap();
    assert_eq!(addresses_of(&signer), vec![key.address(), SAFE]);

    assert_eq!(
        refusal(Network::Mainnet, both(None)),
        "SAFE_SIGNER is required with SAFE_OWNER_KEYS: the Safe of CLAIM_SIGNERS whose owner keys they are"
    );
    assert_eq!(
        refusal(
            Network::Mainnet,
            both(Some("0x1111111111111111111111111111111111111111"))
        ),
        "SAFE_SIGNER signs for 0x1111111111111111111111111111111111111111, which CLAIM_SIGNERS does not list"
    );
}

#[test]
fn each_fault_in_the_safe_owner_keys_is_named() {
    let refused =
        |network, keys: &str| refusal(network, safe_settings(keys, &SAFE.to_string(), "1"));

    assert_eq!(
        refused(Network::Mainnet, "0xZZ,0x01"),
        "SAFE_OWNER_KEYS is not a list of secp256k1 private keys separated by commas"
    );
    assert_eq!(
        refused(Network::Mainnet, OWNER_KEYS[0]),
        "SAFE_OWNER_KEYS holds 1 keys: a Safe coupon signer needs the keys of its threshold of owners, 2 to 20"
    );
    assert_eq!(
        refused(
            Network::Mainnet,
            &format!("{},{}", OWNER_KEYS[0], OWNER_KEYS[0])
        ),
        format!(
            "SAFE_OWNER_KEYS holds the key of {} twice",
            owner_key(0).address()
        )
    );
    assert_eq!(
        refused(
            Network::Mainnet,
            &format!("{},{}", OWNER_KEYS[0], TEST_SIGNER_KEY)
        ),
        format!(
            "SAFE_OWNER_KEYS holds the test signer {TEST_SIGNER}, whose key is public: mainnet refuses it"
        )
    );
    assert!(CouponSigner::from_settings(
        Network::BaseSepolia,
        safe_settings(
            &format!("{},{}", OWNER_KEYS[0], TEST_SIGNER_KEY),
            &SAFE.to_string(),
            "1"
        )
    )
    .is_ok());
}

#[test]
fn expiry_seconds_is_read_when_set() {
    let signer = CouponSigner::from_settings(
        Network::BaseSepolia,
        settings_with(&[("EXPIRY_SECONDS", Some("3600"))]),
    )
    .unwrap();

    assert_eq!(signer.expiry_seconds.get(), 3600);
}

#[test]
fn the_probe_coupon_pays_the_first_signer_one_wei_and_expires_last() {
    let key: PrivateKeySigner = TEST_SIGNER_KEY.parse().unwrap();
    let signer = CouponSigner::with_key(key);

    let probe = tokio::runtime::Runtime::new()
        .unwrap()
        .block_on(signer.probe_coupon(1))
        .unwrap();

    assert_eq!(probe.seats.len(), 1);
    assert_eq!(probe.seats[0].signer, TEST_SIGNER);
    assert_eq!(probe.context[0], pad_address(TEST_SIGNER));
    assert_eq!(probe.context[1], amount_word(U256::from(1)).unwrap());
    // int224::MAX with exponent 0: the latest expiry a float holds as an integer.
    assert_eq!(
        probe.context[2],
        "0x000000007fffffffffffffffffffffffffffffffffffffffffffffffffffffff"
            .parse::<B256>()
            .unwrap()
    );
    assert_eq!(
        recover(&probe.seats[0].signature, &context_digest(&probe.context)),
        TEST_SIGNER
    );
}

/// A signer service as docs/signer-service.md describes it, on this machine:
/// what it answers to `POST /sign` and `GET /signer`, and the requests it was
/// sent.
struct FakeService {
    url: String,
    requests: Arc<Mutex<Vec<(String, Value)>>>,
}

/// Serves `answer(path, body)` as `(status, body)` to every request.
async fn fake_service<A>(answer: A) -> FakeService
where
    A: Fn(&str, &Value) -> (&'static str, String) + Send + Sync + 'static,
{
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let url = format!("http://{}/holo/", listener.local_addr().unwrap());
    let requests = Arc::new(Mutex::new(Vec::new()));
    let seen = Arc::clone(&requests);
    let answer = Arc::new(answer);
    tokio::spawn(async move {
        while let Ok((mut socket, _)) = listener.accept().await {
            let (seen, answer) = (Arc::clone(&seen), Arc::clone(&answer));
            tokio::spawn(async move {
                let mut head = [0u8; 256];
                let peeked = socket.peek(&mut head).await.unwrap();
                let line = String::from_utf8_lossy(&head[..peeked]);
                let path = line.split_whitespace().nth(1).unwrap_or("").to_string();
                let body = read_request(&mut socket).await;
                let body: Value = serde_json::from_slice(&body).unwrap_or(Value::Null);
                let (status, reply) = answer(&path, &body);
                seen.lock().unwrap().push((path, body));
                let response = format!(
                    "HTTP/1.1 {status}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{reply}",
                    reply.len()
                );
                socket.write_all(response.as_bytes()).await.unwrap();
            });
        }
    });
    FakeService { url, requests }
}

/// A service holding `key`, which signs what it is sent: as an honest service
/// does once its checks pass.
async fn signing_service(key: PrivateKeySigner) -> FakeService {
    fake_service(move |path, body| match path {
        "/holo/signer" => (
            "200 OK",
            json!({"signer": key.address(), "chainId": 1}).to_string(),
        ),
        "/holo/sign" => {
            let words: Vec<B256> = body["context"]
                .as_array()
                .unwrap()
                .iter()
                .map(|word| word.as_str().unwrap().parse().unwrap())
                .collect();
            let signature = key.sign_hash_sync(&context_digest(&words)).unwrap();
            (
                "200 OK",
                json!({"signer": key.address(), "signature": format!("0x{}", hex::encode(signature.as_bytes()))})
                    .to_string(),
            )
        }
        _ => ("404 Not Found", "{}".to_string()),
    })
    .await
}

fn service_request(withdrawal: Option<ActionHash>) -> SignRequest {
    let context: Vec<B256> = (0u8..9).map(B256::with_last_byte).collect();
    SignRequest {
        digest: context_digest(&context),
        context,
        withdrawal,
    }
}

/// The request names the withdrawal, the nine words, the signer and the chain,
/// and the signature that comes back is the signer's.
#[tokio::test]
async fn a_signer_service_is_sent_the_withdrawal_and_answers_the_signature() {
    let key = owner_key(0);
    let service = signing_service(key.clone()).await;
    let client = SignerService::new(key.address(), 1, &service.url).unwrap();
    let withdrawal = ActionHash::from_raw_32(vec![7; 32]);
    let request = service_request(Some(withdrawal.clone()));

    let signature = client.sign(&request).await.unwrap();
    client.identity_check().await.unwrap();

    assert_eq!(recover(&signature, &request.digest), key.address());
    let requests = service.requests.lock().unwrap().clone();
    assert_eq!(requests[0].0, "/holo/sign");
    assert_eq!(
        requests[0].1,
        json!({
            "withdrawal": ActionHashB64::from(withdrawal).to_string(),
            "context": request.context.iter().map(|w| w.to_string()).collect::<Vec<_>>(),
            "signer": key.address(),
            "chainId": 1,
        })
    );
    assert_eq!(requests[1].0, "/holo/signer");
}

#[tokio::test]
async fn a_signer_service_is_never_sent_the_probe() {
    let key = owner_key(0);
    let service = signing_service(key.clone()).await;
    let client = SignerService::new(key.address(), 1, &service.url).unwrap();

    let err = client.sign(&service_request(None)).await.unwrap_err();

    assert_eq!(
        format!("{err:#}"),
        format!(
            "the signer service for {} signs coupons for withdrawals, and this pays none",
            key.address()
        )
    );
    assert!(service.requests.lock().unwrap().is_empty());
}

#[tokio::test]
async fn each_wrong_answer_from_a_signer_service_is_named() {
    let key = owner_key(0);
    let other = owner_key(1);
    let wrong_signature = {
        let other = other.clone();
        move |_: &str, body: &Value| {
            let words: Vec<B256> = body["context"]
                .as_array()
                .unwrap()
                .iter()
                .map(|w| w.as_str().unwrap().parse().unwrap())
                .collect();
            let signature = other.sign_hash_sync(&context_digest(&words)).unwrap();
            (
                "200 OK",
                json!({"signer": owner_key(0).address(), "signature": format!("0x{}", hex::encode(signature.as_bytes()))}).to_string(),
            )
        }
    };
    let withdrawal = Some(ActionHash::from_raw_32(vec![7; 32]));
    let refused = |service: FakeService| {
        let withdrawal = withdrawal.clone();
        let key = key.clone();
        async move {
            let client = SignerService::new(key.address(), 1, &service.url).unwrap();
            let host = client.host();
            let message = format!(
                "{:#}",
                client.sign(&service_request(withdrawal)).await.unwrap_err()
            );
            (message, host)
        }
    };
    let signer = key.address();

    let (message, host) = refused(
        fake_service(|_, _| {
            (
                "409 Conflict",
                json!({"refused": "the amount 40 HOT is not the spend's 30 HOT"}).to_string(),
            )
        })
        .await,
    )
    .await;
    assert_eq!(message, format!("the signer service for {signer} at {host} refused: the amount 40 HOT is not the spend's 30 HOT"));

    let (message, host) =
        refused(fake_service(|_, _| ("500 Internal Server Error", "{}".to_string())).await).await;
    assert_eq!(
        message,
        format!("the signer service for {signer} at {host} answered HTTP 500")
    );

    let (message, host) =
        refused(fake_service(|_, _| ("200 OK", "signed".to_string())).await).await;
    assert_eq!(message, format!("the signer service for {signer} at {host} answered with something other than {{\"signer\", \"signature\"}}"));

    let answer_for_other = {
        let other = other.address();
        move |_: &str, _: &Value| {
            (
                "200 OK",
                json!({"signer": other, "signature": "0x01"}).to_string(),
            )
        }
    };
    let (message, host) = refused(fake_service(answer_for_other).await).await;
    assert_eq!(
        message,
        format!(
            "the signer service for {signer} at {host} answered for {}",
            other.address()
        )
    );

    let (message, host) = refused(fake_service(wrong_signature).await).await;
    assert_eq!(message, format!("the signer service for {signer} at {host} answered a signature that is not {signer}'s over the coupon"));
}

#[tokio::test]
async fn a_signer_service_answering_for_another_signer_or_chain_fails_its_check() {
    let key = owner_key(0);
    let service = signing_service(owner_key(1)).await;
    let client = SignerService::new(key.address(), 1, &service.url).unwrap();

    assert_eq!(
        format!("{:#}", client.identity_check().await.unwrap_err()),
        format!(
            "the signer service at {} signs for {} on chain 1, and SIGNER_SERVICES names it for {} on chain 1",
            client.host(),
            owner_key(1).address(),
            key.address()
        )
    );
    let client = SignerService::new(owner_key(1).address(), 84_532, &service.url).unwrap();
    assert!(client.identity_check().await.is_err());
}

#[tokio::test]
async fn an_unreachable_signer_service_is_named_by_its_host_alone() {
    let closed = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let url = format!("http://{}/token-in-the-path", closed.local_addr().unwrap());
    drop(closed);
    let client = SignerService::new(owner_key(0).address(), 1, &url).unwrap();

    let message = format!(
        "{:#}",
        client
            .sign(&service_request(Some(ActionHash::from_raw_32(vec![7; 32]))))
            .await
            .unwrap_err()
    );

    assert_eq!(
        message,
        format!(
            "the signer service for {} at {} could not be reached",
            owner_key(0).address(),
            client.host()
        )
    );
    assert!(!message.contains("token-in-the-path"));
}

/// Two signers' services and the orchestrator's own key fill a 2-of-3 coupon.
#[tokio::test]
async fn signer_services_fill_seats_with_the_keys_held_here() {
    let (a, b, c) = (owner_key(0), owner_key(1), owner_key(2));
    let service_b = signing_service(b.clone()).await;
    let service_c = signing_service(c.clone()).await;
    let listed = [a.address(), b.address(), c.address()]
        .map(|x| x.to_string())
        .join(",");
    let services = format!(
        "{}={},{}={}",
        c.address(),
        service_c.url,
        b.address(),
        service_b.url
    );
    let signer = CouponSigner::from_settings(
        Network::Mainnet,
        settings_with(&[
            ("CLAIM_SIGNERS", Some(&listed)),
            ("CLAIM_THRESHOLD", Some("2")),
            ("SIGNER_PRIVATE_KEY", None),
            ("SIGNER_SERVICES", Some(&services)),
        ]),
    )
    .unwrap();
    assert_eq!(addresses_of(&signer), vec![b.address(), c.address()]);
    assert_eq!(signer.local_signers(), 0);

    let (seats, words) = read(&coupon(&signer, &ActionHash::from_raw_32(vec![7; 32]), NOW).await);

    assert_eq!(seats.len(), 2);
    for (seat, expected) in seats.iter().zip([b.address(), c.address()]) {
        assert_eq!(seat.0, expected);
        assert_eq!(recover(&seat.1, &context_digest(&words)), expected);
    }
}

#[test]
fn each_fault_in_signer_services_is_named() {
    let refused = |network, services: &str| {
        refusal(
            network,
            settings_with(&[
                ("SIGNER_PRIVATE_KEY", None),
                ("CLAIM_SIGNERS", Some(MAINNET_SIGNER)),
                ("SIGNER_SERVICES", Some(services)),
            ]),
        )
    };
    let signer: Address = MAINNET_SIGNER.parse().unwrap();

    assert_eq!(
        refused(Network::Mainnet, "https://signer.example"),
        "SIGNER_SERVICES holds \"https://signer.example\", and each entry is <signer address>=<service URL>"
    );
    assert_eq!(
        refused(Network::Mainnet, "holo=https://signer.example"),
        "SIGNER_SERVICES holds \"holo\" as a signer, which is not an address"
    );
    assert_eq!(
        refused(Network::Mainnet, &format!("{signer}=signer.example")),
        format!("SIGNER_SERVICES names \"signer.example\" for {signer}, which is not an http or https URL")
    );
    assert_eq!(
        refused(Network::Mainnet, &format!("{signer}=http://signer.example/holo")),
        format!("SIGNER_SERVICES names a plain http URL at signer.example for {signer}: mainnet takes https, or http on this machine")
    );
    assert_eq!(
        refused(Network::Mainnet, &format!("{signer}=https://signer.example/?token=1")),
        format!("SIGNER_SERVICES names a URL with a query or fragment for {signer}: name the service's base URL")
    );
    assert_eq!(
        refused(
            Network::Mainnet,
            "0x1111111111111111111111111111111111111111=https://signer.example"
        ),
        "SIGNER_SERVICES signs for 0x1111111111111111111111111111111111111111, which CLAIM_SIGNERS does not list"
    );
    for ok in [
        format!("{signer}=https://signer.example/holo"),
        format!("{signer}=http://127.0.0.1:8545/holo"),
    ] {
        assert!(CouponSigner::from_settings(
            Network::Mainnet,
            settings_with(&[
                ("SIGNER_PRIVATE_KEY", None),
                ("CLAIM_SIGNERS", Some(MAINNET_SIGNER)),
                ("SIGNER_SERVICES", Some(&ok)),
            ])
        )
        .is_ok());
    }
    assert!(CouponSigner::from_settings(
        Network::BaseSepolia,
        settings_with(&[
            ("SIGNER_PRIVATE_KEY", None),
            ("CLAIM_SIGNERS", Some(MAINNET_SIGNER)),
            (
                "SIGNER_SERVICES",
                Some(&format!("{signer}=http://signer.example"))
            ),
        ])
    )
    .is_ok());
}
