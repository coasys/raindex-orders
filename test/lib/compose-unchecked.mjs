#!/usr/bin/env node
// Test only. Composes the claim expression for N made-up signers and threshold M
// without compose-rainlang.mjs's refusal of a shape over the parser's operation
// limit, so test/TestClaim.t.sol can show the deployed parser refusing it:
//   node test/lib/compose-unchecked.mjs N M
import pkg from '@rainlanguage/dotrain'
import { readFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { RAINDEX_SUBPARSER, withSignerChecks } from '../../compose-rainlang.mjs'

const { RainDocument, MetaStore } = pkg
const [n, m] = process.argv.slice(2).map(Number)
const signers = Array.from({ length: n }, (_, i) => `0x${(i + 1).toString(16).padStart(40, '0')}`)
const source = readFileSync(fileURLToPath(new URL('../../src/holo-claim.rain', import.meta.url)), 'utf8')
console.log(
	await RainDocument.composeText(withSignerChecks(source, signers, m), ['calculate-io', 'handle-io'], new MetaStore(), [
		['orderbook-subparser', RAINDEX_SUBPARSER]
	])
)
