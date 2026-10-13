import { describe, expect, it } from 'vitest'
import {
	amountWord,
	deserializeCoupon,
	floatToWei,
	parseCoupon,
	serializeCoupon,
	signedContexts,
	unpackFloat
} from './coupon'

const word = (hex: string) => BigInt(hex).toString()

// Anvil's third and fourth accounts, and nine context words.
const SIGNER_A = '0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC'
const SIGNER_B = '0x90F79bf6EB2c4f870365E785982E1f101E93b906'
const NINE = ['1', '2', '3', '4', '5', '6', '7', '8', '9']

describe('parseCoupon', () => {
	it('keeps the leading zeros of addresses and hashes', () => {
		const coupon = parseCoupon(
			deserializeCoupon(
				[
					'0x8E72b7568738da52ca3DCd9b24E178127A4E7d37',
					'0x00',
					word('0x00000000000000000000000000000000000000aa'),
					word('0xffffffee00000000000000000000000000000000000000000de0b6b3a7640000'),
					'1776472741',
					word('0x0eeff397dac16f82057e20da98cf183daf95a0695980a196270e9e0922a275f9'),
					word('0x00E064e3C2EEf66cb93dA8D8114F5084E92F48D6'),
					word('0x0fa89cD12Ba1346b1ac570ed988AB43b812733fe'),
					word('0x0aC8eEEE9f84F3E3F592e9D8604100eA1b788749'),
					word('0x0ede83a4244afae4fef82c8f5b97df1f18bfe3193e65ba02052e37f6171b334b'),
					'7'
				].join(',')
			)
		)

		expect(coupon.recipient).toBe('0x00000000000000000000000000000000000000aa')
		expect(coupon.orderHash).toBe(
			'0x0eeff397dac16f82057e20da98cf183daf95a0695980a196270e9e0922a275f9'
		)
		expect(coupon.orderOwner).toBe('0x00e064e3c2eef66cb93da8d8114f5084e92f48d6')
		expect(coupon.orderbookAddress).toBe('0x0fa89cd12ba1346b1ac570ed988ab43b812733fe')
		expect(coupon.claimTokenAddress).toBe('0x0ac8eeee9f84f3e3f592e9d8604100ea1b788749')
		expect(coupon.outputVaultId).toBe(
			'0x0ede83a4244afae4fef82c8f5b97df1f18bfe3193e65ba02052e37f6171b334b'
		)
	})

	it.each([
		['a signer one character short', '0x8E72b7568738da52ca3DCd9b24E178127A4E7d3'],
		['a signature that is not hex', '0x8E72b7568738da52ca3DCd9b24E178127A4E7d37', '0xzz']
	])('refuses %s, so the page calls it malformed', (_case, signer, signature = '0x00') => {
		expect(() => deserializeCoupon([signer, signature, ...NINE].join(','))).toThrow('Not a coupon')
	})

	it('takes a signer in any letter case, as the orderbook does', () => {
		const { seats } = deserializeCoupon(
			['0x8e72b7568738da52ca3DCd9b24E178127A4E7d37', '0x00', ...NINE].join(',')
		)

		expect(seats).toEqual([
			{ signer: '0x8e72b7568738da52ca3dcd9b24e178127a4e7d37', signature: '0x00' }
		])
	})
})

describe('a coupon of several seats', () => {
	const text = [SIGNER_A, '0xaa', SIGNER_B, '0xbbbb', ...NINE].join(',')

	it('reads each signer with its signature, in order, then the nine words', () => {
		expect(deserializeCoupon(text)).toEqual({
			seats: [
				{ signer: SIGNER_A.toLowerCase(), signature: '0xaa' },
				{ signer: SIGNER_B.toLowerCase(), signature: '0xbbbb' }
			],
			context: [1n, 2n, 3n, 4n, 5n, 6n, 7n, 8n, 9n]
		})
	})

	it('writes back as it reads, and ignores whitespace around it, as a paste carries', () => {
		expect(serializeCoupon(deserializeCoupon(` ${text}\n`))).toBe(text.toLowerCase())
	})

	it('is one signed context per seat, each with the same nine words', () => {
		const contexts = signedContexts(deserializeCoupon(text))

		expect(contexts.map(c => [c.signer, c.signature])).toEqual([
			[SIGNER_A.toLowerCase(), '0xaa'],
			[SIGNER_B.toLowerCase(), '0xbbbb']
		])
		for (const { context } of contexts) {
			expect(context).toHaveLength(9)
			expect(context[8]).toBe(`0x${'0'.repeat(63)}9`)
		}
	})

	it.each([
		['no seat', NINE.join(',')],
		['a signer without its signature', [SIGNER_A, '0xaa', SIGNER_B, ...NINE].join(',')],
		['eight words', [SIGNER_A, '0xaa', ...NINE.slice(1)].join(',')],
		['ten words', [SIGNER_A, '0xaa', ...NINE, '10'].join(',')],
		[
			'a second signer that is not an address',
			[SIGNER_A, '0xaa', '0x1234', '0xbb', ...NINE].join(',')
		],
		['a second signature that is not hex', [SIGNER_A, '0xaa', SIGNER_B, 'bb', ...NINE].join(',')],
		['a word in hex', [SIGNER_A, '0xaa', ...NINE.slice(1), '0x10'].join(',')],
		['an empty word', [SIGNER_A, '0xaa', ...NINE.slice(1), ''].join(',')],
		[
			'a word above uint256',
			[SIGNER_A, '0xaa', ...NINE.slice(1), (2n ** 256n).toString()].join(',')
		]
	])('refuses %s', (_, malformed) => {
		expect(() => deserializeCoupon(malformed)).toThrow('Not a coupon')
	})
})

describe('the amount word', () => {
	// The coupon test vector: 1.5 HOT (test/TestCouponSignature.t.sol, bridge-orchestrator/src/signer.rs).
	const WORD = 0xffffffee000000000000000000000000000000000000000014d1120d7b160000n

	it('is the wei with exponent -18, and reads back to the wei', () => {
		expect(amountWord(15n * 10n ** 17n)).toBe(
			'0xffffffee000000000000000000000000000000000000000014d1120d7b160000'
		)
		expect(unpackFloat(WORD)).toEqual({ coefficient: 15n * 10n ** 17n, exponent: -18n })
		expect(floatToWei(WORD)).toBe(15n * 10n ** 17n)
		expect(floatToWei(BigInt(amountWord(1n)))).toBe(1n)
	})

	it('reads any float that is a whole number of wei, as Raindex may answer one', () => {
		// 1.5 HOT as 15 * 10^17, as 1.5 * 10^0, and as 150 * 10^-2.
		expect(floatToWei(((2n ** 32n - 1n) << 224n) | 15n)).toBe(15n * 10n ** 17n)
		expect(floatToWei(((2n ** 32n - 2n) << 224n) | 150n)).toBe(15n * 10n ** 17n)
		expect(floatToWei(0n)).toBe(0n)
		expect(floatToWei(40n)).toBe(40n * 10n ** 18n)
	})

	it('refuses a float that is not a whole number of wei, negative, or too large', () => {
		expect(() => floatToWei(((2n ** 32n - 19n) << 224n) | 1n)).toThrow('not a whole number of wei')
		expect(() => floatToWei(((2n ** 32n - 18n) << 224n) | (2n ** 224n - 1n))).toThrow('negative')
		expect(() => floatToWei((80n << 224n) | 1n)).toThrow('too large')
		expect(() => amountWord(2n ** 223n)).toThrow('has no float')
	})

	it('is what parseCoupon reads the withdraw amount from', () => {
		const coupon = parseCoupon(
			deserializeCoupon(
				[
					'0x8E72b7568738da52ca3DCd9b24E178127A4E7d37',
					'0x00',
					'1',
					WORD.toString(),
					'2',
					'3',
					'4',
					'5',
					'6',
					'7',
					'8'
				].join(',')
			)
		)

		expect(coupon.withdrawAmount).toBe(15n * 10n ** 17n)
		expect(coupon.amountWord).toBe(
			'0xffffffee000000000000000000000000000000000000000014d1120d7b160000'
		)
	})
})
