import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { get } from 'svelte/store'
import { encodeErrorResult, encodeFunctionResult, parseAbi, type Address, type Hex } from 'viem'
import { orderbookAbi } from '../generated'
import { deserializeSignedContext, parseCoupon } from './coupon'
import { TransactionStatus } from './stores/transactionStore'
import { asBuild, BUILDS } from './testing/builds'
import { chainAnswers, REPLACEMENT_HASH, type Fate } from './testing/chain'
import { settled } from './testing/clock'

// The coupon of the claim test vector (test/TestCouponSignature.t.sol): the vector's
// order on both builds, signed by anvil's third account, MAINNET_BUILD's claim signer.
const COUPON = deserializeSignedContext(
	'0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC,0x2539526bd71f08ca5ee37e55a6ce55588b0c8cc32dbe2725be220cdebf664fd16040155f78f326e5688350772d23dc2be231e2f57c189b05f3dc6449e8a55fe11b,97433442488726861213578988847752201310395502865,115792088752037155414859468704681636286916632540171964433728779348048145154048,1750604800,76958440712206607560379240569074999120371888444883451443154037264025912540939,1300945060633283894583661816534861012306758682838,319615586448914156470689800627502155326116515104,619044111217614189527117770386815914092009957090,108043606565222972236900316128309391016550688326814185311821020602083120460619,8496889498503184870230947373316602526857109467185425766089433217409414560631,1'
)
const RECIPIENT = parseCoupon(COUPON).recipient
const OTHER_WALLET = '0x2222222222222222222222222222222222222222'
const EXPIRES = new Date(1750604800 * 1000).toLocaleString()
const HASH = '0xe76a7f6dff5bd4384292b7ebf8bba2496021e3eb90a8cf5ee2cbf730d6021898'
/** The amount word of 1.5 HOT: the wei with exponent -18. */
const AMOUNT_WORD: Hex = '0xffffffee000000000000000000000000000000000000000014d1120d7b160000'
const ZERO_WORD: Hex = `0x${'0'.repeat(64)}`
// The takeOrders4 call a claim of that coupon makes to Raindex, as forge encodes it
// (TestClaimCalldataVector).
const TAKE_ORDERS =
	'0x69c728560000000000000000000000000000000000000000000000000000000000000020ffffffee000000000000000000000000000000000000000014d1120d7b160000ffffffee000000000000000000000000000000000000000014d1120d7b160000ffffffe200000000000000000000000000000000000000000000000000000001000000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000c00000000000000000000000000000000000000000000000000000000000000600000000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000200000000000000000000000000000000000000000000000000000000000000080000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000280000000000000000000000000e3e064e3c2eef66cb93da8d8114f5084e92f48d600000000000000000000000000000000000000000000000000000000000000a0000000000000000000000000000000000000000000000000000000000000014000000000000000000000000000000000000000000000000000000000000001a000000000000000000000000000000000000000000000000000000000000000000000000000000000000000004c52eee7fb6aed0f1a30130d96d02409d9d886cf0000000000000000000000001aa775533e28b1d843e1a589034984e3a62005dc0000000000000000000000000000000000000000000000000000000000000060000000000000000000000000000000000000000000000000000000000000000200ab00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000010000000000000000000000001234567890123456789012345678901234567890eede83a4244afae4fef82c8f5b97df1f18bfe3193e65ba02052e37f6171b334b00000000000000000000000000000000000000000000000000000000000000010000000000000000000000006c6ee5e31d828de241282b9606c8e98ea48526e2eede83a4244afae4fef82c8f5b97df1f18bfe3193e65ba02052e37f6171b334b000000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000200000000000000000000000003c44cdddb6a900fa2b585dd299e03d12fa4293bc000000000000000000000000000000000000000000000000000000000000006000000000000000000000000000000000000000000000000000000000000001c0000000000000000000000000000000000000000000000000000000000000000a0000000000000000000000001111111111111111111111111111111111111111ffffffee000000000000000000000000000000000000000014d1120d7b1600000000000000000000000000000000000000000000000000000000000068581c00aa24ef105ecbfc39695b240de6baeb09278fd4ebf75674b29bcbd2c7ef72ff0b000000000000000000000000e3e064e3c2eef66cb93da8d8114f5084e92f48d600000000000000000000000037fc0efec37d19f8a221aa4f8f7600c9ba2acd200000000000000000000000006c6ee5e31d828de241282b9606c8e98ea48526e2eede83a4244afae4fef82c8f5b97df1f18bfe3193e65ba02052e37f6171b334b12c911abe545a1669fcbcdaeeede5352ee5a6743f59dbacdc0251b1e4c2f7b77000000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000412539526bd71f08ca5ee37e55a6ce55588b0c8cc32dbe2725be220cdebf664fd16040155f78f326e5688350772d23dc2be231e2f57c189b05f3dc6449e8a55fe11b000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000'

// What the orderbook answers a claim it refuses: Error(string) reverts recorded on the old
// Sepolia bridge (the same encoding on V6), and Rainlang's InvalidSignature(0).
const SEPOLIA = {
	nonceUsed:
		'0x08c379a0000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000000000000000000000000000000000124e6f6e636520616c726561647920757365640000000000000000000000000000',
	wrongRecipient:
		'0x08c379a00000000000000000000000000000000000000000000000000000000000000020000000000000000000000000000000000000000000000000000000000000000f57726f6e6720726563697069656e740000000000000000000000000000000000',
	expired:
		'0x08c379a00000000000000000000000000000000000000000000000000000000000000020000000000000000000000000000000000000000000000000000000000000000d4f72646572206578706972656400000000000000000000000000000000000000',
	invalidSignature: '0x52bf98480000000000000000000000000000000000000000000000000000000000000000'
} as const

const ensure = (reason: string) =>
	encodeErrorResult({
		abi: parseAbi(['error Error(string)']),
		errorName: 'Error',
		args: [reason]
	})

const ALREADY_CLAIMED = (token: string) =>
	`This coupon has already been claimed, so there is nothing left to claim. Its ${token} went to ${RECIPIENT}.`
const REISSUE_IF_UNPAID =
	'If you have not received its mock HOT, contact Unyt support to have the withdrawal re-issued.'
const OTHER_BRIDGE =
	'This coupon does not match this bridge, so it cannot be claimed here. Contact Unyt support to have the withdrawal re-issued.'
const VAULT_SHORT =
	'The bridge cannot pay this claim right now, and your coupon was not used. Try again later, and contact Unyt support if it keeps failing.'
const REFUSED = 'The bridge refused this claim, and your coupon was not used. Contact Unyt support.'
const REVERTED =
	'Your claim did not go through, so no mock HOT was paid and your coupon was not used. Claim again.'
const UNCHECKED =
	'Could not check your coupon through your wallet, so nothing was sent. Check your connection and claim again.'
const UNCONFIRMED =
	"Your claim was sent, but its result could not be read. Check your wallet's activity to see whether it went through before you claim again."
const DECLINED = 'You declined the claim in your wallet, so nothing was sent.'
const NOT_SENT =
	"Your wallet did not send the claim. If your wallet's activity shows no claim, claim again."
const CANCELLED =
	'You cancelled the claim in your wallet, so nothing was paid and your coupon was not used.'
const REPLACED =
	'Your wallet replaced the claim with another transaction, so no mock HOT was paid and your coupon was not used. Claim again.'
const PENDING =
	"Your claim is still waiting to be confirmed. Check your wallet's activity before you claim again."
const FAILED =
	"Something went wrong with your claim. Check your wallet's activity before you claim again, and contact Unyt support if it keeps failing."

const {
	IDLE,
	CHECKING,
	PENDING_WALLET,
	PENDING_TX,
	SUCCESS,
	ERROR,
	UNCONFIRMED: NOT_CONFIRMED
} = TransactionStatus

const PAYS = encodeFunctionResult({
	abi: orderbookAbi,
	functionName: 'takeOrders4',
	result: [AMOUNT_WORD, ZERO_WORD]
})

const nodeRevert = (data: Hex) => ({ code: 3, message: 'execution reverted', data })
const metaMaskRevert = (data: Hex) => ({
	code: -32603,
	message: 'Internal JSON-RPC error.',
	data: nodeRevert(data)
})
const REVERT_SHAPES = {
	node: nodeRevert,
	'MetaMask nesting': metaMaskRevert,
	'original error nesting': (data: Hex) => ({
		code: -32603,
		data: { originalError: nodeRevert(data) }
	}),
	'-32000 with data': (data: Hex) => ({ code: -32000, message: 'Execution reverted', data })
}

const COUPON_LOG = {
	couponNonce: '0x12c911abe545a1669fcbcdaeeede5352ee5a6743f59dbacdc0251b1e4c2f7b77',
	couponExpiry: 1750604800
}
const MINED = { blockNumber: 0x11n, gasUsed: 447_599n, gasLimit: 849_182n }

type Answer = Hex | object
type Request = { method: string; params?: unknown[] }
type Wallet = {
	ethCallAnswers: Answer[]
	fate?: Fate
	send?: Answer
	network?: 'base-sepolia' | 'mainnet'
	walletChain?: Hex
	account?: string | null
	accountDuringCheck?: string
	chainAfterCheck?: Hex
	coupon?: typeof COUPON
}

async function wallet({
	ethCallAnswers,
	fate = { mined: '0x1' },
	send = HASH,
	network = 'base-sepolia',
	walletChain = network === 'base-sepolia' ? '0x14a34' : '0x1',
	account = RECIPIENT,
	accountDuringCheck,
	chainAfterCheck,
	coupon = COUPON
}: Wallet) {
	vi.useFakeTimers()
	const asked: string[] = []
	const params: Record<string, unknown> = {}
	const modalWhen: Record<string, unknown> = {}
	let modal = (): { status?: unknown } => ({})
	let switchAccount: (to: string) => void = () => {}
	const chain = chainAnswers(
		{
			hash: HASH,
			from: RECIPIENT,
			to: BUILDS[network].PUBLIC_ORDERBOOK_ADDRESS as Address,
			input: TAKE_ORDERS
		},
		fate
	)
	const answer = (value: Answer | undefined) => {
		if (value === undefined) throw new Error('unexpected request')
		if (typeof value === 'string') return value
		throw value
	}
	const request = vi.fn(async ({ method, params: all = [] }: Request) => {
		asked.push(method)
		params[method] = all[0]
		modalWhen[method] ??= modal().status
		if (method === 'eth_chainId') return walletChain
		if (method === 'eth_call') {
			if (accountDuringCheck) switchAccount(accountDuringCheck)
			walletChain = chainAfterCheck ?? walletChain
			return answer(ethCallAnswers.shift())
		}
		if (method === 'eth_sendTransaction') return answer(send)
		const fromChain = chain(method, all)
		if (fromChain === undefined) throw new Error(`unexpected ${method}`)
		return fromChain
	})
	vi.stubGlobal('window', { ethereum: { request, on: vi.fn() } })
	const { claim, ethereum, store } = await asBuild(BUILDS[network], async () => ({
		claim: await import('./claim'),
		ethereum: await import('./ethereum'),
		store: await import('./stores/transactionStore')
	}))
	ethereum.ethereumStore.set({
		isConnected: true,
		account,
		chainId: network === 'base-sepolia' ? 84532 : 1,
		isLoading: false,
		error: null
	})
	modal = () => get(store.transactionStore)
	switchAccount = to => ethereum.ethereumStore.update(s => ({ ...s, account: to }))
	const statuses: string[] = []
	store.transactionStore.subscribe(({ status }) => {
		if (statuses.at(-1) !== status) statuses.push(status)
	})
	const claimed = () => settled(claim.claimCoupon(coupon))
	const logs = () => vi.mocked(console.error).mock.calls
	return { asked, params, modalWhen, modal, statuses, logs, claim: claimed }
}

beforeEach(() => {
	vi.spyOn(console, 'error').mockImplementation(() => {})
})
afterEach(() => {
	vi.useRealTimers()
	vi.unstubAllGlobals()
	vi.restoreAllMocks()
})

describe.each(Object.entries(REVERT_SHAPES))(
	'a claim the order refuses, told as %s,',
	(_shape, revert) => {
		it.each([
			['already claimed', SEPOLIA.nonceUsed, ALREADY_CLAIMED('mock HOT')],
			[
				'expired',
				SEPOLIA.expired,
				`This coupon expired on ${EXPIRES} and can no longer be claimed. ${REISSUE_IF_UNPAID}`
			],
			[
				'altered',
				SEPOLIA.invalidSignature,
				"This coupon's signature does not match its contents, so it was changed or cut short. Copy the coupon from your Unyt app again."
			],
			[
				'signed by a key the order does not accept',
				ensure('Wrong signer'),
				`This coupon was signed by a key this bridge does not accept. ${REISSUE_IF_UNPAID}`
			],
			['for another order', ensure('Wrong order hash'), OTHER_BRIDGE],
			['for another order owner', ensure('Wrong order owner'), OTHER_BRIDGE],
			['for another orderbook', ensure('Wrong orderbook'), OTHER_BRIDGE],
			['for another token', ensure('Wrong output token'), OTHER_BRIDGE],
			['for another vault', ensure('Wrong output vault id'), OTHER_BRIDGE],
			[
				'for another chain',
				ensure('Wrong chain id'),
				'This coupon is for another chain than Base Sepolia, so it cannot be claimed here. Contact Unyt support to have the withdrawal re-issued.'
			],
			['more than the vault holds', ensure('Wrong output amount'), VAULT_SHORT],
			[
				'from an empty vault',
				encodeErrorResult({
					abi: orderbookAbi,
					errorName: 'MinimumIO',
					args: [AMOUNT_WORD, ZERO_WORD]
				}),
				VAULT_SHORT
			],
			['for a reason the site does not know', ensure('Something new'), REFUSED],
			['with an empty reason', ensure(''), REFUSED],
			['with an error the site cannot decode', '0xdeadbeef', REFUSED]
		] as const)(
			'%s is not sent, and goes from checking to its reason',
			async (_case, data, message) => {
				const refusal = revert(data)
				const { asked, statuses, modal, claim } = await wallet({ ethCallAnswers: [refusal] })

				await expect(claim()).rejects.toMatchObject({ message, cause: refusal })
				expect(asked).not.toContain('eth_sendTransaction')
				expect(statuses).toEqual([IDLE, CHECKING, ERROR])
				expect(modal()).toMatchObject({ error: { message }, hash: '' })
			}
		)
	}
)

describe('a claim the order refuses', () => {
	it('logs the step, the decoded revert, the raw data and the coupon once', async () => {
		const refusal = metaMaskRevert(SEPOLIA.nonceUsed)
		const { claim, logs } = await wallet({ ethCallAnswers: [refusal] })

		await expect(claim()).rejects.toThrow()
		expect(logs()).toHaveLength(1)
		const [summary, details] = logs()[0]
		expect(summary).toBe(`Claim failed while checking the coupon: ${ALREADY_CLAIMED('mock HOT')}`)
		expect(details).toMatchObject({
			step: 'checking the coupon',
			account: RECIPIENT,
			chainId: 84532,
			...COUPON_LOG,
			revert: {
				reason: 'Nonce already used',
				errorName: 'Error',
				args: ['Nonce already used'],
				data: SEPOLIA.nonceUsed
			},
			causes: [expect.objectContaining({ message: ALREADY_CLAIMED('mock HOT') }), refusal]
		})
		expect(details).not.toHaveProperty('hash')
	})

	it('for another wallet names the wallet the coupon pays', async () => {
		const { params, claim } = await wallet({
			ethCallAnswers: [nodeRevert(SEPOLIA.wrongRecipient)],
			account: OTHER_WALLET
		})

		await expect(claim()).rejects.toMatchObject({
			message: `This coupon pays ${RECIPIENT}, not the connected wallet. Switch your wallet to that account and claim again.`
		})
		expect(params.eth_call).toMatchObject({ from: OTHER_WALLET })
	})

	it('names its own token on a MainNet build', async () => {
		const { claim } = await wallet({
			ethCallAnswers: [nodeRevert(SEPOLIA.nonceUsed)],
			network: 'mainnet'
		})

		await expect(claim()).rejects.toMatchObject({ message: ALREADY_CLAIMED('HOT') })
	})

	it.each([
		['execution reverted: Nonce already used', ALREADY_CLAIMED('mock HOT')],
		['execution reverted: Nonce already used\n', ALREADY_CLAIMED('mock HOT')],
		['Execution reverted', REFUSED]
	])('told only as "%s" is not sent, and says why', async (reverted, message) => {
		const { asked, claim } = await wallet({
			ethCallAnswers: [{ code: 3, message: reverted, data: '0x' }]
		})

		await expect(claim()).rejects.toMatchObject({ message })
		expect(asked).not.toContain('eth_sendTransaction')
	})
})

describe('a claim the order would pay', () => {
	it('shows each step, is sent as checked, and succeeds without a log', async () => {
		const { asked, params, modalWhen, statuses, logs, claim, modal } = await wallet({
			ethCallAnswers: [PAYS],
			fate: { mined: '0x1', afterPolls: 2 }
		})

		await expect(claim()).resolves.toBe(HASH)
		const call = {
			from: RECIPIENT,
			to: BUILDS['base-sepolia'].PUBLIC_ORDERBOOK_ADDRESS,
			data: TAKE_ORDERS
		}
		expect(params.eth_call).toMatchObject(call)
		expect(params.eth_sendTransaction).toMatchObject(call)
		expect(asked.filter(m => m === 'eth_sendTransaction')).toHaveLength(1)
		expect(statuses).toEqual([IDLE, CHECKING, PENDING_WALLET, PENDING_TX, SUCCESS])
		expect(modalWhen).toMatchObject({
			eth_call: CHECKING,
			eth_sendTransaction: PENDING_WALLET,
			eth_getTransactionReceipt: PENDING_TX
		})
		expect(modal()).toMatchObject({ status: SUCCESS, hash: HASH })
		expect(logs()).toHaveLength(0)
	})

	it('that the wallet speeds up succeeds under its new hash', async () => {
		const { claim, modal } = await wallet({
			ethCallAnswers: [PAYS],
			fate: { replacedBy: 'repriced' }
		})

		await expect(claim()).resolves.toBe(REPLACEMENT_HASH)
		expect(modal()).toMatchObject({ status: SUCCESS, hash: REPLACEMENT_HASH })
	})

	it('that reverts on chain, and would still pay, says it did not go through and logs why', async () => {
		const { statuses, logs, claim, modal } = await wallet({
			ethCallAnswers: [PAYS, PAYS],
			fate: { mined: '0x0' }
		})

		await expect(claim()).rejects.toMatchObject({ message: REVERTED })
		expect(statuses).toEqual([IDLE, CHECKING, PENDING_WALLET, PENDING_TX, ERROR])
		expect(modal()).toMatchObject({ error: { message: REVERTED }, hash: HASH })
		expect(logs()).toHaveLength(1)
		const [summary, details] = logs()[0]
		expect(summary).toBe(`Claim failed while waiting for confirmation: ${REVERTED}`)
		expect(details).toMatchObject({
			step: 'waiting for confirmation',
			outcome: 'reverted',
			sentHash: HASH,
			hash: HASH,
			recheck: 'would pay',
			mined: MINED,
			account: RECIPIENT,
			chainId: 84532,
			...COUPON_LOG,
			causes: [
				expect.objectContaining({ message: REVERTED }),
				expect.objectContaining({ outcome: 'reverted', hash: HASH })
			]
		})
	})

	it('that the wallet speeds up and then reverts says it did not go through', async () => {
		const { claim, modal } = await wallet({
			ethCallAnswers: [PAYS, PAYS],
			fate: { replacedBy: 'repriced', status: '0x0' }
		})

		await expect(claim()).rejects.toMatchObject({ message: REVERTED })
		expect(modal()).toMatchObject({ hash: REPLACEMENT_HASH })
	})

	it('that reverts because the coupon was claimed meanwhile says so, and logs the reason', async () => {
		const { claim, modal, logs } = await wallet({
			ethCallAnswers: [PAYS, nodeRevert(SEPOLIA.nonceUsed)],
			fate: { mined: '0x0' }
		})

		await expect(claim()).rejects.toMatchObject({ message: ALREADY_CLAIMED('mock HOT') })
		expect(modal()).toMatchObject({ hash: HASH })
		expect(logs()[0][1]).toMatchObject({
			outcome: 'reverted',
			recheck: { reason: 'Nonce already used', data: SEPOLIA.nonceUsed }
		})
		expect(logs()[0][1]).not.toHaveProperty('revert')
	})

	it('that reverts, when the reason cannot be read, still says it did not go through', async () => {
		const readError = new Error('Failed to fetch')
		const { claim, logs } = await wallet({
			ethCallAnswers: [PAYS, readError],
			fate: { mined: '0x0' }
		})

		await expect(claim()).rejects.toMatchObject({ message: REVERTED })
		expect(logs()).toHaveLength(1)
		expect(logs()[0][1]).toMatchObject({ recheck: { error: readError } })
	})

	it('that the user cancels in the wallet says so, without checking again', async () => {
		const { asked, claim, modal } = await wallet({
			ethCallAnswers: [PAYS],
			fate: { replacedBy: 'cancelled' }
		})

		await expect(claim()).rejects.toMatchObject({ message: CANCELLED })
		expect(asked.filter(m => m === 'eth_call')).toHaveLength(1)
		expect(modal()).toMatchObject({ status: ERROR, hash: REPLACEMENT_HASH })
	})

	it.each([
		['would still pay', PAYS, REPLACED],
		['was claimed by it', nodeRevert(SEPOLIA.nonceUsed), ALREADY_CLAIMED('mock HOT')]
	])(
		'that the wallet replaces with another transaction, and %s, says so',
		async (_case, recheck, message) => {
			const { claim } = await wallet({
				ethCallAnswers: [PAYS, recheck],
				fate: { replacedBy: 'replaced' }
			})

			await expect(claim()).rejects.toMatchObject({ message })
		}
	)

	it('that is not confirmed in time says it is still pending, and links it', async () => {
		const { statuses, claim, modal, logs } = await wallet({
			ethCallAnswers: [PAYS],
			fate: { dropped: true }
		})

		await expect(claim()).rejects.toMatchObject({ message: PENDING })
		expect(statuses).toEqual([IDLE, CHECKING, PENDING_WALLET, PENDING_TX, NOT_CONFIRMED])
		expect(modal()).toMatchObject({ error: { message: PENDING }, hash: HASH })
		expect(logs()[0][1]).toMatchObject({ step: 'waiting for confirmation', outcome: 'pending' })
	})

	it('whose receipt cannot be read says to look before claiming again', async () => {
		const { asked, claim, modal } = await wallet({
			ethCallAnswers: [PAYS],
			fate: { receiptFails: true }
		})

		await expect(claim()).rejects.toMatchObject({ message: UNCONFIRMED })
		expect(asked.filter(m => m === 'eth_call')).toHaveLength(1)
		expect(modal()).toMatchObject({ status: NOT_CONFIRMED, hash: HASH })
	})

	it('that the user declines in the wallet says nothing was sent', async () => {
		const { statuses, claim, modal } = await wallet({
			ethCallAnswers: [PAYS],
			send: { code: 4001, message: 'MetaMask Tx Signature: User denied transaction signature.' }
		})

		await expect(claim()).rejects.toMatchObject({ message: DECLINED })
		expect(statuses).toEqual([IDLE, CHECKING, PENDING_WALLET, ERROR])
		expect(modal()).toMatchObject({ error: { message: DECLINED }, hash: '' })
	})

	it('that the wallet fails to send says so, without the wallet text', async () => {
		const failure = { code: -32603, message: 'Internal JSON-RPC error.' }
		const { claim, logs } = await wallet({ ethCallAnswers: [PAYS], send: failure })

		await expect(claim()).rejects.toMatchObject({ message: NOT_SENT })
		expect(logs()[0][1]).toMatchObject({
			step: 'asking the wallet to send',
			causes: [expect.anything(), failure]
		})
	})

	it('that the wallet refuses with a revert names the reason, and logs it', async () => {
		const { claim, logs } = await wallet({
			ethCallAnswers: [PAYS],
			send: metaMaskRevert(SEPOLIA.nonceUsed)
		})

		await expect(claim()).rejects.toMatchObject({ message: ALREADY_CLAIMED('mock HOT') })
		expect(logs()[0][1]).toMatchObject({
			step: 'asking the wallet to send',
			revert: { reason: 'Nonce already used', data: SEPOLIA.nonceUsed }
		})
	})

	it('whose wallet changes network before sending says to switch back', async () => {
		const { asked, claim } = await wallet({ ethCallAnswers: [PAYS], chainAfterCheck: '0x1' })

		await expect(claim()).rejects.toMatchObject({
			message: 'Switch your wallet to Base Sepolia first'
		})
		expect(asked).not.toContain('eth_sendTransaction')
	})

	it('is sent from the account it was checked for, even if the wallet switches', async () => {
		const { params, claim } = await wallet({
			ethCallAnswers: [PAYS],
			accountDuringCheck: OTHER_WALLET
		})

		await claim()
		expect(params.eth_sendTransaction).toMatchObject({ from: RECIPIENT })
	})
})

describe('a claim the wallet cannot check', () => {
	it.each([
		['the read fails', new Error('Failed to fetch')],
		['the wallet reports an internal error', { code: -32603, message: 'Internal JSON-RPC error.' }],
		['the wallet reports text as data', { code: -32603, data: 'header not found' }],
		['the orderbook answers nothing', '0x'],
		['the orderbook answers too little', '0x12345678'],
		['the orderbook answers a revert as a result', ensure('Nonce already used')]
	] as const)('is not sent when %s', async (_case, failure) => {
		const { asked, claim } = await wallet({ ethCallAnswers: [failure] })

		await expect(claim()).rejects.toMatchObject({ message: UNCHECKED })
		expect(asked).not.toContain('eth_sendTransaction')
	})

	it('is not checked or sent while the wallet is on another network', async () => {
		const { asked, claim, logs } = await wallet({ ethCallAnswers: [PAYS], walletChain: '0x1' })

		await expect(claim()).rejects.toMatchObject({
			message: 'Switch your wallet to Base Sepolia first'
		})
		expect(asked).not.toContain('eth_call')
		expect(asked).not.toContain('eth_sendTransaction')
		expect(logs()[0][1]).toMatchObject({ step: 'checking the network', chainId: 1 })
	})

	it('without a connected wallet says so', async () => {
		const { asked, claim } = await wallet({ ethCallAnswers: [], account: null })

		await expect(claim()).rejects.toMatchObject({
			message: 'Your wallet is not connected, so nothing was sent. Connect it and claim again.'
		})
		expect(asked).toEqual([])
	})

	it('for a cause the site does not know says so in general terms, and logs the cause', async () => {
		const { claim, logs } = await wallet({
			ethCallAnswers: [],
			coupon: deserializeSignedContext(`${COUPON.signer},${COUPON.signature},1`)
		})

		await expect(claim()).rejects.toMatchObject({ message: FAILED })
		expect(logs()[0][1]).toMatchObject({
			step: 'reading the coupon',
			causes: [expect.objectContaining({ message: FAILED }), expect.any(Error)]
		})
	})
})
