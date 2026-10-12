import { describe, expect, it } from 'vitest'
import { zeroAddress } from 'viem'
import {
	BASE_SEPOLIA_DEFAULTS,
	BUILD_VARIABLES,
	TEST_SIGNER,
	orderHashOf,
	parseBridgeConfig,
	withTestnetDefaults
} from './network'
import { BASE_SEPOLIA_BUILD, MAINNET_BUILD, withOtherStore } from './testing/builds'

const without = (build: Record<string, string>, key: string) => {
	const rest = { ...build }
	delete rest[key]
	return rest
}

// Anvil's third, fourth and fifth accounts.
const SIGNER_A = '0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC'
const SIGNER_B = '0x90F79bf6EB2c4f870365E785982E1f101E93b906'
const SIGNER_C = '0x15d34AAf54267DB7D7c367839AAf71A00a2C6A65'
const TWO_OF_THREE = {
	PUBLIC_CLAIM_SIGNERS: `${SIGNER_A},${SIGNER_B},${SIGNER_C}`,
	PUBLIC_CLAIM_THRESHOLD: '2'
}

/** The build variables TestNet has no default for: its own deploy's values. */
const DEPLOYED = BUILD_VARIABLES.filter(
	key => key !== 'PUBLIC_NETWORK' && !(key in BASE_SEPOLIA_DEFAULTS)
)

describe('parseBridgeConfig', () => {
	it('reads a TestNet build: Base Sepolia, mock HOT, its explorer, the faucet', () => {
		const config = parseBridgeConfig(BASE_SEPOLIA_BUILD)

		expect(config.network).toBe('base-sepolia')
		expect(config.chain.id).toBe(84532)
		expect(config.tokenName).toBe('mock HOT')
		expect(config.networkName).toBe('Base Sepolia')
		expect(config.explorer).toBe('https://sepolia.basescan.org')
		expect(config.faucet).toBe(true)
		expect(config.rpcSecret).toBe('BASE_SEPOLIA_RPC_URL')
		expect(config.addToWallet?.blockExplorerUrls).toEqual(['https://sepolia.basescan.org'])
		expect(config.tokenAddress).toBe(BASE_SEPOLIA_BUILD.PUBLIC_TOKEN_ADDRESS)
		expect(config.lockVaultAddress).toBe(BASE_SEPOLIA_BUILD.PUBLIC_LOCK_VAULT_ADDRESS)
		expect(config.orderbookAddress).toBe(BASE_SEPOLIA_BUILD.PUBLIC_ORDERBOOK_ADDRESS)
		expect(config.claimOrder).toEqual({
			orderHash: BASE_SEPOLIA_BUILD.PUBLIC_CLAIM_ORDER_HASH,
			signers: [TEST_SIGNER],
			threshold: 1,
			interpreter: BASE_SEPOLIA_BUILD.PUBLIC_CLAIM_INTERPRETER,
			store: BASE_SEPOLIA_BUILD.PUBLIC_CLAIM_STORE,
			bytecode: BASE_SEPOLIA_BUILD.PUBLIC_CLAIM_BYTECODE,
			inputToken: BASE_SEPOLIA_BUILD.PUBLIC_CLAIM_INPUT_TOKEN
		})
	})

	it('reads a MainNet build: Ethereum, HOT, its explorer, no faucet', () => {
		const config = parseBridgeConfig(MAINNET_BUILD)

		expect(config.network).toBe('mainnet')
		expect(config.chain.id).toBe(1)
		expect(config.tokenName).toBe('HOT')
		expect(config.networkName).toBe('Ethereum')
		expect(config.explorer).toBe('https://etherscan.io')
		expect(config.faucet).toBe(false)
		expect(config.rpcSecret).toBe('ETH_RPC_URL')
		expect(config.addToWallet).toBeUndefined()
		expect(config.claimOrder.signers).toEqual([MAINNET_BUILD.PUBLIC_CLAIM_SIGNERS])
		expect(config.claimOrder.threshold).toBe(1)
		expect(config.claimOrder.inputToken).toBe(MAINNET_BUILD.PUBLIC_CLAIM_INPUT_TOKEN)
	})

	it('hashes the claim order as Raindex V6 does: the order hash test vector', () => {
		// test/TestCouponSignature.t.sol and bridge-orchestrator/src/preflight.rs hash the same order.
		expect(
			orderHashOf({
				lockVaultAddress: '0xE3E064e3C2EEf66cb93dA8D8114F5084E92F48D6',
				tokenAddress: '0x6c6EE5e31d828De241282B9606C8e98Ea48526E2',
				claimOrder: {
					interpreter: '0x4c52eee7Fb6aeD0F1a30130d96d02409D9d886cf',
					store: '0x1Aa775533E28B1D843e1A589034984E3a62005DC',
					bytecode: '0x00ab',
					inputToken: '0x1234567890123456789012345678901234567890'
				}
			})
		).toBe('0xaa24ef105ecbfc39695b240de6baeb09278fd4ebf75674b29bcbd2c7ef72ff0b')
	})

	it('reads a build with no network as TestNet, and takes TestNet values for what is the same on every chain', () => {
		const testnet = parseBridgeConfig(BASE_SEPOLIA_BUILD)
		const deployed = Object.fromEntries(DEPLOYED.map(key => [key, BASE_SEPOLIA_BUILD[key]]))

		expect(parseBridgeConfig(deployed)).toEqual(testnet)
		expect(parseBridgeConfig({ ...deployed, PUBLIC_NETWORK: '', PUBLIC_CLAIM_STORE: '' })).toEqual(
			testnet
		)
		expect(withTestnetDefaults(deployed).defaulted).toEqual([
			'PUBLIC_NETWORK',
			'PUBLIC_ORDERBOOK_ADDRESS',
			'PUBLIC_CLAIM_SIGNERS',
			'PUBLIC_CLAIM_THRESHOLD',
			'PUBLIC_CLAIM_INTERPRETER',
			'PUBLIC_CLAIM_STORE'
		])
	})

	it('refuses a TestNet build missing its own deploy, naming each variable: none is deployed on Base Sepolia yet', () => {
		expect(() => parseBridgeConfig({})).toThrow(
			'Bridge build variables: PUBLIC_TOKEN_ADDRESS is required; PUBLIC_LOCK_VAULT_ADDRESS is required; PUBLIC_CLAIM_INPUT_TOKEN is required; PUBLIC_CLAIM_ORDER_HASH is required; PUBLIC_CLAIM_BYTECODE is required'
		)
		for (const key of DEPLOYED) {
			expect(() => parseBridgeConfig(without(BASE_SEPOLIA_BUILD, key))).toThrow(
				`${key} is required`
			)
		}
	})

	it('refuses a mainnet build missing any variable, naming it, with no TestNet value', () => {
		for (const key of BUILD_VARIABLES.filter(key => key !== 'PUBLIC_NETWORK')) {
			expect(() => parseBridgeConfig(without(MAINNET_BUILD, key))).toThrow(`${key} is required`)
			expect(() => parseBridgeConfig({ ...MAINNET_BUILD, [key]: '' })).toThrow(`${key} is required`)
		}
	})

	it.each([
		['PUBLIC_NETWORK', 'sepolia', 'PUBLIC_NETWORK must be base-sepolia or mainnet, not sepolia'],
		[
			'PUBLIC_TOKEN_ADDRESS',
			'0x1234',
			'PUBLIC_TOKEN_ADDRESS=0x1234 is not a valid nonzero address'
		],
		[
			'PUBLIC_LOCK_VAULT_ADDRESS',
			'0x47fa611Bb47f2172b99135D6c00dC5555ca230C1',
			'is not a valid nonzero address'
		],
		[
			'PUBLIC_CLAIM_INPUT_TOKEN',
			'0x0000000000000000000000000000000000000000',
			'is not a valid nonzero address'
		],
		[
			'PUBLIC_CLAIM_ORDER_HASH',
			'0x1c1fe2',
			'PUBLIC_CLAIM_ORDER_HASH=0x1c1fe2 is not a 32-byte hash'
		],
		['PUBLIC_CLAIM_BYTECODE', '0x', 'PUBLIC_CLAIM_BYTECODE=0x is not hex bytecode'],
		['PUBLIC_CLAIM_BYTECODE', '0xabc', 'PUBLIC_CLAIM_BYTECODE=0xabc is not hex bytecode'],
		['PUBLIC_CLAIM_BYTECODE', 'abcd', 'PUBLIC_CLAIM_BYTECODE=abcd is not hex bytecode']
	])('refuses a malformed %s', (key, value, fault) => {
		expect(() => parseBridgeConfig({ ...MAINNET_BUILD, [key]: value })).toThrow(fault)
	})

	it.each([
		['base-sepolia', BASE_SEPOLIA_BUILD],
		['mainnet', MAINNET_BUILD]
	])('refuses a %s build whose order does not hash to its order hash', (_, build) => {
		const stale = { ...build, PUBLIC_CLAIM_STORE: '0x1111111111111111111111111111111111111111' }

		expect(() => parseBridgeConfig(stale)).toThrow(
			'PUBLIC_CLAIM_ORDER_HASH is not the hash of the order'
		)
		expect(() =>
			parseBridgeConfig({ ...build, PUBLIC_LOCK_VAULT_ADDRESS: MAINNET_BUILD.PUBLIC_TOKEN_ADDRESS })
		).toThrow('PUBLIC_CLAIM_ORDER_HASH is not the hash of the order')
		expect(() => parseBridgeConfig({ ...build, PUBLIC_CLAIM_BYTECODE: '0x00ac' })).toThrow(
			'PUBLIC_CLAIM_ORDER_HASH is not the hash of the order'
		)
		expect(parseBridgeConfig(withOtherStore(build)).claimOrder.store).toBe(
			'0x1111111111111111111111111111111111111111'
		)
	})

	it('names every fault in one error', () => {
		expect(() =>
			parseBridgeConfig({
				...without(MAINNET_BUILD, 'PUBLIC_CLAIM_STORE'),
				PUBLIC_NETWORK: 'goerli'
			})
		).toThrow(
			'Bridge build variables: PUBLIC_NETWORK must be base-sepolia or mainnet, not goerli; PUBLIC_CLAIM_STORE is required'
		)
	})

	it('refuses the test signer anywhere in a mainnet list, in any case, and takes it on base-sepolia', () => {
		for (const signer of [TEST_SIGNER, TEST_SIGNER.toLowerCase()]) {
			for (const signers of [signer, `${SIGNER_A},${signer},${SIGNER_B}`]) {
				expect(() =>
					parseBridgeConfig({ ...MAINNET_BUILD, PUBLIC_CLAIM_SIGNERS: signers })
				).toThrow(
					`PUBLIC_CLAIM_SIGNERS lists the test signer ${TEST_SIGNER}, whose key is public: mainnet refuses it`
				)
				expect(
					parseBridgeConfig({ ...BASE_SEPOLIA_BUILD, PUBLIC_CLAIM_SIGNERS: signers }).network
				).toBe('base-sepolia')
			}
		}
	})
})

describe('parseBridgeConfig, the claim signers', () => {
	it.each([
		['base-sepolia', BASE_SEPOLIA_BUILD],
		['mainnet', MAINNET_BUILD]
	])('reads a %s order of 2 of 3 signers, as the deploy record lists them', (_, build) => {
		const config = parseBridgeConfig({ ...build, ...TWO_OF_THREE })

		expect(config.claimOrder.signers).toEqual([SIGNER_A, SIGNER_B, SIGNER_C])
		expect(config.claimOrder.threshold).toBe(2)
	})

	it('reads 15 signers, the most a claim order lists, and a threshold of all of them', () => {
		const fifteen = Array.from(
			{ length: 15 },
			(_, i) => `0x${(i + 1).toString(16).padStart(40, '0')}`
		)

		const config = parseBridgeConfig({
			...MAINNET_BUILD,
			PUBLIC_CLAIM_SIGNERS: fifteen.join(','),
			PUBLIC_CLAIM_THRESHOLD: '15'
		})

		expect(config.claimOrder.signers).toEqual(fifteen)
		expect(config.claimOrder.threshold).toBe(15)
	})

	it.each([
		[
			'an entry that is not an address',
			`${SIGNER_A},0x1234`,
			'"0x1234", not a valid nonzero address'
		],
		[
			'the zero address',
			`${SIGNER_A},${zeroAddress}`,
			`"${zeroAddress}", not a valid nonzero address`
		],
		['an empty entry', `${SIGNER_A},,${SIGNER_B}`, '"", not a valid nonzero address'],
		['a trailing comma', `${SIGNER_A},`, '"", not a valid nonzero address'],
		[
			'a space after a comma',
			`${SIGNER_A}, ${SIGNER_B}`,
			`" ${SIGNER_B}", not a valid nonzero address`
		],
		[
			'16 signers',
			Array.from({ length: 16 }, (_, i) => `0x${(i + 1).toString(16).padStart(40, '0')}`).join(','),
			'PUBLIC_CLAIM_SIGNERS lists 16 signers: a claim order takes 1 to 15'
		],
		[
			'one signer twice, in another letter case',
			`${SIGNER_A},${SIGNER_B},${SIGNER_A.toLowerCase()}`,
			`PUBLIC_CLAIM_SIGNERS lists ${SIGNER_A.toLowerCase()} twice`
		]
	])('refuses a list with %s', (_, signers, fault) => {
		for (const build of [BASE_SEPOLIA_BUILD, MAINNET_BUILD]) {
			expect(() => parseBridgeConfig({ ...build, PUBLIC_CLAIM_SIGNERS: signers })).toThrow(fault)
		}
	})

	it.each([
		['0', 'PUBLIC_CLAIM_THRESHOLD=0 is not a whole number of signers from 1 up'],
		['-1', 'PUBLIC_CLAIM_THRESHOLD=-1 is not a whole number of signers from 1 up'],
		['1.5', 'PUBLIC_CLAIM_THRESHOLD=1.5 is not a whole number of signers from 1 up'],
		['two', 'PUBLIC_CLAIM_THRESHOLD=two is not a whole number of signers from 1 up'],
		['02', 'PUBLIC_CLAIM_THRESHOLD=02 is not a whole number of signers from 1 up'],
		['4', 'PUBLIC_CLAIM_THRESHOLD=4 is more than the 3 signers PUBLIC_CLAIM_SIGNERS lists']
	])('refuses the threshold %s', (threshold, fault) => {
		for (const build of [BASE_SEPOLIA_BUILD, MAINNET_BUILD]) {
			expect(() =>
				parseBridgeConfig({ ...build, ...TWO_OF_THREE, PUBLIC_CLAIM_THRESHOLD: threshold })
			).toThrow(fault)
		}
	})

	it("takes TestNet's signer and threshold only when neither is given, so a list never pairs with threshold 1 unasked", () => {
		const testnet = without(
			without(BASE_SEPOLIA_BUILD, 'PUBLIC_CLAIM_SIGNERS'),
			'PUBLIC_CLAIM_THRESHOLD'
		)

		expect(parseBridgeConfig(testnet).claimOrder).toMatchObject({
			signers: [TEST_SIGNER],
			threshold: 1
		})
		expect(() =>
			parseBridgeConfig({ ...testnet, PUBLIC_CLAIM_SIGNERS: TWO_OF_THREE.PUBLIC_CLAIM_SIGNERS })
		).toThrow('PUBLIC_CLAIM_THRESHOLD is required')
		expect(() => parseBridgeConfig({ ...testnet, PUBLIC_CLAIM_THRESHOLD: '1' })).toThrow(
			'PUBLIC_CLAIM_SIGNERS is required'
		)
		expect(
			withTestnetDefaults({ ...testnet, PUBLIC_CLAIM_THRESHOLD: '1' }).defaulted
		).not.toContain('PUBLIC_CLAIM_SIGNERS')
	})

	it.each([
		['base-sepolia', BASE_SEPOLIA_BUILD],
		['mainnet', MAINNET_BUILD]
	])(
		'refuses a %s build that still sets PUBLIC_CLAIM_SIGNER, naming what replaced it',
		(_, build) => {
			for (const value of [SIGNER_A, '']) {
				expect(() => parseBridgeConfig({ ...build, PUBLIC_CLAIM_SIGNER: value })).toThrow(
					'PUBLIC_CLAIM_SIGNER is replaced by PUBLIC_CLAIM_SIGNERS and PUBLIC_CLAIM_THRESHOLD'
				)
			}
		}
	)

	it('names every signer fault in one error, with the others', () => {
		expect(() =>
			parseBridgeConfig({
				...without(MAINNET_BUILD, 'PUBLIC_CLAIM_STORE'),
				PUBLIC_CLAIM_SIGNER: SIGNER_A,
				PUBLIC_CLAIM_SIGNERS: `${SIGNER_A},${TEST_SIGNER},${SIGNER_A}`,
				PUBLIC_CLAIM_THRESHOLD: '0'
			})
		).toThrow(
			`Bridge build variables: PUBLIC_CLAIM_SIGNER is replaced by PUBLIC_CLAIM_SIGNERS and PUBLIC_CLAIM_THRESHOLD: unset it; PUBLIC_CLAIM_STORE is required; PUBLIC_CLAIM_SIGNERS lists ${SIGNER_A.toLowerCase()} twice; PUBLIC_CLAIM_SIGNERS lists the test signer ${TEST_SIGNER}, whose key is public: mainnet refuses it; PUBLIC_CLAIM_THRESHOLD=0 is not a whole number of signers from 1 up`
		)
	})
})
