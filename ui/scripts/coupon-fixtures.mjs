#!/usr/bin/env node
// Writes src/routes/api/coupon-status/fixtures.ts: twenty coupons for the TestNet
// claim order of src/lib/testing/builds.ts, signed by the test signer, whose key is
// public (TEST_SIGNER_KEY in src/Constants.sol). Each keeps the recipient, amount,
// expiry and nonce of a coupon redeemed on the old Sepolia bridge, over the V6 order.
import { writeFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { encodePacked, keccak256, numberToHex } from 'viem'
import { privateKeyToAccount } from 'viem/accounts'

const TEST_SIGNER_KEY = '0xdcbe53cbf4cbee212fe6339821058f2787c7726ae0684335118cdea2e8adaafd'
const ORDER = {
	hash: 0xaa24ef105ecbfc39695b240de6baeb09278fd4ebf75674b29bcbd2c7ef72ff0bn,
	owner: 0xe3e064e3c2eef66cb93da8d8114f5084e92f48d6n,
	orderbook: 0x37fc0efec37d19f8a221aa4f8f7600c9ba2acd20n,
	token: 0x6c6ee5e31d828de241282b9606c8e98ea48526e2n,
	vaultId: 0xeede83a4244afae4fef82c8f5b97df1f18bfe3193e65ba02052e37f6171b334bn
}
const amountWord = wei => ((2n ** 32n - 18n) << 224n) | wei
const RECIPIENT_A = 0x1aa2b3c4d5e6f708192a3b4c5d6e7f8091a2b3c4n
const RECIPIENT_B = 0xa6e4a7b19c5ef3a2d18f32d47e5c8b9a0f1e2d3cn
const OLD = [
	[RECIPIENT_A, 200n, 1776472741],
	[RECIPIENT_A, 263n, 1776472743],
	[RECIPIENT_A, 10n, 1776472922],
	[RECIPIENT_A, 20n, 1776484555],
	[RECIPIENT_A, 10n, 1776484526],
	[RECIPIENT_A, 40n, 1776484513],
	[RECIPIENT_A, 20n, 1776484483],
	[RECIPIENT_A, 200n, 1776484458],
	[RECIPIENT_B, 3n, 1776484470],
	[RECIPIENT_A, 0n, 1776487875, 10000000000000n],
	[RECIPIENT_A, 0n, 1776487847, 100000000000000000n],
	[RECIPIENT_A, 1n, 1776487822],
	[RECIPIENT_A, 90n, 1776487787],
	[RECIPIENT_A, 1000n, 1776487749],
	[RECIPIENT_A, 0n, 1776490403, 10000000000000n],
	[RECIPIENT_A, 0n, 1776490234, 1001000010000000000000n],
	[RECIPIENT_A, 0n, 1776490264, 100000010000000000000n],
	[RECIPIENT_A, 0n, 1776490311, 10000010000000000000n],
	[RECIPIENT_A, 0n, 1776490357, 1000010000000000000n],
	[RECIPIENT_B, 15n, 1776490380]
]
const signer = privateKeyToAccount(TEST_SIGNER_KEY)
const coupons = []
for (const [recipient, hot, expiry, wei = hot * 10n ** 18n] of OLD) {
	const nonce = BigInt(expiry - 604800)
	const words = [
		recipient,
		amountWord(wei),
		BigInt(expiry),
		ORDER.hash,
		ORDER.owner,
		ORDER.orderbook,
		ORDER.token,
		ORDER.vaultId,
		nonce
	]
	const hash = keccak256(encodePacked(Array(9).fill('uint256'), words))
	const signature = await signer.signMessage({ message: { raw: hash } })
	coupons.push([signer.address, signature, ...words.map(String)].join(','))
}
const out = `// Twenty coupons for the TestNet claim order of src/lib/testing/builds.ts, signed by
// the test signer, CLAIM_ORDER.signer on that build. Each keeps the recipient, amount,
// expiry and nonce of a coupon once redeemed on the old Sepolia bridge, over the V6
// order. None is redeemed on a chain. Written by scripts/coupon-fixtures.mjs.
export const TESTNET_COUPONS: string[] = [
${coupons.map(c => `\t'${c}'`).join(',\n')}
]
`
writeFileSync(
	fileURLToPath(new URL('../src/routes/api/coupon-status/fixtures.ts', import.meta.url)),
	out
)
console.log(
	coupons.length,
	'coupons written;',
	'amount word of 1.5 HOT',
	numberToHex(amountWord(15n * 10n ** 17n), { size: 32 })
)
