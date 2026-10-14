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

export type SignedContextV1Struct = {
	signer: Hex
	signature: Hex
	context: bigint[]
}

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
	// Zero at any exponent, which 10 cannot be raised to past the BigInt limit.
	if (coefficient === 0n) return 0n
	const scale = exponent + HOT_DECIMALS
	if (scale >= 0n) {
		if (scale > 77n) throw new Error('The amount is too large')
		return coefficient * 10n ** scale
	}
	// A coefficient is below 10^68, so no power of 10 past 10^77 divides it.
	if (-scale > 77n) throw new Error('The amount is not a whole number of wei')
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

export const parseCoupon = (signedContext: SignedContextV1Struct): CouponConfig => {
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
	] = signedContext.context

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

export const serializeSignedContext = (signedContext: SignedContextV1Struct): string => {
	// we can't use JSON.stringify because the context is an array of BigInts
	// but we need to serialize all of it as a string
	const serialized = signedContext.context.map(n => n.toString()).join(',')
	return `${signedContext.signer},${signedContext.signature},${serialized}`
}

export const deserializeSignedContext = (serialized: string): SignedContextV1Struct => {
	const [signer, signature, ...context] = serialized.split(',')
	if (!isAddress(signer, { strict: false }) || !isHex(signature, { strict: true })) {
		throw new Error('Not a coupon: its signer or signature is malformed')
	}
	return {
		signer: signer.toLowerCase() as Address,
		signature,
		context: context.map(n => BigInt(n))
	}
}
