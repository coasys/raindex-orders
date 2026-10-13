import {
	encodeAbiParameters,
	isAddress,
	isAddressEqual,
	isHex,
	keccak256,
	parseAbiParameters,
	zeroAddress,
	type Address,
	type Hex
} from 'viem'
import { baseSepolia, mainnet } from 'viem/chains'

/** The coupon signer whose private key is committed in `src/Constants.sol`. */
export const TEST_SIGNER: Address = '0x8E72b7568738da52ca3DCd9b24E178127A4E7d37'

/** What `PUBLIC_NETWORK` selects. Every other network value is a build variable. */
export const NETWORKS = {
	'base-sepolia': {
		chain: baseSepolia,
		tokenName: 'mock HOT',
		networkName: 'Base Sepolia',
		explorer: 'https://sepolia.basescan.org',
		faucet: true,
		rpcSecret: 'BASE_SEPOLIA_RPC_URL',
		addToWallet: {
			chainName: 'Base Sepolia',
			nativeCurrency: { name: 'Sepolia ETH', symbol: 'ETH', decimals: 18 },
			rpcUrls: ['https://sepolia.base.org'],
			blockExplorerUrls: ['https://sepolia.basescan.org']
		}
	},
	mainnet: {
		chain: mainnet,
		tokenName: 'HOT',
		networkName: 'Ethereum',
		explorer: 'https://etherscan.io',
		faucet: false,
		rpcSecret: 'ETH_RPC_URL',
		addToWallet: undefined
	}
} as const

export type NetworkName = keyof typeof NETWORKS

/** `HOLO_VAULT_ID` in src/Constants.sol, on both networks. */
export const HOLO_VAULT_ID: Hex =
	'0xeede83a4244afae4fef82c8f5b97df1f18bfe3193e65ba02052e37f6171b334b'

/** `CLAIM_ORDER_NONCE` in src/Constants.sol: one claim order per signer. */
export const CLAIM_ORDER_NONCE: Hex = `0x${'0'.repeat(64)}`

/**
 * `CLAIM_IO_RATIO` in src/Constants.sol: the claim order's io-ratio, `1e-30` in
 * src/holo-claim.rain, as the decimal float the parser makes of it (coefficient 1,
 * exponent -30). A claim passes it as its maximum ratio.
 */
export const CLAIM_IO_RATIO: Hex =
	'0xffffffe200000000000000000000000000000000000000000000000000000001'

const ORDER_V4 = parseAbiParameters(
	'(address owner, (address interpreter, address store, bytes bytecode) evaluable, (address token, bytes32 vaultId)[] validInputs, (address token, bytes32 vaultId)[] validOutputs, bytes32 nonce)'
)

type ClaimValues = {
	lockVaultAddress: Address
	tokenAddress: Address
	claimOrder: { interpreter: Address; store: Address; bytecode: Hex; inputToken: Address }
}

/**
 * The OrderV4 the vault added and takeOrders4 names, as script/ClaimOrderScript.sol
 * adds it: its bytecode is the parsed claim expression, and both IOs pay out of
 * HOLO_VAULT_ID.
 */
export function claimOrderStruct({ lockVaultAddress, tokenAddress, claimOrder }: ClaimValues) {
	return {
		owner: lockVaultAddress,
		evaluable: {
			interpreter: claimOrder.interpreter,
			store: claimOrder.store,
			bytecode: claimOrder.bytecode
		},
		validInputs: [{ token: claimOrder.inputToken, vaultId: HOLO_VAULT_ID }],
		validOutputs: [{ token: tokenAddress, vaultId: HOLO_VAULT_ID }],
		nonce: CLAIM_ORDER_NONCE
	}
}

/** The order's hash as Raindex V6 hashes it: keccak256 of abi.encode(OrderV4). */
export const orderHashOf = (values: ClaimValues): Hex =>
	keccak256(encodeAbiParameters(ORDER_V4, [claimOrderStruct(values)]))

export type BridgeConfig = (typeof NETWORKS)[NetworkName] & {
	network: NetworkName
	tokenAddress: Address
	lockVaultAddress: Address
	orderbookAddress: Address
	claimOrder: {
		orderHash: Hex
		/** The N signers the claim order lists, as the build names them. */
		signers: Address[]
		/** M: how many of them, each a different one, sign every coupon. */
		threshold: number
		interpreter: Address
		store: Address
		bytecode: Hex
		inputToken: Address
	}
}

const ADDRESS_VARIABLES = [
	'PUBLIC_TOKEN_ADDRESS',
	'PUBLIC_LOCK_VAULT_ADDRESS',
	'PUBLIC_ORDERBOOK_ADDRESS',
	'PUBLIC_CLAIM_INTERPRETER',
	'PUBLIC_CLAIM_STORE',
	'PUBLIC_CLAIM_INPUT_TOKEN'
] as const

/** The build variables the website reads, inlined at build time. */
export const BUILD_VARIABLES = [
	'PUBLIC_NETWORK',
	'PUBLIC_CLAIM_ORDER_HASH',
	'PUBLIC_CLAIM_BYTECODE',
	'PUBLIC_CLAIM_SIGNERS',
	'PUBLIC_CLAIM_THRESHOLD',
	...ADDRESS_VARIABLES
] as const

/**
 * Build variables the website no longer reads, and what replaced them. A build that
 * sets one fails, so a value meant for it is never silently ignored.
 */
export const REPLACED_VARIABLES = {
	PUBLIC_CLAIM_SIGNER: 'PUBLIC_CLAIM_SIGNERS and PUBLIC_CLAIM_THRESHOLD'
} as const

/**
 * The most signers a claim order lists: compose-rainlang.mjs writes one `any` input
 * per signer, and a Rainlang word takes at most 15.
 */
export const MAX_CLAIM_SIGNERS = 15

/**
 * The claim order's signers and threshold come as a pair: TestNet's are taken only
 * when neither is given, so one given alone never pairs with the other's default.
 */
const SIGNER_PAIR = ['PUBLIC_CLAIM_SIGNERS', 'PUBLIC_CLAIM_THRESHOLD']

type BuildEnv = Partial<Record<string, string>>

/**
 * TestNet's values: a base-sepolia build takes each one it is not given. They are
 * what is the same on every chain: Raindex V6, the Rainlang interpreter and store,
 * and the test signer. TestNet's mock HOT, lock vault and claim order are not
 * deployed on Base Sepolia yet, so a base-sepolia build names those as a mainnet
 * build does. The test signer alone signs TestNet's coupons, threshold 1. Mainnet has
 * no defaults.
 */
export const BASE_SEPOLIA_DEFAULTS: Partial<
	Record<Exclude<(typeof BUILD_VARIABLES)[number], 'PUBLIC_NETWORK'>, string>
> = {
	PUBLIC_ORDERBOOK_ADDRESS: '0x37FC0EFec37D19f8A221aa4F8F7600C9ba2AcD20',
	PUBLIC_CLAIM_SIGNERS: TEST_SIGNER,
	PUBLIC_CLAIM_THRESHOLD: '1',
	PUBLIC_CLAIM_INTERPRETER: '0x4c52eee7Fb6aeD0F1a30130d96d02409D9d886cf',
	PUBLIC_CLAIM_STORE: '0x1Aa775533E28B1D843e1A589034984E3a62005DC'
}

/**
 * `env` with TestNet's values for the network values a base-sepolia build is not
 * given, PUBLIC_NETWORK itself base-sepolia when unset. An empty value counts as
 * not given. PUBLIC_CLAIM_SIGNERS and PUBLIC_CLAIM_THRESHOLD are filled only when
 * neither is given. Returns the names it filled.
 */
export function withTestnetDefaults(env: BuildEnv): { env: BuildEnv; defaulted: string[] } {
	const given = (key: string) => (env[key] ? env[key] : undefined)
	const network = given('PUBLIC_NETWORK') ?? 'base-sepolia'
	const filled: BuildEnv = { ...env, PUBLIC_NETWORK: network }
	const defaulted = given('PUBLIC_NETWORK') ? [] : ['PUBLIC_NETWORK']
	if (network === 'base-sepolia') {
		const signersGiven = SIGNER_PAIR.some(key => given(key))
		for (const [key, value] of Object.entries(BASE_SEPOLIA_DEFAULTS)) {
			if (SIGNER_PAIR.includes(key) && signersGiven) continue
			if (!given(key)) {
				filled[key] = value
				defaulted.push(key)
			}
		}
	}
	return { env: filled, defaulted }
}

/**
 * The claim order's signers and threshold, or undefined after pushing each fault to
 * `faults`: 1 to MAX_CLAIM_SIGNERS nonzero addresses separated by commas, none listed
 * twice in any letter case, none the test signer on mainnet, and a threshold that is
 * a whole number from 1 to the signers listed.
 */
function parseSigners(env: BuildEnv, network: string | undefined, faults: string[]) {
	const listed = env.PUBLIC_CLAIM_SIGNERS
	const threshold = env.PUBLIC_CLAIM_THRESHOLD
	let signers: Address[] | undefined
	if (!listed) faults.push('PUBLIC_CLAIM_SIGNERS is required')
	else {
		const entries = listed.split(',')
		const malformed = entries.filter(s => !isAddress(s) || isAddressEqual(s, zeroAddress))
		const lower = entries.map(s => s.toLowerCase())
		const twice = [...new Set(lower.filter((s, i) => lower.indexOf(s) !== i))]
		if (malformed.length > 0) {
			faults.push(
				`PUBLIC_CLAIM_SIGNERS=${listed} lists ${malformed.map(s => `"${s}"`).join(', ')}, not a valid nonzero address: it takes addresses separated by commas`
			)
		} else if (entries.length > MAX_CLAIM_SIGNERS) {
			faults.push(
				`PUBLIC_CLAIM_SIGNERS lists ${entries.length} signers: a claim order takes 1 to ${MAX_CLAIM_SIGNERS}`
			)
		} else if (twice.length > 0) {
			faults.push(`PUBLIC_CLAIM_SIGNERS lists ${twice.join(', ')} twice`)
		} else signers = entries as Address[]
		if (network === 'mainnet' && lower.includes(TEST_SIGNER.toLowerCase())) {
			faults.push(
				`PUBLIC_CLAIM_SIGNERS lists the test signer ${TEST_SIGNER}, whose key is public: mainnet refuses it`
			)
		}
	}
	if (!threshold) faults.push('PUBLIC_CLAIM_THRESHOLD is required')
	else if (!/^[1-9][0-9]*$/.test(threshold)) {
		faults.push(`PUBLIC_CLAIM_THRESHOLD=${threshold} is not a whole number of signers from 1 up`)
	} else if (signers && Number(threshold) > signers.length) {
		faults.push(
			`PUBLIC_CLAIM_THRESHOLD=${threshold} is more than the ${signers.length} signers PUBLIC_CLAIM_SIGNERS lists`
		)
	} else if (signers) return { signers, threshold: Number(threshold) }
	return undefined
}

/**
 * The website's network values, or an error naming every build variable that is
 * missing or malformed, replaced, and the test signer on mainnet. A base-sepolia
 * build takes TestNet's value for any it is not given.
 */
export function parseBridgeConfig(given: BuildEnv): BridgeConfig {
	const { env } = withTestnetDefaults(given)
	const faults: string[] = []
	for (const [key, replacement] of Object.entries(REPLACED_VARIABLES)) {
		if (key in given) faults.push(`${key} is replaced by ${replacement}: unset it`)
	}
	const network = env.PUBLIC_NETWORK
	if (network !== 'base-sepolia' && network !== 'mainnet') {
		faults.push(`PUBLIC_NETWORK must be base-sepolia or mainnet, not ${network}`)
	}

	const addresses: Partial<Record<(typeof ADDRESS_VARIABLES)[number], Address>> = {}
	for (const key of ADDRESS_VARIABLES) {
		const value = env[key]
		if (!value) faults.push(`${key} is required`)
		else if (!isAddress(value) || isAddressEqual(value, zeroAddress)) {
			faults.push(`${key}=${value} is not a valid nonzero address`)
		} else addresses[key] = value
	}

	const orderHash = env.PUBLIC_CLAIM_ORDER_HASH
	if (!orderHash) faults.push('PUBLIC_CLAIM_ORDER_HASH is required')
	else if (!isHex(orderHash, { strict: true }) || orderHash.length !== 66) {
		faults.push(`PUBLIC_CLAIM_ORDER_HASH=${orderHash} is not a 32-byte hash`)
	}

	const bytecode = env.PUBLIC_CLAIM_BYTECODE
	if (!bytecode) faults.push('PUBLIC_CLAIM_BYTECODE is required')
	else if (!isHex(bytecode, { strict: true }) || bytecode.length % 2 !== 0 || bytecode.length < 4) {
		faults.push(`PUBLIC_CLAIM_BYTECODE=${bytecode} is not hex bytecode`)
	}

	const signers = parseSigners(env, network, faults)

	if (faults.length > 0 || !signers) {
		throw new Error(`Bridge build variables: ${faults.join('; ')}`)
	}
	const a = addresses as Record<(typeof ADDRESS_VARIABLES)[number], Address>
	const config: BridgeConfig = {
		...NETWORKS[network as NetworkName],
		network: network as NetworkName,
		tokenAddress: a.PUBLIC_TOKEN_ADDRESS,
		lockVaultAddress: a.PUBLIC_LOCK_VAULT_ADDRESS,
		orderbookAddress: a.PUBLIC_ORDERBOOK_ADDRESS,
		claimOrder: {
			orderHash: orderHash as Hex,
			signers: signers.signers,
			threshold: signers.threshold,
			interpreter: a.PUBLIC_CLAIM_INTERPRETER,
			store: a.PUBLIC_CLAIM_STORE,
			bytecode: bytecode as Hex,
			inputToken: a.PUBLIC_CLAIM_INPUT_TOKEN
		}
	}
	if (orderHashOf(config).toLowerCase() !== config.claimOrder.orderHash.toLowerCase()) {
		throw new Error(
			`Bridge build variables: PUBLIC_CLAIM_ORDER_HASH is not the hash of the order that PUBLIC_LOCK_VAULT_ADDRESS, PUBLIC_TOKEN_ADDRESS, PUBLIC_CLAIM_INTERPRETER, PUBLIC_CLAIM_STORE, PUBLIC_CLAIM_BYTECODE and PUBLIC_CLAIM_INPUT_TOKEN describe`
		)
	}
	return config
}
