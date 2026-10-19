import { describe, expect, it } from 'vitest'
import { recoverAddress } from 'viem'
import { privateKeyToAccount } from 'viem/accounts'
import {
	couponDigest,
	safeMessageHash,
	safeMessageTypedData,
	signAsOwner
} from './safe-message.mjs'

/** The coupon test vector's ten words: docs/signer-service.md, worked example. */
const WORDS = [
	'0x0000000000000000000000001111111111111111111111111111111111111111',
	'0xffffffee000000000000000000000000000000000000000014d1120d7b160000',
	'0x0000000000000000000000000000000000000000000000000000000068581c00',
	'0x5eeff397dac16f82057e20da98cf183daf95a0695980a196270e9e0922a275f9',
	'0x000000000000000000000000e3e064e3c2eef66cb93da8d8114f5084e92f48d6',
	'0x00000000000000000000000037fc0efec37d19f8a221aa4f8f7600c9ba2acd20',
	'0x0000000000000000000000006c6ee5e31d828de241282b9606c8e98ea48526e2',
	'0xeede83a4244afae4fef82c8f5b97df1f18bfe3193e65ba02052e37f6171b334b',
	'0x12c911abe545a1669fcbcdaeeede5352ee5a6743f59dbacdc0251b1e4c2f7b77',
	'0x0000000000000000000000000000000000000000000000000000000000000001'
] as const
const SAFE = '0x3838Fc4E0cba211c3D6D202539bB2dc2B72C7a22'
/** Anvil's account 1, an owner of SAFE: its key is public. */
const OWNER_KEY = '0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d'
const DIGEST = '0x4cb8e1ac1a5194e298140ad5c708b227eec55df3ffd4c983641a9d81c544aa60'
const HASH = '0xa2725acb9f918ab1eb2e6657d2d7ebecec2a152c93c3101f123385804bd5bffe'
const SIGNATURE =
	'0x2400e7ddd4b737971e696dbfc5f5f9f6516d15980925ee2e38cb2b6a7be87dfb0fe177ede6ba7a45519c44841019e1f2357988698c43808dbe48cd8d53e170bc1b'

describe('the SafeMessage an owner signs for a coupon', () => {
	it('hashes the worked example as the orchestrator, forge and Safe 1.4.1 do', () => {
		expect(couponDigest([...WORDS])).toBe(DIGEST)
		expect(safeMessageHash({ chainId: 1, safe: SAFE, digest: DIGEST })).toBe(HASH)
	})

	it('takes ten words and nothing else', () => {
		expect(() => couponDigest([...WORDS].slice(0, 9))).toThrow('a coupon is ten words, not 9')
	})

	it('depends on the chain and the Safe', () => {
		expect(safeMessageHash({ chainId: 84532, safe: SAFE, digest: DIGEST })).not.toBe(HASH)
		expect(
			safeMessageHash({
				chainId: 1,
				safe: '0x1111111111111111111111111111111111111111',
				digest: DIGEST
			})
		).not.toBe(HASH)
	})

	it('is signed alike as a raw hash and as typed data, by the owner', async () => {
		const owner = privateKeyToAccount(OWNER_KEY)
		const signature = await signAsOwner(OWNER_KEY, HASH)

		expect(signature).toBe(SIGNATURE)
		expect(
			await owner.signTypedData(safeMessageTypedData({ chainId: 1, safe: SAFE, digest: DIGEST }))
		).toBe(SIGNATURE)
		expect(await recoverAddress({ hash: HASH, signature })).toBe(owner.address)
	})
})
