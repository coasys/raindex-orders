#!/usr/bin/env node
// Makes a claim coupon for the local TestNet that test/local-ui.sh deploys, signed by
// the test signer, whose key is public (TEST_SIGNER_KEY in src/Constants.sol), and
// prints the claim page's link for it. From ui/:
//   npm run make-coupon -- --recipient 0x... --amount 5 [--expiry <unix seconds>] [--nonce <n>]
// It reads the claim order and the RPC from the env file local-ui.sh writes,
// .env.development.local, or --env. It refuses mainnet: the test signer's coupons are
// for Base Sepolia, and a local fork of it, only.
import { readFileSync } from 'node:fs'
import { randomBytes } from 'node:crypto'
import { parseArgs } from 'node:util'
import { fileURLToPath } from 'node:url'
import {
	createPublicClient,
	formatUnits,
	getAddress,
	http,
	isAddress,
	isAddressEqual,
	parseAbi,
	parseUnits
} from 'viem'
import { HOLO_VAULT_ID, signCoupon, TEST_SIGNER_KEY } from './coupon-signing.mjs'

const TEST_SIGNER = '0x8E72b7568738da52ca3DCd9b24E178127A4E7d37'
const BASE_SEPOLIA = 84532
const WEEK = 7n * 24n * 60n * 60n

const fail = message => {
	console.error(`make-coupon: ${message}`)
	process.exit(1)
}

const { values: args } = parseArgs({
	options: {
		recipient: { type: 'string' },
		amount: { type: 'string' },
		expiry: { type: 'string' },
		nonce: { type: 'string' },
		env: { type: 'string' },
		rpc: { type: 'string' },
		url: { type: 'string', default: 'http://localhost:5173' }
	}
})

if (!args.recipient || !isAddress(args.recipient)) fail('--recipient must be an address')
if (!args.amount) fail('--amount is required, in HOT, such as 5 or 0.5')
let wei
try {
	wei = parseUnits(args.amount, 18)
} catch {
	fail(`--amount ${args.amount} is not a number of HOT`)
}
if (wei <= 0n) fail('--amount must be more than 0')

const envFile = args.env ?? fileURLToPath(new URL('../.env.development.local', import.meta.url))
let text
try {
	text = readFileSync(envFile, 'utf8')
} catch {
	fail(`${envFile} is not there: run test/local-ui.sh first, or pass --env`)
}
const env = Object.fromEntries(
	text
		.split('\n')
		.map(line => /^\s*([A-Z0-9_]+)=(.*?)\s*$/.exec(line))
		.filter(Boolean)
		.map(([, key, value]) => [key, value])
)
const need = key => env[key] || fail(`${envFile} has no ${key}`)

if (env.PUBLIC_NETWORK !== 'base-sepolia') {
	fail(
		`PUBLIC_NETWORK is ${env.PUBLIC_NETWORK || 'not set'}: test coupons are for base-sepolia only`
	)
}
const signer = need('PUBLIC_CLAIM_SIGNER')
if (!isAddressEqual(signer, TEST_SIGNER)) {
	fail(`the claim order takes coupons from ${signer}, not the test signer ${TEST_SIGNER}`)
}

const rpcUrl = args.rpc ?? need('BASE_SEPOLIA_RPC_URL')
const client = createPublicClient({ transport: http(rpcUrl, { retryCount: 0 }) })
let chainId
try {
	chainId = await client.getChainId()
} catch {
	fail(`${rpcUrl} did not answer: is anvil running (test/local-ui.sh)?`)
}
if (chainId === 1) fail(`${rpcUrl} is Ethereum mainnet: make-coupon never signs for mainnet`)
if (chainId !== BASE_SEPOLIA)
	fail(`${rpcUrl} answers for chain ${chainId}, not Base Sepolia (84532)`)

const order = {
	hash: BigInt(need('PUBLIC_CLAIM_ORDER_HASH')),
	owner: BigInt(need('PUBLIC_LOCK_VAULT_ADDRESS')),
	orderbook: BigInt(need('PUBLIC_ORDERBOOK_ADDRESS')),
	token: BigInt(need('PUBLIC_TOKEN_ADDRESS')),
	vaultId: HOLO_VAULT_ID
}
const orderExists = await client.readContract({
	address: env.PUBLIC_ORDERBOOK_ADDRESS,
	abi: parseAbi(['function orderExists(bytes32) view returns (bool)']),
	functionName: 'orderExists',
	args: [env.PUBLIC_CLAIM_ORDER_HASH]
})
if (!orderExists) {
	fail(
		`the claim order ${env.PUBLIC_CLAIM_ORDER_HASH} is not on ${rpcUrl}: run test/local-ui.sh again`
	)
}

// A week from the chain's time, not this machine's: a fork's clock starts at its block.
const { timestamp } = await client.getBlock()
const expiry = args.expiry ? BigInt(args.expiry) : timestamp + WEEK
if (expiry <= timestamp) fail(`--expiry ${expiry} has passed: the chain's time is ${timestamp}`)
const nonce = args.nonce ? BigInt(args.nonce) : BigInt(`0x${randomBytes(8).toString('hex')}`)

const recipient = getAddress(args.recipient)
const coupon = await signCoupon({ key: TEST_SIGNER_KEY, order, recipient, wei, expiry, nonce })
console.log(
	`Coupon for ${formatUnits(wei, 18)} mock HOT to ${recipient}, expiring ${new Date(Number(expiry) * 1000).toISOString()}, nonce ${nonce}`
)
console.log(`Claim link: ${args.url.replace(/\/$/, '')}/claim?c=${coupon}`)
console.log(`Coupon: ${coupon}`)
