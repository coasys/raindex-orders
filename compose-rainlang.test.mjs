import assert from 'node:assert/strict'
import { execFileSync, spawnSync } from 'node:child_process'
import { test } from 'node:test'
import { fileURLToPath } from 'node:url'
import {
	MAX_SIGNERS,
	MAX_SOURCE_OPS,
	RAINDEX_SUBPARSER,
	TEST_SIGNER,
	bindings,
	compose,
	signerCheckOps,
	signerChecks,
	withSignerChecks
} from './compose-rainlang.mjs'

const SIGNERS = [
	'0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC',
	'0x90F79bf6EB2c4f870365E785982E1f101E93b906',
	'0x15d34AAf54267DB7D7c367839AAf71A00a2C6A65'
]
const COMPOSER = fileURLToPath(new URL('compose-rainlang.mjs', import.meta.url))

/** `n` distinct nonzero addresses. */
const addresses = n => Array.from({ length: n }, (_, i) => `0x${(i + 1).toString(16).padStart(40, '0')}`)

const mainnet = (signers, threshold) =>
	bindings({ network: 'mainnet', subparser: RAINDEX_SUBPARSER, signers, threshold })

for (const network of ['base-sepolia', 'mainnet']) {
	test(`${network}: binds the subparser and the signers it is given`, async () => {
		const rainlang = await compose({
			network,
			subparser: RAINDEX_SUBPARSER,
			signers: SIGNERS.join(','),
			threshold: '2'
		})

		assert.match(rainlang, new RegExp(`using-words-from ${RAINDEX_SUBPARSER}`))
		for (const i of [0, 1]) {
			const listed = SIGNERS.map(s => `binary-equal-to\\(signer<${i}>\\(\\) ${s}\\)`).join(' ')
			assert.match(rainlang, new RegExp(`:ensure\\(any\\(${listed}\\) "Wrong signer"\\)`))
		}
		assert.doesNotMatch(rainlang, /signer<2>/)
		assert.match(
			rainlang,
			/:ensure\(is-zero\(binary-equal-to\(signer<0>\(\) signer<1>\(\)\)\) "Duplicate signer"\)/
		)
		assert.doesNotMatch(rainlang, new RegExp(TEST_SIGNER, 'i'))
		assert.doesNotMatch(rainlang, /valid-signer/)
		assert.match(rainlang, /io-ratio: 1e-30;/)
	})
}

test('a claim needs the same coupon from each of its M seats', () => {
	const checks = signerChecks(SIGNERS, 3)
	const words = seat => Array.from({ length: 9 }, (_, w) => `signed-context<${seat} ${w}>\\(\\)`).join(' ')

	assert.match(checks, new RegExp(`coupon: hash\\(${words(0)}\\),`))
	for (const i of [1, 2]) {
		assert.match(checks, new RegExp(`:ensure\\(binary-equal-to\\(coupon hash\\(${words(i)}\\)\\) "Coupons differ"\\),`))
	}
	assert.equal((checks.match(/Coupons differ/g) ?? []).length, 2)
	assert.doesNotMatch(checks, /signed-context<3/)
	for (const [i, j] of [
		[0, 1],
		[0, 2],
		[1, 2]
	]) {
		assert.match(
			checks,
			new RegExp(`is-zero\\(binary-equal-to\\(signer<${i}>\\(\\) signer<${j}>\\(\\)\\)\\) "Duplicate signer"`)
		)
	}
	assert.equal((checks.match(/Duplicate signer/g) ?? []).length, 3)
	assert.equal((checks.match(/Wrong signer/g) ?? []).length, 3)
})

test('one signer of one needs no distinctness or copy checks', () => {
	const checks = signerChecks([TEST_SIGNER], 1)

	assert.equal(
		checks,
		`/* each of the M seats is signed by one of the N signers the order lists */\n:ensure(any(binary-equal-to(signer<0>() ${TEST_SIGNER})) "Wrong signer"),`
	)
})

test('the checks go where the expression marks, exactly once', () => {
	const mark = '/* M-of-N signer checks, written here by compose-rainlang.mjs */'
	assert.equal(withSignerChecks(`a\n${mark}\nb`, [TEST_SIGNER], 1), `a\n${signerChecks([TEST_SIGNER], 1)}\nb`)
	assert.throws(() => withSignerChecks('a\nb', [TEST_SIGNER], 1), /holds it 0 times/)
	assert.throws(() => withSignerChecks(`${mark}\n${mark}`, [TEST_SIGNER], 1), /holds it 2 times/)
})

test('base-sepolia takes the test signer', async () => {
	const rainlang = await compose({
		network: 'base-sepolia',
		subparser: RAINDEX_SUBPARSER,
		signers: TEST_SIGNER,
		threshold: '1'
	})

	assert.match(rainlang, new RegExp(TEST_SIGNER))
})

test('composes for TestNet when given nothing: the test signer alone', async () => {
	const rainlang = await compose({})

	assert.match(rainlang, new RegExp(`using-words-from ${RAINDEX_SUBPARSER}`))
	assert.match(rainlang, new RegExp(`any\\(binary-equal-to\\(signer<0>\\(\\) ${TEST_SIGNER}\\)\\)`))
	assert.doesNotMatch(rainlang, /signer<1>/)
	assert.equal(execFileSync('node', [COMPOSER], { encoding: 'utf8' }).trim(), rainlang.trim())
})

test('mainnet has no default binding', () => {
	assert.throws(() => bindings({ network: 'mainnet' }), {
		message:
			'--subparser must be a nonzero address, not unset; --signers must list 1 to 15 nonzero addresses, separated by commas; --threshold must be a whole number of signers from 1 up, not unset'
	})
})

test('mainnet refuses the test signer among the signers, in any case', () => {
	for (const signer of [TEST_SIGNER, TEST_SIGNER.toLowerCase()]) {
		assert.throws(
			() => mainnet(`${SIGNERS[0]},${signer}`, '1'),
			/the test signer, whose key is public: mainnet refuses it/
		)
	}
})

test('the signer list and threshold are checked against each other', () => {
	assert.throws(() => mainnet(SIGNERS.join(','), '4'), /--threshold 4 is more than the 3 signers listed/)
	assert.throws(() => mainnet(SIGNERS.join(','), '0'), /--threshold must be a whole number of signers from 1 up, not 0/)
	assert.throws(() => mainnet(SIGNERS.join(','), '1.5'), /--threshold must be a whole number/)
	assert.throws(() => mainnet(SIGNERS.join(','), '02'), /--threshold must be a whole number/)
	assert.throws(
		() => mainnet(`${SIGNERS[0]},${SIGNERS[1].toLowerCase()},${SIGNERS[1]}`, '2'),
		new RegExp(`--signers lists ${SIGNERS[1].toLowerCase()} more than once`)
	)
	assert.throws(() => mainnet(`${SIGNERS[0]},0x1234`, '1'), /--signers must be nonzero addresses, not 0x1234/)
	assert.throws(
		() => mainnet(addresses(MAX_SIGNERS + 1).join(','), '1'),
		new RegExp(`--signers lists ${MAX_SIGNERS + 1} addresses, and the claim order takes at most ${MAX_SIGNERS}`)
	)
	assert.equal(mainnet(SIGNERS.join(','), '3').threshold, 3)
	assert.deepEqual(mainnet(SIGNERS.join(','), '2').signers, SIGNERS)
})

/**
 * The operation counts test/TestClaim.t.sol measured against the deployed
 * parser on a mainnet fork: 49 fixed operations, plus the signer checks.
 */
test('the operations counted are the ones the deployed parser counted', () => {
	for (const [n, m, ops] of [
		[1, 1, 55],
		[2, 1, 58],
		[15, 1, 97],
		[3, 2, 103],
		[15, 2, 175],
		[2, 2, 97],
		[3, 3, 141],
		[5, 3, 159],
		[7, 4, 233],
		[15, 3, 249],
		[8, 4, 245],
		[9, 4, 257],
		[5, 5, 265]
	]) {
		assert.equal(49 + signerCheckOps(n, m), ops, `${m} of ${n}`)
	}
})

test('a shape the deployed parser cannot hold in one source is refused, naming its size', () => {
	for (const [n, m] of [
		[15, 3],
		[8, 4]
	]) {
		assert.equal(mainnet(addresses(n).join(','), String(m)).threshold, m)
	}
	assert.throws(
		() => mainnet(addresses(9).join(','), '4'),
		{
			message: `--threshold 4 of 9 signers needs 257 operations in one source, and the deployed parser takes at most ${MAX_SOURCE_OPS}: list fewer signers or lower the threshold`
		}
	)
	assert.throws(() => mainnet(addresses(5).join(','), '5'), /needs 265 operations/)
})

test('names every missing or malformed input', () => {
	assert.throws(() => bindings({ network: 'goerli', subparser: '0x1234', signers: undefined }), {
		message:
			'--network must be base-sepolia or mainnet, not goerli; --subparser must be a nonzero address, not 0x1234; --signers must list 1 to 15 nonzero addresses, separated by commas; --threshold must be a whole number of signers from 1 up, not unset'
	})
	assert.throws(
		() =>
			bindings({
				network: 'base-sepolia',
				subparser: RAINDEX_SUBPARSER,
				signers: `0x${'0'.repeat(40)}`,
				threshold: '1'
			}),
		/--signers must be nonzero addresses/
	)
})

test('the command prints the composed expression, and exits 1 naming a refusal', () => {
	const args = ['--network', 'mainnet', '--subparser', RAINDEX_SUBPARSER, '--threshold', '2', '--signers']
	const out = execFileSync('node', [COMPOSER, ...args, SIGNERS.join(',')], { encoding: 'utf8' })
	assert.match(out, /using-words-from/)

	const refused = spawnSync('node', [COMPOSER, ...args, `${SIGNERS[0]},${TEST_SIGNER}`], {
		encoding: 'utf8'
	})
	assert.equal(refused.status, 1)
	assert.equal(refused.stdout, '')
	assert.match(refused.stderr, /mainnet refuses it/)
})
