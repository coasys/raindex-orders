// Signs claim coupons as the orchestrator signs them (bridge-orchestrator/src/signer.rs),
// for the scripts that make test coupons: coupon-fixtures.mjs and make-coupon.mjs.
// The website itself never signs (src/lib/coupon.ts).
import { encodePacked, keccak256 } from 'viem'
import { privateKeyToAccount } from 'viem/accounts'

/** TEST_SIGNER_KEY in src/Constants.sol: the test signer's key, which is public. */
export const TEST_SIGNER_KEY = '0xdcbe53cbf4cbee212fe6339821058f2787c7726ae0684335118cdea2e8adaafd'

/** HOLO_VAULT_ID in src/Constants.sol, on both networks. */
export const HOLO_VAULT_ID = 0xeede83a4244afae4fef82c8f5b97df1f18bfe3193e65ba02052e37f6171b334bn

/** The float word of `wei` of HOT, as the orchestrator writes it: exponent -18, the wei as coefficient. */
export const amountWord = wei => ((2n ** 32n - 18n) << 224n) | wei

/**
 * The coupon string the claim page takes, `signer,signature,ctx0,...,ctx8`: `key`
 * signs the EIP-191 message of keccak256 over the nine context words. `order` is
 * the claim order's { hash, owner, orderbook, token, vaultId }, each a bigint.
 */
export async function signCoupon({ key, order, recipient, wei, expiry, nonce }) {
	const words = [
		BigInt(recipient),
		amountWord(wei),
		BigInt(expiry),
		order.hash,
		order.owner,
		order.orderbook,
		order.token,
		order.vaultId,
		BigInt(nonce)
	]
	const signer = privateKeyToAccount(key)
	const hash = keccak256(encodePacked(Array(9).fill('uint256'), words))
	const signature = await signer.signMessage({ message: { raw: hash } })
	return [signer.address, signature, ...words.map(String)].join(',')
}
