import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { asBuild } from '$lib/testing/builds'
import { fakeCache } from './fakeRpc'

/**
 * coupon-status against the anvil fork of mainnet test/fork-rehearsal.sh deploys the
 * bridge on, with its claim order's real signers: keys, and Safes whose
 * isValidSignature answers on the fork. The rehearsal sets:
 *   REHEARSAL_RPC_URL  the fork's RPC; the test is skipped unless it is set
 *   PUBLIC_*           the build variables of its deploy record
 *   REHEARSAL_COUPONS  a JSON array of 1 to 20 [coupon, expected status] pairs, at
 *                      least one of them a coupon that reads the chain
 * It posts every coupon in one request, and expects each status in order, chain 1, a
 * block, and nothing logged as an error.
 */
const rehearsal = process.env.REHEARSAL_RPC_URL
const env = vi.hoisted(() => ({}) as Record<string, string | undefined>)
vi.mock('$env/dynamic/private', () => ({ env }))

const build = () =>
	Object.fromEntries(
		Object.entries(process.env).filter(([key]) => key.startsWith('PUBLIC_'))
	) as Record<string, string>

const STATUSES = ['unredeemed', 'redeemed', 'expired', 'invalid']

/** REHEARSAL_COUPONS, or an error saying how it is malformed. */
function rehearsalCoupons(): [string, string][] {
	const value = process.env.REHEARSAL_COUPONS
	if (!value) throw new Error('REHEARSAL_COUPONS is not set')
	const pairs: unknown = JSON.parse(value)
	if (
		!Array.isArray(pairs) ||
		pairs.length === 0 ||
		!pairs.every(
			pair =>
				Array.isArray(pair) &&
				pair.length === 2 &&
				typeof pair[0] === 'string' &&
				STATUSES.includes(pair[1])
		)
	) {
		throw new Error(
			`REHEARSAL_COUPONS must be a JSON array of [coupon, status] pairs, each status one of ${STATUSES.join(', ')}`
		)
	}
	return pairs as [string, string][]
}

describe.skipIf(!rehearsal)('coupon-status on the fork rehearsal', () => {
	let cache: ReturnType<typeof fakeCache>

	beforeEach(() => {
		cache = fakeCache()
		env.ETH_RPC_URL = rehearsal
		vi.spyOn(console, 'error').mockImplementation(() => {})
	})

	afterEach(() => {
		vi.restoreAllMocks()
	})

	async function post(coupons: string[]) {
		const { POST } = await asBuild(build(), () => import('./+server'))
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

	it('answers each of REHEARSAL_COUPONS the status the rehearsal expects, in order', async () => {
		const pairs = rehearsalCoupons()

		const { response, body } = await post(pairs.map(([coupon]) => coupon))

		expect(response.status).toBe(200)
		expect(body.chainId).toBe(1)
		expect(body.block).not.toBeNull()
		expect(body.results.map((r: { status: string }) => r.status)).toEqual(
			pairs.map(([, status]) => status)
		)
		expect(console.error).not.toHaveBeenCalled()
	})
})
