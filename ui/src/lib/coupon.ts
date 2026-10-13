// coupon.ts — client-safe coupon helpers.
// Coupon SIGNING is done server-side only (the bridge orchestrator, see
// bridge-orchestrator/src/signer.rs). No signing key lives in this module or any
// client-bundled code (issue #14).
import { isAddress, isHex, numberToHex, type Hex, type Address } from 'viem'

export type CouponConfig = {
	recipient: Address
	orderHash: Hex
	orderbookAddress: Address
	claimTokenAddress: Address
	outputVaultId: Hex
	/** The amount in wei, read from the coupon's float word. */
	withdrawAmount: bigint
	/** The amount as the coupon carries it: the decimal float Raindex V6 pays out. */
	amountWord: Hex
	orderOwner: Address
	nonce: bigint
	expiryTimestamp: number
}

/** One signer's signature over a coupon's nine context words. */
export type Seat = {
	signer: Address
	signature: Hex
}

/**
 * A coupon as the claim order takes it: the nine context words, signed by each of its
 * seats. A claim passes seat i as signed context i, each with the same words.
 */
export type SignedCoupon = {
	seats: Seat[]
	context: bigint[]
}

/** Raindex V6's SignedContextV1, as takeOrders4 takes one. */
export type SignedContextV1Struct = {
	signer: Address
	signature: Hex
	context: Hex[]
}

/** The words of a coupon's context. */
export const COUPON_WORDS = 9

/** HOT's decimals on Ethereum, the exponent of a coupon's amount float. */
const HOT_DECIMALS = 18n
const WORD = 1n << 256n
const COEFFICIENT_BITS = 224n
const COEFFICIENT_MASK = (1n << COEFFICIENT_BITS) - 1n
const MAX_COEFFICIENT = (1n << (COEFFICIENT_BITS - 1n)) - 1n

/**
 * Raindex V6's decimal float, as a bytes32 word: the exponent as an int32 in the
 * top 32 bits, the signed coefficient as an int224 in the rest, and the value
 * coefficient * 10^exponent.
 */
export function unpackFloat(word: bigint): { coefficient: bigint; exponent: bigint } {
	const unsignedExponent = word >> COEFFICIENT_BITS
	const exponent = unsignedExponent >= 1n << 31n ? unsignedExponent - (1n << 32n) : unsignedExponent
	const unsignedCoefficient = word & COEFFICIENT_MASK
	const coefficient =
		unsignedCoefficient > MAX_COEFFICIENT
			? unsignedCoefficient - (1n << COEFFICIENT_BITS)
			: unsignedCoefficient
	return { coefficient, exponent }
}

/**
 * The wei a float word of HOT holds, or an error for a float that is not a whole,
 * nonnegative number of wei. A coupon's amount word always is: the orchestrator
 * writes the wei with exponent -18.
 */
export function floatToWei(word: bigint): bigint {
	const { coefficient, exponent } = unpackFloat(word)
	if (coefficient < 0n) throw new Error('The amount is negative')
	const scale = exponent + HOT_DECIMALS
	if (scale >= 0n) {
		if (scale > 77n && coefficient !== 0n) throw new Error('The amount is too large')
		return coefficient * 10n ** scale
	}
	const divisor = 10n ** -scale
	if (coefficient % divisor !== 0n) throw new Error('The amount is not a whole number of wei')
	return coefficient / divisor
}

/** The float word of `wei` of HOT as the orchestrator writes it: 0xffffffee then the wei. */
export function amountWord(wei: bigint): Hex {
	if (wei < 0n || wei > MAX_COEFFICIENT) throw new Error('The amount has no float')
	const exponent = (WORD >> COEFFICIENT_BITS) - HOT_DECIMALS
	return numberToHex((exponent << COEFFICIENT_BITS) | wei, { size: 32 })
}

export const parseCoupon = (coupon: SignedCoupon): CouponConfig => {
	const [
		recipient,
		amount,
		expiryTimestamp,
		orderHash,
		orderOwner,
		orderbookAddress,
		claimTokenAddress,
		outputVaultId,
		nonce
	] = coupon.context

	const address = (word: bigint) => numberToHex(word, { size: 20 })
	return {
		recipient: address(recipient),
		withdrawAmount: floatToWei(amount),
		amountWord: numberToHex(amount, { size: 32 }),
		expiryTimestamp: Number(expiryTimestamp),
		orderHash: numberToHex(orderHash, { size: 32 }),
		orderOwner: address(orderOwner),
		orderbookAddress: address(orderbookAddress),
		claimTokenAddress: address(claimTokenAddress),
		outputVaultId: numberToHex(outputVaultId, { size: 32 }),
		nonce
	}
}

/** The signed contexts a claim passes: one per seat, every one with the coupon's words. */
export const signedContexts = (coupon: SignedCoupon): SignedContextV1Struct[] =>
	coupon.seats.map(({ signer, signature }) => ({
		signer,
		signature,
		context: coupon.context.map(word => numberToHex(word, { size: 32 }))
	}))

/**
 * A coupon as the orchestrator writes it (bridge-orchestrator/src/signer.rs):
 * `signer1,signature1,...,signerK,signatureK,c0,...,c8`, K >= 1 seats then the nine
 * context words in decimal. One seat is the format of a coupon from before M-of-N.
 */
export const serializeCoupon = (coupon: SignedCoupon): string =>
	[
		...coupon.seats.flatMap(({ signer, signature }) => [signer, signature]),
		...coupon.context.map(word => word.toString())
	].join(',')

const UINT256_DIGITS = (2n ** 256n - 1n).toString().length

/**
 * The coupon `serialized` holds, or an error saying how it is malformed. Whitespace
 * around it, as a paste may carry, is not part of it.
 */
export const deserializeCoupon = (serialized: string): SignedCoupon => {
	const fields = serialized.trim().split(',')
	const seatFields = fields.length - COUPON_WORDS
	if (seatFields < 2 || seatFields % 2 !== 0) {
		throw new Error(
			`Not a coupon: it holds ${fields.length} fields, and a coupon is one or more signers each with its signature, then ${COUPON_WORDS} numbers`
		)
	}
	const seats: Seat[] = []
	for (let i = 0; i < seatFields; i += 2) {
		const [signer, signature] = fields.slice(i, i + 2)
		if (!isAddress(signer, { strict: false }) || !isHex(signature, { strict: true })) {
			throw new Error(`Not a coupon: signer ${i / 2 + 1}'s address or signature is malformed`)
		}
		seats.push({ signer: signer.toLowerCase() as Address, signature })
	}
	const words = fields.slice(seatFields)
	if (!words.every(word => /^[0-9]+$/.test(word) && word.length <= UINT256_DIGITS)) {
		throw new Error(`Not a coupon: its last ${COUPON_WORDS} fields must be whole numbers`)
	}
	const context = words.map(word => BigInt(word))
	if (context.some(word => word >= 2n ** 256n)) {
		throw new Error('Not a coupon: a number in it is larger than a word')
	}
	return { seats, context }
}
