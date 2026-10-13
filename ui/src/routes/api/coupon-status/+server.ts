import { json } from '@sveltejs/kit'
import type { RequestHandler } from './$types'
import {
	BaseError,
	ContractFunctionZeroDataError,
	createPublicClient,
	encodeAbiParameters,
	encodePacked,
	hashMessage,
	hexToBigInt,
	http,
	isAddress,
	isAddressEqual,
	isHex,
	keccak256,
	maxUint256,
	parseAbi,
	recoverMessageAddress,
	stringToHex,
	type Address,
	type ContractFunctionParameters,
	type Hex
} from 'viem'
import { env } from '$env/dynamic/private'
import { bridge } from '$lib/config'
import { CLAIM_ORDER } from '$lib/orderConfig'
import {
	CouponStatusCache,
	settledStatus,
	type CouponCache,
	type ReadStatus
} from '$lib/server/couponStatusCache'
import { logRpcError } from '$lib/server/rpcError'

// hot-bridge-ui runs on the Workers Free plan: 50 subrequests per request, Cache API
// calls included, and 10 ms of CPU. N uncached coupons cost N cache matches, one RPC
// fetch and N cache puts, so 20 costs at most 41 subrequests. Each costs one signature
// check per key seat, and the orchestrator writes M seats: 20 for a 1-of-N order.
const MAX_COUPONS = 20
// The most seats a coupon carries: the most signers a claim order lists
// (compose-rainlang.mjs). The order reads seats 0 to M-1, and a coupon the orchestrator
// writes carries exactly M.
const MAX_SEATS = 15
const COUPON_WORDS = 9
const KEY_SIGNATURE_BYTES = 65
// A Safe's signature holds 65 bytes for each owner signature its threshold asks for.
const MIN_SAFE_SIGNATURES = 2
const MAX_SAFE_SIGNATURES = 20
// The `v` of a Safe owner's ECDSA signature: 27 or 28 over the hash, 31 or 32 over
// its EIP-191 message. 0 would have the Safe call another contract, and 1 read an
// approval stored on chain, so neither is read.
const SAFE_OWNER_V = ['1b', '1c', '1f', '20']
const EIP1271_MAGIC_VALUE = '0x1626ba7e00000000000000000000000000000000000000000000000000000000'
const MAX_BODY_BYTES = 64 * 1024
const UINT256_DIGITS = maxUint256.toString().length
// The highest `s` OpenZeppelin's ECDSA.tryRecover accepts, which the orderbook uses to
// check a coupon's signature. viem would also accept the high-`s` twin.
const MAX_SIGNATURE_S = 0x7fffffffffffffffffffffffffffffff5d576e7357a4501ddfe92f46681b20a0n

const HEADERS = {
	'Access-Control-Allow-Origin': '*',
	'Access-Control-Allow-Methods': 'POST, OPTIONS',
	'Access-Control-Allow-Headers': 'Content-Type',
	'Access-Control-Max-Age': '86400',
	'Cache-Control': 'no-store'
}

const orderbook = bridge.orderbookAddress
const orderHash = BigInt(CLAIM_ORDER.orderHash)
const listedSigners = new Set(CLAIM_ORDER.signers.map(signer => signer.toLowerCase()))

// Raindex evaluates the claim order under the namespace
// LibNamespace.qualifyNamespace(order owner, raindex) = keccak256(owner, raindex),
// and src/holo-claim.rain marks a nonce used there at hash(order-hash() nonce).
const namespace = BigInt(
	keccak256(
		encodeAbiParameters([{ type: 'address' }, { type: 'address' }], [CLAIM_ORDER.owner, orderbook])
	)
)
const nonceKey = (nonce: bigint) =>
	keccak256(encodePacked(['uint256', 'uint256'], [orderHash, nonce]))

// Rainlang's IInterpreterStoreV3: keys and values are bytes32 words.
const readAbi = parseAbi([
	'function get(uint256 namespace, bytes32 key) view returns (bytes32)',
	'function isValidSignature(bytes32 hash, bytes signature) view returns (bytes32)',
	'function getChainId() view returns (uint256)',
	'function getBlockNumber() view returns (uint256)',
	'function getCurrentBlockTimestamp() view returns (uint256)'
])
const multicall3 = bridge.chain.contracts.multicall3.address

// When each listed signer's isValidSignature call last found no answer, as an address
// with no code gives, by lowercase address. For SILENT_SIGNER_MS after it, this isolate
// answers a coupon with a contract seat for that signer invalid unread, so forged ones
// cost no read. Only listed signers are asked, so it holds at most N entries.
const claimSignerSilentAt = new Map<string, number>()
const SILENT_SIGNER_MS = 10 * 60_000

/** One signer's signature over the coupon, signed context i of a claim. */
type Seat = {
	/** Lowercase. */
	signer: Address
	signature: Hex
	signedBy: 'key' | 'contract'
}

type Coupon = {
	id: Hex
	seats: Seat[]
	hash: Hex
	nonce: bigint
	expiry: bigint
}

type Result = {
	status: ReadStatus | 'invalid'
	nonce: string | null
	expiry: number | null
}

type ChainRead = {
	block: bigint
	timestamp: bigint
	flags: Map<bigint, bigint>
	/** The coupons every contract seat of which its signer accepted. */
	contractSigned: Set<Coupon>
}

const reply = (body: unknown, status: number) => json(body, { status, headers: HEADERS })

export const OPTIONS: RequestHandler = () => new Response(null, { status: 204, headers: HEADERS })

export const POST: RequestHandler = async ({ request, platform }) => {
	const texts = await readCoupons(request)
	if ('error' in texts) return reply(texts, 400)
	if (!platform) throw new Error('coupon-status needs the Cloudflare Workers platform')
	// The adapter types `caches` with @cloudflare/workers-types, whose Response is not
	// the DOM Response this app builds; at runtime both are the Workers Response.
	const store = (await platform.caches.open('coupon-status')) as unknown as CouponCache
	const cache = new CouponStatusCache(store, new URL(request.url).origin)

	// A coupon with no status at the end is invalid.
	const coupons = texts.map(parseCoupon)
	const statuses = new Map<Coupon, ReadStatus>()
	const unread: Coupon[] = []
	const unverified: Coupon[] = []
	const now = Date.now()
	await Promise.all(
		coupons.map(async coupon => {
			if (!coupon) return
			const cached = await cache.get(coupon.id)
			const status = cached && settledStatus(cached, coupon.expiry, now)
			if (status) statuses.set(coupon, status)
			// An entry exists only for a coupon whose every signature was verified.
			else if (cached) unread.push(coupon)
			else {
				const contractSeats = coupon.seats.filter(seat => seat.signedBy === 'contract')
				if (contractSeats.some(seat => isSilent(seat.signer, now))) return
				if (!(await keySeatsSigned(coupon))) return
				if (contractSeats.length > 0) unverified.push(coupon)
				else unread.push(coupon)
			}
		})
	)

	let chain: ChainRead | undefined
	if (unread.length + unverified.length > 0) {
		const rpcUrl = env[bridge.rpcSecret]
		if (!rpcUrl) {
			console.error(`coupon-status: ${bridge.rpcSecret} is not set`)
			return reply({ error: 'RPC is not configured' }, 502)
		}
		try {
			chain = await readChain(rpcUrl, unread, unverified)
		} catch (e) {
			logRpcError('coupon-status: RPC read failed', e)
			return reply({ error: 'RPC read failed' }, 502)
		}
		const readAt = Date.now()
		const { flags, timestamp, contractSigned } = chain
		const verified = [...unread, ...unverified.filter(coupon => contractSigned.has(coupon))]
		await Promise.all(
			verified.map(coupon => {
				const status =
					flags.get(coupon.nonce) !== 0n
						? 'redeemed'
						: coupon.expiry <= timestamp
							? 'expired'
							: 'unredeemed'
				statuses.set(coupon, status)
				return cache.put(coupon.id, { status, readAt })
			})
		)
	}

	const results = coupons.map((coupon): Result => {
		const status = coupon && statuses.get(coupon)
		if (!status) return { status: 'invalid', nonce: null, expiry: null }
		return { status, nonce: coupon.nonce.toString(), expiry: Number(coupon.expiry) }
	})
	return reply({ chainId: bridge.chain.id, block: chain?.block.toString() ?? null, results }, 200)
}

async function readCoupons(request: Request): Promise<string[] | { error: string }> {
	const text = await readText(request)
	if (text === null) return { error: `body must be at most ${MAX_BODY_BYTES} bytes` }
	let body: unknown
	try {
		body = JSON.parse(text)
	} catch {
		return { error: 'body must be JSON' }
	}
	if (
		typeof body !== 'object' ||
		body === null ||
		Array.isArray(body) ||
		Object.keys(body).length !== 1 ||
		!('coupons' in body)
	) {
		return { error: 'body must be {"coupons": [...]}' }
	}
	const { coupons } = body
	if (
		!Array.isArray(coupons) ||
		coupons.length < 1 ||
		coupons.length > MAX_COUPONS ||
		!coupons.every(coupon => typeof coupon === 'string')
	) {
		return { error: `coupons must be an array of 1 to ${MAX_COUPONS} strings` }
	}
	return coupons
}

/** The body as text, or null as soon as it is longer than MAX_BODY_BYTES. */
async function readText(request: Request): Promise<string | null> {
	if (Number(request.headers.get('Content-Length')) > MAX_BODY_BYTES) return null
	if (!request.body) return ''
	const reader = request.body.getReader()
	const decoder = new TextDecoder()
	let text = ''
	let size = 0
	for (let read = await reader.read(); !read.done; read = await reader.read()) {
		size += read.value.byteLength
		if (size > MAX_BODY_BYTES) {
			await reader.cancel()
			return null
		}
		text += decoder.decode(read.value, { stream: true })
	}
	return text + decoder.decode()
}

/**
 * A coupon is `signer1,signature1,...,signerK,signatureK,c0..c8`, K >= 1 seats then
 * the nine context words (bridge-orchestrator/src/signer.rs). Null unless it parses,
 * names the claim order, carries at least M seats, the first M of them signed by M
 * different signers the order lists, and every seat carries a signature the orderbook
 * would accept the form of. The order reads seats 0 to M-1 only; Raindex checks the
 * signature of every seat a claim carries, so a seat past M may name any key, but a
 * contract seat must name a listed signer, the only contracts this asks. A key seat's
 * signature is checked by keySeatsSigned, a contract seat's on chain by readChain.
 */
function parseCoupon(text: string): Coupon | null {
	const fields = text.split(',')
	const seatFields = fields.length - COUPON_WORDS
	if (seatFields < 2 || seatFields % 2 !== 0 || seatFields / 2 > MAX_SEATS) return null
	const seats: Seat[] = []
	for (let i = 0; i < seatFields; i += 2) {
		const [signer, signature] = fields.slice(i, i + 2)
		if (!isAddress(signer, { strict: false })) return null
		const signedBy = signatureForm(signature)
		if (!signedBy) return null
		const lower = signer.toLowerCase() as Address
		if (signedBy === 'contract' && !listedSigners.has(lower)) return null
		seats.push({ signer: lower, signature: signature as Hex, signedBy })
	}
	const required = seats.slice(0, CLAIM_ORDER.threshold)
	if (required.length < CLAIM_ORDER.threshold) return null
	if (!required.every(seat => listedSigners.has(seat.signer))) return null
	if (new Set(required.map(seat => seat.signer)).size !== required.length) return null

	const words = fields.slice(seatFields)
	if (!words.every(field => field.length <= UINT256_DIGITS && /^\d+$/.test(field))) return null
	const context = words.map(BigInt)
	if (context.some(value => value > maxUint256)) return null
	const [, , expiry, couponOrderHash, owner, couponOrderbook, , , nonce] = context
	if (couponOrderHash !== orderHash) return null
	if (owner !== BigInt(CLAIM_ORDER.owner)) return null
	if (couponOrderbook !== BigInt(orderbook)) return null
	// The response states expiry as a JSON number of seconds.
	if (expiry > BigInt(Number.MAX_SAFE_INTEGER)) return null

	const hash = keccak256(encodePacked(Array<'uint256'>(9).fill('uint256'), context))
	return { id: couponId(seats, context), seats, hash, nonce, expiry }
}

/**
 * Who could have made `signature`: a key, as 65 bytes r, s, v with v 27 or 28 and a
 * low s, as ECDSA.tryRecover requires; or a Safe, as 2 to 20 of its owners' ECDSA
 * signatures.
 */
function signatureForm(signature: string): Seat['signedBy'] | null {
	if (!isHex(signature) || signature.length % 2 !== 0) return null
	const bytes = (signature.length - 2) / 2
	if (bytes === KEY_SIGNATURE_BYTES) {
		if (!['1b', '1c'].includes(signature.slice(130).toLowerCase())) return null
		if (hexToBigInt(`0x${signature.slice(66, 130)}`) > MAX_SIGNATURE_S) return null
		return 'key'
	}
	const signatures = bytes / KEY_SIGNATURE_BYTES
	if (
		Number.isInteger(signatures) &&
		signatures >= MIN_SAFE_SIGNATURES &&
		signatures <= MAX_SAFE_SIGNATURES
	) {
		const vs = Array.from({ length: signatures }, (_, i) =>
			signature.slice(2 + 130 * i + 128, 2 + 130 * (i + 1)).toLowerCase()
		)
		return vs.every(v => SAFE_OWNER_V.includes(v)) ? 'contract' : null
	}
	return null
}

/**
 * One coupon's identity, whatever its spelling: hex case and leading zeros change the
 * text but not what the orderbook checks. It covers every seat, in order, and the
 * context, which includes the expiry, so a coupon re-issued for the same withdrawal
 * has an identity of its own. A coupon of one seat keeps the identity it had before
 * M-of-N, and with it its cache entry.
 */
function couponId(seats: Seat[], context: bigint[]): Hex {
	const canonical = [
		...seats.flatMap(({ signer, signature }) => [signer, signature.toLowerCase()]),
		...context.map(String)
	]
	return keccak256(stringToHex(canonical.join(',')))
}

/**
 * Whether each key seat's signature recovers to the signer the seat names, over the
 * EIP-191 message the orderbook checks: keccak256 of the nine context words.
 */
async function keySeatsSigned({ hash, seats }: Coupon): Promise<boolean> {
	for (const { signer, signature, signedBy } of seats) {
		if (signedBy !== 'key') continue
		try {
			const recovered = await recoverMessageAddress({ message: { raw: hash }, signature })
			if (!isAddressEqual(recovered, signer)) return false
		} catch {
			return false
		}
	}
	return true
}

/** Whether `signer` found no isValidSignature answer within SILENT_SIGNER_MS of `now`. */
function isSilent(signer: Address, now: number): boolean {
	const at = claimSignerSilentAt.get(signer)
	return at !== undefined && now - at < SILENT_SIGNER_MS
}

/**
 * One aggregate3 eth_call at the `safe` block reads each nonce's flag once, along with
 * the chain, number and timestamp of the block it read them in. In the same call the
 * listed signer of each contract seat of each `unverified` coupon checks that seat's
 * signature through EIP-1271 isValidSignature, over the digest the orderbook passes it,
 * accepting only the magic value, as the orderbook does.
 */
async function readChain(
	rpcUrl: string,
	unread: Coupon[],
	unverified: Coupon[]
): Promise<ChainRead> {
	const nonces = [...new Set([...unread, ...unverified].map(coupon => coupon.nonce))]
	const seatChecks = unverified.flatMap(coupon =>
		coupon.seats.filter(seat => seat.signedBy === 'contract').map(seat => ({ coupon, seat }))
	)
	const contracts: ContractFunctionParameters<typeof readAbi, 'view'>[] = [
		{ address: multicall3, abi: readAbi, functionName: 'getChainId' },
		{ address: multicall3, abi: readAbi, functionName: 'getBlockNumber' },
		{ address: multicall3, abi: readAbi, functionName: 'getCurrentBlockTimestamp' },
		...nonces.map(nonce => ({
			address: CLAIM_ORDER.store,
			abi: readAbi,
			functionName: 'get' as const,
			args: [namespace, nonceKey(nonce)] as const
		})),
		...seatChecks.map(({ coupon, seat }) => ({
			address: seat.signer,
			abi: readAbi,
			functionName: 'isValidSignature' as const,
			args: [hashMessage({ raw: coupon.hash }), seat.signature] as const
		}))
	]
	// One attempt of at most 5 s. A retry would wait as long as the RPC's Retry-After
	// asks, and the caller polls anyway.
	const transport = http(rpcUrl, { retryCount: 0, timeout: 5_000 })
	const client = createPublicClient({ chain: bridge.chain, transport })
	const results = await client.multicall({
		contracts,
		// A contract signer reverts on a signature it refuses.
		allowFailure: true,
		blockTag: 'safe',
		// 0 keeps viem from splitting the batch across several eth_calls.
		batchSize: 0
	})
	const read = (i: number) => {
		const answer = results[i]
		if (answer.status === 'failure') throw answer.error
		return answer.result as bigint
	}
	const flag = (i: number) => hexToBigInt(read(i) as unknown as Hex)
	const chainId = read(0)
	if (chainId !== BigInt(bridge.chain.id)) {
		throw new Error(`RPC answered for chain ${chainId}, expected ${bridge.chain.id}`)
	}
	const checks = results.slice(3 + nonces.length)
	const silent = new Set(
		seatChecks
			.filter((_, i) => {
				const answer = checks[i]
				return (
					answer.status === 'failure' &&
					answer.error instanceof BaseError &&
					answer.error.walk(e => e instanceof ContractFunctionZeroDataError) !== null
				)
			})
			.map(({ seat }) => seat.signer)
	)
	for (const signer of silent) {
		claimSignerSilentAt.set(signer, Date.now())
		console.error(
			`coupon-status: the claim signer ${signer} gave no isValidSignature answer; its contract signatures read as invalid for ${SILENT_SIGNER_MS / 60_000} min`
		)
	}
	const refused = new Set(
		seatChecks
			.filter((_, i) => {
				const answer = checks[i]
				return !(answer.status === 'success' && String(answer.result) === EIP1271_MAGIC_VALUE)
			})
			.map(({ coupon }) => coupon)
	)
	return {
		block: read(1),
		timestamp: read(2),
		flags: new Map(nonces.map((nonce, i) => [nonce, flag(3 + i)])),
		contractSigned: new Set(unverified.filter(coupon => !refused.has(coupon)))
	}
}
