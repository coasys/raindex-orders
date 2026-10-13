import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import {
	encodeAbiParameters,
	encodePacked,
	hashMessage,
	keccak256,
	type Address,
	type Hex
} from 'viem'
import { generatePrivateKey, privateKeyToAccount } from 'viem/accounts'
import { asBuild, MAINNET_BUILD, BASE_SEPOLIA_BUILD } from '$lib/testing/builds'
import { TESTNET_COUPONS } from './fixtures'
import { fakeCache, fakeRpc, type ContractSigner } from './fakeRpc'

const env = vi.hoisted(() => ({}) as Record<string, string | undefined>)
vi.mock('$env/dynamic/private', () => ({ env }))

const VAULT_ID = 0xeede83a4244afae4fef82c8f5b97df1f18bfe3193e65ba02052e37f6171b334bn
// Anvil's third account: MAINNET_BUILD's claim signer. Its fourth: a second key signer.
const KEY_SIGNER = '0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a'
const SECOND_KEY = '0x7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6'
const OWNERS = [
	'0x47e179ec197488593b187f80a00eb0da91f1b9d0b13f8733639f19c30a34926a',
	'0x8b3a350cf5c34c9194ca85829a2df0ec3153be0318b5e2d3348e872092edffba'
] as const
const SAFE = '0x5afe5afe5afe5afe5afe5afe5afe5afe5afe5afe'
const NOW = 1_776_400_000
const SAFE_BUILD = { ...MAINNET_BUILD, PUBLIC_CLAIM_SIGNERS: SAFE }
const address = (key: Hex) => privateKeyToAccount(key).address
/** A 2-of-3 claim order: two keys and the Safe. */
const TWO_OF_THREE = {
	...MAINNET_BUILD,
	PUBLIC_CLAIM_SIGNERS: [address(KEY_SIGNER), address(SECOND_KEY), SAFE].join(','),
	PUBLIC_CLAIM_THRESHOLD: '2'
}

type Build = typeof MAINNET_BUILD

let cache: ReturnType<typeof fakeCache>

/** The amount word of one HOT: the wei with exponent -18. */
const ONE_HOT = ((2n ** 32n - 18n) << 224n) | (10n ** 18n)

function context(build: Build, nonce: bigint): bigint[] {
	return [
		0x1111111111111111111111111111111111111111n,
		ONE_HOT,
		BigInt(NOW + 7 * 24 * 60 * 60),
		BigInt(build.PUBLIC_CLAIM_ORDER_HASH),
		BigInt(build.PUBLIC_LOCK_VAULT_ADDRESS),
		BigInt(build.PUBLIC_ORDERBOOK_ADDRESS),
		BigInt(build.PUBLIC_TOKEN_ADDRESS),
		VAULT_ID,
		nonce
	]
}

const contextHash = (words: bigint[]) =>
	keccak256(encodePacked(Array<'uint256'>(9).fill('uint256'), words))

const coupon = (signer: string, signature: Hex, words: bigint[]) =>
	[signer, signature, ...words.map(String)].join(',')

/** A seat: a key signs as itself, or names `signer` (a key signs naming another). */
type SeatOf = { key: Hex; signer?: string } | { safe: readonly Hex[] }

/** A coupon of `seats`, each signing `words`, in order. */
async function seated(words: bigint[], seats: SeatOf[]) {
	const hash = contextHash(words)
	const fields = await Promise.all(
		seats.map(async seat => {
			if ('safe' in seat) {
				const parts = await Promise.all(
					seat.safe.map(key => privateKeyToAccount(key).signMessage({ message: { raw: hash } }))
				)
				return [SAFE, `0x${parts.map(s => s.slice(2)).join('')}`]
			}
			const account = privateKeyToAccount(seat.key)
			const signature = await account.signMessage({ message: { raw: hash } })
			return [seat.signer ?? account.address, signature]
		})
	)
	return [...fields.flat(), ...words.map(String)].join(',')
}

/** A coupon signed by `key`, as bridge-orchestrator signs one. */
async function keySigned(build: Build, key: Hex, nonce: bigint) {
	const words = context(build, nonce)
	const account = privateKeyToAccount(key)
	const signature = await account.signMessage({ message: { raw: contextHash(words) } })
	return coupon(account.address, signature, words)
}

/** A coupon naming the Safe, carrying `owners` 65-byte signatures. */
async function safeSigned(nonce: bigint, owners: readonly Hex[] = OWNERS) {
	const words = context(SAFE_BUILD, nonce)
	const signatures = await Promise.all(
		owners.map(key =>
			privateKeyToAccount(key).signMessage({ message: { raw: contextHash(words) } })
		)
	)
	return coupon(SAFE, `0x${signatures.map(s => s.slice(2)).join('')}`, words)
}

/** The Safe, accepting any signature two owners long. */
const SAFE_SIGNER: ContractSigner = {
	address: SAFE,
	accepts: (_hash, signature) => signature.length === 2 + 2 * 130
}

/** The chain `build` names, where the Safe accepts any signature two owners long. */
function chain(
	build: Build,
	chainId: bigint,
	flags = new Map<bigint, bigint>(),
	contractSigners = [SAFE_SIGNER]
) {
	const namespace = BigInt(
		keccak256(
			encodeAbiParameters(
				[{ type: 'address' }, { type: 'address' }],
				[build.PUBLIC_LOCK_VAULT_ADDRESS as Address, build.PUBLIC_ORDERBOOK_ADDRESS as Address]
			)
		)
	)
	return fakeRpc({
		chainId,
		block: 24_000_000n,
		timestamp: NOW,
		store: build.PUBLIC_CLAIM_STORE.toLowerCase(),
		namespace,
		flags,
		contractSigners
	})
}

const nonceKey = (build: Build, nonce: bigint) =>
	BigInt(
		keccak256(encodePacked(['uint256', 'uint256'], [BigInt(build.PUBLIC_CLAIM_ORDER_HASH), nonce]))
	)

type Post = (typeof import('./+server'))['POST']

const load = async (build: Build) => (await asBuild(build, () => import('./+server'))).POST

async function post(build: Build, coupons: string[]) {
	return postTo(await load(build), coupons)
}

async function postTo(POST: Post, coupons: string[]) {
	const response = await POST({
		request: new Request('http://localhost/api/coupon-status', {
			method: 'POST',
			headers: { 'Content-Type': 'application/json' },
			body: JSON.stringify({ coupons })
		}),
		platform: { caches: { open: cache.open } }
	} as unknown as Parameters<typeof POST>[0])
	return { response, body: await response.json() }
}

const statuses = (body: { results: { status: string }[] }) => body.results.map(r => r.status)

beforeEach(() => {
	for (const key of Object.keys(env)) delete env[key]
	cache = fakeCache()
	vi.useFakeTimers({ toFake: ['Date'] })
	vi.setSystemTime(NOW * 1000)
	vi.spyOn(console, 'error').mockImplementation(() => {})
})

afterEach(() => {
	vi.useRealTimers()
	vi.unstubAllGlobals()
	vi.restoreAllMocks()
})

describe('a mainnet build', () => {
	it('reads Ethereum through ETH_RPC_URL and reports chain 1', async () => {
		env.ETH_RPC_URL = 'https://eth.rpc.test/key'
		const rpc = chain(MAINNET_BUILD, 1n, new Map([[nonceKey(MAINNET_BUILD, 1n), 1n]]))

		const { response, body } = await post(MAINNET_BUILD, [
			await keySigned(MAINNET_BUILD, KEY_SIGNER, 1n),
			await keySigned(MAINNET_BUILD, KEY_SIGNER, 2n)
		])

		expect(response.status).toBe(200)
		expect(body.chainId).toBe(1)
		expect(statuses(body)).toEqual(['redeemed', 'unredeemed'])
		expect(rpc.fetch).toHaveBeenCalledTimes(1)
		expect(rpc.fetch.mock.calls[0][0]).toBe('https://eth.rpc.test/key')
	})

	it('refuses the read, and caches nothing, when the RPC answers for Base Sepolia', async () => {
		env.ETH_RPC_URL = 'https://eth.rpc.test/key'
		chain(MAINNET_BUILD, 84532n, new Map([[nonceKey(MAINNET_BUILD, 1n), 1n]]))

		const { response } = await post(MAINNET_BUILD, [await keySigned(MAINNET_BUILD, KEY_SIGNER, 1n)])

		expect(response.status).toBe(502)
		expect(cache.store.put).not.toHaveBeenCalled()
	})

	it('never reads through BASE_SEPOLIA_RPC_URL', async () => {
		env.BASE_SEPOLIA_RPC_URL = 'https://base-sepolia.rpc.test/key'
		const rpc = chain(MAINNET_BUILD, 1n)

		const { response } = await post(MAINNET_BUILD, [await keySigned(MAINNET_BUILD, KEY_SIGNER, 1n)])

		expect(response.status).toBe(502)
		expect(rpc.fetch).not.toHaveBeenCalled()
	})

	it('answers invalid for a TestNet coupon, signed by the test signer, with no RPC call', async () => {
		env.ETH_RPC_URL = 'https://eth.rpc.test/key'
		const rpc = chain(MAINNET_BUILD, 1n)

		const { body } = await post(MAINNET_BUILD, [TESTNET_COUPONS[0]])

		expect(statuses(body)).toEqual(['invalid'])
		expect(rpc.fetch).not.toHaveBeenCalled()
	})
})

describe('a base-sepolia build', () => {
	it('never reads through ETH_RPC_URL', async () => {
		env.ETH_RPC_URL = 'https://eth.rpc.test/key'
		const rpc = chain(BASE_SEPOLIA_BUILD, 84532n)

		const { response } = await post(BASE_SEPOLIA_BUILD, [TESTNET_COUPONS[0]])

		expect(response.status).toBe(502)
		expect(rpc.fetch).not.toHaveBeenCalled()
	})
})

describe('a Safe as the claim signer', () => {
	beforeEach(() => {
		env.ETH_RPC_URL = 'https://eth.rpc.test/key'
	})

	it('is asked, in the one eth_call, whether it signed the digest the orderbook checks', async () => {
		const rpc = chain(SAFE_BUILD, 1n, new Map([[nonceKey(SAFE_BUILD, 1n), 1n]]))
		const signed = await safeSigned(1n)

		const { body } = await post(SAFE_BUILD, [signed, await safeSigned(2n)])

		expect(statuses(body)).toEqual(['redeemed', 'unredeemed'])
		expect(rpc.requests).toHaveLength(1)
		expect(rpc.signatureChecks).toHaveLength(2)
		const [check] = rpc.signatureChecks
		expect(check.signer).toBe(SAFE)
		expect(check.hash).toBe(hashMessage({ raw: contextHash(context(SAFE_BUILD, 1n)) }))
		expect(check.signature).toBe(signed.split(',')[1])
		expect(check.accepted).toBe(true)
	})

	it('answers invalid for a signature it refuses, and checks it again next time', async () => {
		const rpc = chain(SAFE_BUILD, 1n)
		const refused = await safeSigned(1n, [...OWNERS, OWNERS[0]])

		expect(statuses((await post(SAFE_BUILD, [refused])).body)).toEqual(['invalid'])
		expect(statuses((await post(SAFE_BUILD, [refused])).body)).toEqual(['invalid'])

		expect(rpc.signatureChecks.map(c => c.accepted)).toEqual([false, false])
		expect(cache.store.put).not.toHaveBeenCalled()
	})

	it('answers a redeemed coupon it accepted from the cache, with no RPC call', async () => {
		const rpc = chain(SAFE_BUILD, 1n, new Map([[nonceKey(SAFE_BUILD, 1n), 1n]]))
		const signed = await safeSigned(1n)
		await post(SAFE_BUILD, [signed])

		const { body } = await post(SAFE_BUILD, [signed])

		expect(statuses(body)).toEqual(['redeemed'])
		expect(body.block).toBeNull()
		expect(rpc.requests).toHaveLength(1)
	})

	it('answers invalid, with no RPC call, for one owner signature or more than 20', async () => {
		const rpc = chain(SAFE_BUILD, 1n)
		const words = context(SAFE_BUILD, 1n)
		const one = await safeSigned(1n, [OWNERS[0]])
		const tooMany = coupon(SAFE, `0x${'11'.repeat(21 * 65)}`, words)

		const { body } = await post(SAFE_BUILD, [one, tooMany])

		expect(statuses(body)).toEqual(['invalid', 'invalid'])
		expect(rpc.fetch).not.toHaveBeenCalled()
	})

	it('checks a signature of 20 owners on chain', async () => {
		const rpc = chain(SAFE_BUILD, 1n)

		await post(SAFE_BUILD, [await safeSigned(1n, Array(20).fill(OWNERS[0]))])

		expect(rpc.signatureChecks).toHaveLength(1)
	})

	it('answers invalid, with no RPC call, for an owner part that would call another contract', async () => {
		const rpc = chain(SAFE_BUILD, 1n)
		const signed = await safeSigned(1n)
		const contractPart = `${signed.split(',')[1].slice(0, -2)}00`

		const { body } = await post(SAFE_BUILD, [
			coupon(SAFE, contractPart as Hex, context(SAFE_BUILD, 1n))
		])

		expect(statuses(body)).toEqual(['invalid'])
		expect(rpc.fetch).not.toHaveBeenCalled()
	})

	it('stops asking a claim signer with no code for 10 minutes once it has found none', async () => {
		const rpc = chain(MAINNET_BUILD, 1n)
		const POST = await load(MAINNET_BUILD)
		const words = (nonce: bigint) => context(MAINNET_BUILD, nonce)
		const signer = privateKeyToAccount(KEY_SIGNER)
		const twice = async (nonce: bigint) => {
			const signature = await signer.signMessage({ message: { raw: contextHash(words(nonce)) } })
			return coupon(signer.address, `${signature}${signature.slice(2)}`, words(nonce))
		}

		const first = await postTo(POST, [await twice(1n)])
		const second = await postTo(POST, [await twice(2n)])

		expect(statuses(first.body)).toEqual(['invalid'])
		expect(statuses(second.body)).toEqual(['invalid'])
		expect(rpc.signatureChecks).toEqual([expect.objectContaining({ accepted: false })])
		expect(rpc.fetch).toHaveBeenCalledTimes(1)
		expect(console.error).toHaveBeenCalledWith(
			expect.stringContaining('gave no isValidSignature answer')
		)

		vi.setSystemTime((NOW + 10 * 60) * 1000)
		await postTo(POST, [await twice(4n)])
		expect(rpc.signatureChecks).toHaveLength(2)
		vi.setSystemTime(NOW * 1000)
		expect(
			statuses((await postTo(POST, [await keySigned(MAINNET_BUILD, KEY_SIGNER, 3n)])).body)
		).toEqual(['unredeemed'])
	})
})

describe('a 2-of-3 claim order', () => {
	const words = (nonce: bigint) => context(TWO_OF_THREE, nonce)
	const A: SeatOf = { key: KEY_SIGNER }
	const B: SeatOf = { key: SECOND_KEY }
	const SAFE_SEAT: SeatOf = { safe: OWNERS }

	beforeEach(() => {
		env.ETH_RPC_URL = 'https://eth.rpc.test/key'
	})

	it('reads a coupon two listed keys signed, in either order, with no contract asked', async () => {
		const rpc = chain(TWO_OF_THREE, 1n, new Map([[nonceKey(TWO_OF_THREE, 1n), 1n]]))

		const { body } = await post(TWO_OF_THREE, [
			await seated(words(1n), [A, B]),
			await seated(words(2n), [B, A])
		])

		expect(statuses(body)).toEqual(['redeemed', 'unredeemed'])
		expect(rpc.requests).toHaveLength(1)
		expect(rpc.signatureChecks).toEqual([])
	})

	it('asks the Safe, in the one eth_call, for its seat beside a key', async () => {
		const rpc = chain(TWO_OF_THREE, 1n)
		const signed = await seated(words(1n), [A, SAFE_SEAT])

		const { body } = await post(TWO_OF_THREE, [signed, await seated(words(2n), [SAFE_SEAT, B])])

		expect(statuses(body)).toEqual(['unredeemed', 'unredeemed'])
		expect(rpc.requests).toHaveLength(1)
		expect(rpc.signatureChecks).toHaveLength(2)
		expect(rpc.signatureChecks[0]).toEqual({
			signer: SAFE,
			hash: hashMessage({ raw: contextHash(words(1n)) }),
			signature: signed.split(',')[3],
			accepted: true
		})
	})

	it('answers invalid for a Safe seat the Safe refuses, beside a good key seat', async () => {
		const rpc = chain(TWO_OF_THREE, 1n)

		const { body } = await post(TWO_OF_THREE, [
			await seated(words(1n), [A, { safe: [...OWNERS, OWNERS[0]] }])
		])

		expect(statuses(body)).toEqual(['invalid'])
		expect(rpc.signatureChecks.map(c => c.accepted)).toEqual([false])
		expect(cache.store.put).not.toHaveBeenCalled()
	})

	it('answers invalid, with no RPC call, for a coupon short of a seat, as the order would panic', async () => {
		const rpc = chain(TWO_OF_THREE, 1n)

		const { body } = await post(TWO_OF_THREE, [
			await seated(words(1n), [A]),
			await seated(words(2n), [SAFE_SEAT])
		])

		expect(statuses(body)).toEqual(['invalid', 'invalid'])
		expect(rpc.fetch).not.toHaveBeenCalled()
	})

	it('answers invalid, with no RPC call, for one signer in both seats, in any letter case', async () => {
		const rpc = chain(TWO_OF_THREE, 1n)
		const lower: SeatOf = { key: KEY_SIGNER, signer: address(KEY_SIGNER).toLowerCase() }

		const { body } = await post(TWO_OF_THREE, [
			await seated(words(1n), [A, A]),
			await seated(words(2n), [A, lower]),
			await seated(words(3n), [SAFE_SEAT, SAFE_SEAT])
		])

		expect(statuses(body)).toEqual(['invalid', 'invalid', 'invalid'])
		expect(rpc.fetch).not.toHaveBeenCalled()
	})

	it('answers invalid, with no RPC call, for a seat signed by a key the order does not list', async () => {
		const rpc = chain(TWO_OF_THREE, 1n)
		const stranger: SeatOf = { key: generatePrivateKey() }

		const { body } = await post(TWO_OF_THREE, [
			await seated(words(1n), [A, stranger]),
			await seated(words(2n), [stranger, B])
		])

		expect(statuses(body)).toEqual(['invalid', 'invalid'])
		expect(rpc.fetch).not.toHaveBeenCalled()
	})

	it('answers invalid, with no RPC call, when one seat names a listed signer another key signed', async () => {
		const rpc = chain(TWO_OF_THREE, 1n)
		const forged: SeatOf = { key: generatePrivateKey(), signer: address(SECOND_KEY) }

		const { body } = await post(TWO_OF_THREE, [
			await seated(words(1n), [A, forged]),
			await seated(words(2n), [forged, A]),
			await seated(words(3n), [forged, SAFE_SEAT])
		])

		expect(statuses(body)).toEqual(['invalid', 'invalid', 'invalid'])
		expect(rpc.fetch).not.toHaveBeenCalled()
	})

	it('answers invalid for a seat signing other words than the coupon carries', async () => {
		const rpc = chain(TWO_OF_THREE, 1n)
		const good = (await seated(words(1n), [A, B])).split(',')
		const other = (await seated(words(2n), [A, B])).split(',')
		const mixed = [...good.slice(0, 2), ...other.slice(2, 4), ...good.slice(4)].join(',')

		const { body } = await post(TWO_OF_THREE, [mixed])

		expect(statuses(body)).toEqual(['invalid'])
		expect(rpc.fetch).not.toHaveBeenCalled()
	})

	it('reads a coupon carrying a seat past the threshold only when that seat is signed too', async () => {
		const rpc = chain(TWO_OF_THREE, 1n)
		const stranger: SeatOf = { key: generatePrivateKey() }
		const forged: SeatOf = { key: generatePrivateKey(), signer: address(SECOND_KEY) }

		const { body } = await post(TWO_OF_THREE, [
			// The order reads seats 0 and 1 only, and Raindex checks seat 2's signature.
			await seated(words(1n), [A, B, stranger]),
			await seated(words(2n), [A, B, A]),
			await seated(words(3n), [A, SAFE_SEAT, B]),
			await seated(words(4n), [A, B, forged]),
			await seated(words(5n), [A, B, { safe: [OWNERS[0], OWNERS[0], OWNERS[0]] }])
		])

		expect(statuses(body)).toEqual(['unredeemed', 'unredeemed', 'unredeemed', 'invalid', 'invalid'])
		expect(rpc.signatureChecks.map(c => c.accepted)).toEqual([true, false])
	})

	it('answers invalid, with no RPC call, for a contract seat naming a signer the order does not list', async () => {
		const rpc = chain(TWO_OF_THREE, 1n)
		const parts = await seated(words(1n), [SAFE_SEAT])
		const unlisted = parts.replace(SAFE, '0x1111111111111111111111111111111111111111')

		const { body } = await post(TWO_OF_THREE, [
			[...(await seated(words(1n), [A, B])).split(',').slice(0, 4), ...unlisted.split(',')].join(
				','
			)
		])

		expect(statuses(body)).toEqual(['invalid'])
		expect(rpc.fetch).not.toHaveBeenCalled()
	})

	it('caches a coupon under every seat it carries', async () => {
		const rpc = chain(TWO_OF_THREE, 1n, new Map([[nonceKey(TWO_OF_THREE, 1n), 1n]]))
		const signed = await seated(words(1n), [A, SAFE_SEAT])
		await post(TWO_OF_THREE, [signed])
		const fields = signed.split(',')
		const recased = [fields[0].toUpperCase().replace('0X', '0x'), ...fields.slice(1)].join(',')
		const otherSafeSignature = [
			...fields.slice(0, 3),
			`${fields[3].slice(0, -2)}${fields[3].endsWith('1b') ? '1c' : '1b'}`,
			...fields.slice(4)
		].join(',')

		const cached = await post(TWO_OF_THREE, [signed, recased])
		const reread = await post(TWO_OF_THREE, [otherSafeSignature])

		expect(statuses(cached.body)).toEqual(['redeemed', 'redeemed'])
		expect(cached.body.block).toBeNull()
		expect(reread.body.block).not.toBeNull()
		expect(rpc.requests).toHaveLength(2)
	})

	it('stops asking one contract signer with no code, and still asks the Safe', async () => {
		const keyless = address(SECOND_KEY)
		const build = {
			...MAINNET_BUILD,
			PUBLIC_CLAIM_SIGNERS: [address(KEY_SIGNER), keyless, SAFE].join(','),
			PUBLIC_CLAIM_THRESHOLD: '2'
		}
		const rpc = chain(build, 1n)
		const POST = await load(build)
		const words = (nonce: bigint) => context(build, nonce)
		// SECOND_KEY's signature twice: the form of a contract's, so its address is asked.
		const keylessSeat = async (nonce: bigint) => {
			const signature = await privateKeyToAccount(SECOND_KEY).signMessage({
				message: { raw: contextHash(words(nonce)) }
			})
			return [keyless, `${signature}${signature.slice(2)}`]
		}
		const withKeyless = async (nonce: bigint) =>
			[...(await keylessSeat(nonce)), ...(await seated(words(nonce), [A])).split(',')].join(',')

		const first = await postTo(POST, [await withKeyless(1n)])
		const second = await postTo(POST, [
			await withKeyless(2n),
			await seated(words(3n), [A, SAFE_SEAT])
		])

		expect(statuses(first.body)).toEqual(['invalid'])
		expect(statuses(second.body)).toEqual(['invalid', 'unredeemed'])
		expect(rpc.signatureChecks.map(c => [c.signer, c.accepted])).toEqual([
			[keyless.toLowerCase(), false],
			[SAFE, true]
		])
		expect(console.error).toHaveBeenCalledWith(
			expect.stringContaining(`${keyless.toLowerCase()} gave no isValidSignature answer`)
		)
	})
})

describe('a 1-of-2 claim order', () => {
	it('reads a coupon of one seat, as before M-of-N, from either signer', async () => {
		env.ETH_RPC_URL = 'https://eth.rpc.test/key'
		const build = {
			...MAINNET_BUILD,
			PUBLIC_CLAIM_SIGNERS: [address(KEY_SIGNER), address(SECOND_KEY)].join(','),
			PUBLIC_CLAIM_THRESHOLD: '1'
		}
		chain(build, 1n)

		const { body } = await post(build, [
			await keySigned(build, KEY_SIGNER, 1n),
			await keySigned(build, SECOND_KEY, 2n),
			await keySigned(build, generatePrivateKey(), 3n)
		])

		expect(statuses(body)).toEqual(['unredeemed', 'unredeemed', 'invalid'])
	})
})
