#!/usr/bin/env node
// TEST ONLY (branch mofn-onchain-test, never merge). Prints the takeOrders4 calldata
// the claim page would send for a coupon, so `cast send` can send a claim the claim
// order refuses and it is mined and reverts on chain. A wallet such as a MetaMask
// smart account checks the claim before sending and does not send a refused one.
// From ui/:
//   node scripts/claim-calldata.mjs '<coupon>'
// It reads the claim order from .env.development.local, as make-coupon does, and
// tells on stderr what the orderbook answers for the claim now (eth_call, from the
// coupon's recipient), before it prints the calldata on stdout.
import { readFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import {
	createPublicClient,
	decodeErrorResult,
	encodeAbiParameters,
	encodeFunctionData,
	getAddress,
	http,
	keccak256,
	numberToHex,
	parseAbi,
	parseAbiParameters
} from 'viem'
import { HOLO_VAULT_ID } from './coupon-signing.mjs'

const fail = message => {
	console.error(`claim-calldata: ${message}`)
	process.exit(1)
}

const coupon = process.argv[2]
if (!coupon) fail("give the coupon: node scripts/claim-calldata.mjs '<signer>,<signature>,<words>'")
const [signer, signature, ...words] = coupon.trim().split(',')
if (words.length !== 9) fail(`the coupon has ${words.length} words, not 9`)
const context = words.map(word => numberToHex(BigInt(word), { size: 32 }))

const envFile = fileURLToPath(new URL('../.env.development.local', import.meta.url))
const env = Object.fromEntries(
	readFileSync(envFile, 'utf8')
		.split('\n')
		.map(line => /^\s*([A-Z0-9_]+)=(.*?)\s*$/.exec(line))
		.filter(Boolean)
		.map(([, key, value]) => [key, value])
)
const need = key => env[key] || fail(`${envFile} has no ${key}`)

const vaultId = numberToHex(HOLO_VAULT_ID, { size: 32 })
const order = {
	owner: need('PUBLIC_LOCK_VAULT_ADDRESS'),
	evaluable: {
		interpreter: need('PUBLIC_CLAIM_INTERPRETER'),
		store: need('PUBLIC_CLAIM_STORE'),
		bytecode: need('PUBLIC_CLAIM_BYTECODE')
	},
	validInputs: [{ token: need('PUBLIC_CLAIM_INPUT_TOKEN'), vaultId }],
	validOutputs: [{ token: need('PUBLIC_TOKEN_ADDRESS'), vaultId }],
	nonce: numberToHex(0n, { size: 32 })
}
const orderHash = keccak256(
	encodeAbiParameters(
		parseAbiParameters(
			'(address owner, (address interpreter, address store, bytes bytecode) evaluable, (address token, bytes32 vaultId)[] validInputs, (address token, bytes32 vaultId)[] validOutputs, bytes32 nonce)'
		),
		[order]
	)
)
if (orderHash !== need('PUBLIC_CLAIM_ORDER_HASH').toLowerCase())
	fail(`the order these values describe is ${orderHash}, not PUBLIC_CLAIM_ORDER_HASH`)

const abi = parseAbi([
	'struct IOV2 { address token; bytes32 vaultId; }',
	'struct EvaluableV4 { address interpreter; address store; bytes bytecode; }',
	'struct OrderV4 { address owner; EvaluableV4 evaluable; IOV2[] validInputs; IOV2[] validOutputs; bytes32 nonce; }',
	'struct SignedContextV1 { address signer; bytes32[] context; bytes signature; }',
	'struct TakeOrderConfigV4 { OrderV4 order; uint256 inputIOIndex; uint256 outputIOIndex; SignedContextV1[] signedContext; }',
	'struct TakeOrdersConfigV5 { bytes32 minimumIO; bytes32 maximumIO; bytes32 maximumIORatio; bool IOIsInput; TakeOrderConfigV4[] orders; bytes data; }',
	'function takeOrders4(TakeOrdersConfigV5 config) returns (bytes32, bytes32)',
	'error InvalidSignature(uint256 i)',
	'error Error(string)'
])
const data = encodeFunctionData({
	abi,
	functionName: 'takeOrders4',
	args: [
		{
			minimumIO: context[1],
			maximumIO: context[1],
			maximumIORatio: '0xffffffe200000000000000000000000000000000000000000000000000000001',
			IOIsInput: true,
			orders: [
				{ order, inputIOIndex: 0n, outputIOIndex: 0n, signedContext: [{ signer, context, signature }] }
			],
			data: '0x'
		}
	]
})

const recipient = getAddress(numberToHex(BigInt(words[0]), { size: 20 }))
const client = createPublicClient({ transport: http(need('BASE_SEPOLIA_RPC_URL')) })
try {
	await client.call({ account: recipient, to: need('PUBLIC_ORDERBOOK_ADDRESS'), data })
	console.error(`claim-calldata: the orderbook would pay this claim now. Send it from ${recipient}`)
} catch (err) {
	let reason = err.shortMessage ?? String(err)
	let revert = err
	while (revert && !revert.data) revert = revert.cause
	if (typeof revert?.data === 'string') {
		try {
			const { errorName, args } = decodeErrorResult({ abi, data: revert.data })
			reason = errorName === 'Error' ? args[0] : `${errorName}(${args.join(', ')})`
		} catch {
			reason = revert.data.slice(0, 10)
		}
	}
	console.error(`claim-calldata: the orderbook refuses this claim now: ${reason}. Send it from ${recipient}`)
}
console.log(data)
