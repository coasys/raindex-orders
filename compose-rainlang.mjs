#!/usr/bin/env node
// Composes the claim expression for one network:
//   node compose-rainlang.mjs --network mainnet --subparser 0x... --signers 0xA,0xB,0xC --threshold 2 [src/holo-claim.rain]
//   node compose-rainlang.mjs     TestNet's network (base-sepolia) and bindings: the test signer alone
import pkg from '@rainlanguage/dotrain'
import { readFileSync } from 'node:fs'
import { fileURLToPath, pathToFileURL } from 'node:url'
import { parseArgs } from 'node:util'

const { RainDocument, MetaStore } = pkg

export const TEST_SIGNER = '0x8E72b7568738da52ca3DCd9b24E178127A4E7d37'
/** `RAINDEX_SUBPARSER` in src/Constants.sol: Rain's deterministic address, the same on every chain. */
export const RAINDEX_SUBPARSER = '0x09Bc7AF266012F44fb41D8Bd682da931666605e1'
const NETWORKS = ['base-sepolia', 'mainnet']
const ZERO_ADDRESS = `0x${'0'.repeat(40)}`
/** TestNet's bindings: a base-sepolia composition takes each one it is not given. */
const BASE_SEPOLIA_DEFAULTS = {
	subparser: RAINDEX_SUBPARSER,
	signers: TEST_SIGNER,
	threshold: '1'
}

/**
 * At most 15 signers: a Rainlang word takes at most 15 inputs, and `any` takes
 * one per listed signer.
 */
export const MAX_SIGNERS = 15

/**
 * The most operations the deployed parser (Rainlang 0.1.9) takes in one source:
 * it refuses more with SourceTotalOpsOverflow. Every word, literal and context
 * read is one operation.
 */
export const MAX_SOURCE_OPS = 255

/** Where in src/holo-claim.rain the signer checks go, as one whole line. */
const SIGNER_CHECKS_MARK = '/* M-of-N signer checks, written here by compose-rainlang.mjs */'
const COUPON_WORDS = 9

/**
 * The operations src/holo-claim.rain's calculate-io holds besides the signer
 * checks. test/TestClaim.t.sol pins MAX_SOURCE_OPS against the deployed parser
 * by parsing the largest shape this accepts and the smallest it refuses.
 */
const CLAIM_CHECKS_OPS = 49

const isAddress = value => /^0x[0-9a-fA-F]{40}$/.test(value ?? '') && value !== ZERO_ADDRESS

/**
 * The operations signerChecks writes for N signers and threshold M: each seat's
 * membership is one `any` of N `binary-equal-to(signer<i>() 0x...)` (3 each)
 * under an `ensure` and its message; each pair of seats is `is-zero` of one
 * `binary-equal-to` of two reads under an `ensure` (6); seat 0's coupon is a
 * `hash` of nine reads (10), and each other seat's is the same hash compared
 * with it under an `ensure` (14).
 */
export function signerCheckOps(n, m) {
	const membership = m * (3 * n + 3)
	if (m === 1) return membership
	return membership + 6 * ((m * (m - 1)) / 2) + (COUPON_WORDS + 1) + (m - 1) * (COUPON_WORDS + 5)
}

/**
 * The expression's network bindings and signer list, or an error naming every
 * input at fault. The network is base-sepolia when unset, and base-sepolia takes
 * TestNet's bindings for any it is not given. Mainnet has none. Signers are a
 * comma-separated list of N addresses, and the threshold M is how many of them
 * must sign each coupon.
 */
export function bindings({ network = 'base-sepolia', subparser, signers, threshold }) {
	if (network === 'base-sepolia') {
		subparser ||= BASE_SEPOLIA_DEFAULTS.subparser
		signers ||= BASE_SEPOLIA_DEFAULTS.signers
		threshold ||= BASE_SEPOLIA_DEFAULTS.threshold
	}
	const faults = []
	if (!NETWORKS.includes(network)) {
		faults.push(`--network must be base-sepolia or mainnet, not ${network ?? 'unset'}`)
	}
	if (!isAddress(subparser)) {
		faults.push(`--subparser must be a nonzero address, not ${subparser ?? 'unset'}`)
	}
	const list = (signers ?? '').split(',').filter(s => s !== '')
	const malformed = list.filter(s => !isAddress(s))
	let listOk = false
	if (list.length === 0) {
		faults.push(`--signers must list 1 to ${MAX_SIGNERS} nonzero addresses, separated by commas`)
	} else if (malformed.length > 0) {
		faults.push(`--signers must be nonzero addresses, not ${malformed.join(', ')}`)
	} else if (list.length > MAX_SIGNERS) {
		faults.push(`--signers lists ${list.length} addresses, and the claim order takes at most ${MAX_SIGNERS}`)
	} else {
		const lower = list.map(s => s.toLowerCase())
		const repeated = lower.filter((s, i) => lower.indexOf(s) !== i)
		if (repeated.length > 0) {
			faults.push(`--signers lists ${[...new Set(repeated)].join(', ')} more than once`)
		} else {
			listOk = true
		}
		if (network === 'mainnet' && lower.includes(TEST_SIGNER.toLowerCase())) {
			faults.push(`--signers names ${TEST_SIGNER}, the test signer, whose key is public: mainnet refuses it`)
		}
	}
	const m = Number(threshold)
	if (!/^[1-9][0-9]*$/.test(threshold ?? '')) {
		faults.push(`--threshold must be a whole number of signers from 1 up, not ${threshold ?? 'unset'}`)
	} else if (list.length > 0 && m > list.length) {
		faults.push(`--threshold ${m} is more than the ${list.length} signers listed`)
	} else if (listOk && CLAIM_CHECKS_OPS + signerCheckOps(list.length, m) > MAX_SOURCE_OPS) {
		faults.push(
			`--threshold ${m} of ${list.length} signers needs ${CLAIM_CHECKS_OPS + signerCheckOps(list.length, m)} operations in one source, and the deployed parser takes at most ${MAX_SOURCE_OPS}: list fewer signers or lower the threshold`
		)
	}
	if (faults.length > 0) throw new Error(faults.join('; '))
	return { rebinds: [['orderbook-subparser', subparser]], signers: list, threshold: m }
}

/**
 * The Rainlang that makes a claim carry the coupon from M distinct signers of the
 * N listed, each signing the same nine words. Signer i is the signer of the
 * claim's i-th signed context, its seat, and signed context i its words. A claim
 * with fewer than M signed contexts fails reading seat M-1, past the end.
 *
 * This is the shape of the M-of-N example in st0x.attest's SPEC.md: every seat
 * in the allowlist (`binary-in<M>`), no signer in two seats (`binary-unique`),
 * and every seat attesting the same thing. Those words came after Rainlang
 * 0.1.9, the release deployed on mainnet and Base Sepolia, whose parser refuses
 * them, so this writes what they replace: an `any` of `binary-equal-to` per
 * seat, and `is-zero(binary-equal-to(...))` per pair of seats.
 */
export function signerChecks(signers, threshold) {
	const lines = []
	lines.push('/* each of the M seats is signed by one of the N signers the order lists */')
	for (let i = 0; i < threshold; i++) {
		const listed = signers.map(signer => `binary-equal-to(signer<${i}>() ${signer})`).join(' ')
		lines.push(`:ensure(any(${listed}) "Wrong signer"),`)
	}
	if (threshold > 1) {
		lines.push('/* no signer fills two seats */')
		for (let i = 0; i < threshold; i++) {
			for (let j = i + 1; j < threshold; j++) {
				lines.push(`:ensure(is-zero(binary-equal-to(signer<${i}>() signer<${j}>())) "Duplicate signer"),`)
			}
		}
		const words = seat =>
			Array.from({ length: COUPON_WORDS }, (_, word) => `signed-context<${seat} ${word}>()`).join(' ')
		lines.push('/* and every seat signed the same nine words as seat 0 */')
		lines.push(`coupon: hash(${words(0)}),`)
		for (let i = 1; i < threshold; i++) {
			lines.push(`:ensure(binary-equal-to(coupon hash(${words(i)})) "Coupons differ"),`)
		}
	}
	return lines.join('\n')
}

/** `source` with the signer checks written where its mark is, which must be there once. */
export function withSignerChecks(source, signers, threshold) {
	const marks = source.split(SIGNER_CHECKS_MARK).length - 1
	if (marks !== 1) {
		throw new Error(`the expression must hold the line "${SIGNER_CHECKS_MARK}" once, and holds it ${marks} times`)
	}
	return source.replace(SIGNER_CHECKS_MARK, signerChecks(signers, threshold))
}

const CLAIM_EXPRESSION = fileURLToPath(new URL('src/holo-claim.rain', import.meta.url))

export async function compose({ network, subparser, signers, threshold, file = CLAIM_EXPRESSION }) {
	const bound = bindings({ network, subparser, signers, threshold })
	return RainDocument.composeText(
		withSignerChecks(readFileSync(file, 'utf8'), bound.signers, bound.threshold),
		['calculate-io', 'handle-io'],
		new MetaStore(),
		bound.rebinds
	)
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
	const { values, positionals } = parseArgs({
		options: {
			network: { type: 'string' },
			subparser: { type: 'string' },
			signers: { type: 'string' },
			threshold: { type: 'string' }
		},
		allowPositionals: true
	})
	try {
		console.log(await compose({ ...values, file: positionals[0] }))
	} catch (error) {
		console.error(error.message)
		process.exit(1)
	}
}
