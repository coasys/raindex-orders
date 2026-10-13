import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import type { ConfigEnv, UserConfig } from 'vite'
import { BASE_SEPOLIA_DEFAULTS, BUILD_VARIABLES, REPLACED_VARIABLES } from '../network'
import { BASE_SEPOLIA_BUILD, BUILDS, MAINNET_BUILD } from '../testing/builds'
import { bridgeConfig } from './bridgeConfig'

// No .env file is read: the build variables are the process's alone.
const envDir = '/nonexistent/bridge-build'
let outside: Record<string, string | undefined>
const VARIABLES = [...BUILD_VARIABLES, ...Object.keys(REPLACED_VARIABLES)]

/** Runs the plugin as `vite build` does. */
function build() {
	const plugin = bridgeConfig()
	expect(plugin.apply).toBe('build')
	const hook = plugin.config as (config: UserConfig, env: ConfigEnv) => void
	hook({ envDir }, { command: 'build', mode: 'production' })
}

beforeEach(() => {
	outside = Object.fromEntries(VARIABLES.map(key => [key, process.env[key]]))
	for (const key of VARIABLES) delete process.env[key]
})

afterEach(() => {
	vi.unstubAllEnvs()
	for (const [key, value] of Object.entries(outside)) {
		if (value === undefined) delete process.env[key]
		else process.env[key] = value
	}
})

describe('the build', () => {
	it.each(Object.entries(BUILDS))('passes with the %s build variables', (_, variables) => {
		for (const [key, value] of Object.entries(variables)) vi.stubEnv(key, value)

		expect(build).not.toThrow()
	})

	it('fails with nothing set: TestNet has no vault or claim order on Base Sepolia yet', () => {
		expect(build).toThrow('PUBLIC_LOCK_VAULT_ADDRESS is required')
	})

	it('passes a TestNet build given its vault and order, naming the TestNet values it took', () => {
		const info = vi.spyOn(console, 'info').mockImplementation(() => {})
		for (const [key, value] of Object.entries(BASE_SEPOLIA_BUILD)) {
			if (!(key in BASE_SEPOLIA_DEFAULTS) && key !== 'PUBLIC_NETWORK') vi.stubEnv(key, value)
		}

		expect(build).not.toThrow()
		expect(info).toHaveBeenCalledWith(
			expect.stringContaining(
				"bridge build: TestNet's values for PUBLIC_NETWORK, PUBLIC_ORDERBOOK_ADDRESS, PUBLIC_CLAIM_SIGNERS, PUBLIC_CLAIM_THRESHOLD, PUBLIC_CLAIM_INTERPRETER, PUBLIC_CLAIM_STORE"
			)
		)
		info.mockRestore()
	})

	it('fails with a variable missing, naming it', () => {
		for (const [key, value] of Object.entries(MAINNET_BUILD)) vi.stubEnv(key, value)
		vi.stubEnv('PUBLIC_CLAIM_BYTECODE', '')

		expect(build).toThrow('PUBLIC_CLAIM_BYTECODE is required')
	})

	it('fails on mainnet with the test signer among the signers', () => {
		for (const [key, value] of Object.entries(MAINNET_BUILD)) vi.stubEnv(key, value)
		vi.stubEnv(
			'PUBLIC_CLAIM_SIGNERS',
			`${MAINNET_BUILD.PUBLIC_CLAIM_SIGNERS},0x8E72b7568738da52ca3DCd9b24E178127A4E7d37`
		)

		expect(build).toThrow('PUBLIC_CLAIM_SIGNERS lists the test signer')
	})

	it('fails on base-sepolia given the signers without the threshold', () => {
		for (const [key, value] of Object.entries(BASE_SEPOLIA_BUILD)) vi.stubEnv(key, value)
		vi.stubEnv('PUBLIC_CLAIM_THRESHOLD', '')

		expect(build).toThrow('PUBLIC_CLAIM_THRESHOLD is required')
	})

	it.each(Object.entries(BUILDS))(
		'fails on %s while PUBLIC_CLAIM_SIGNER is set, naming what replaced it',
		(_, variables) => {
			for (const [key, value] of Object.entries(variables)) vi.stubEnv(key, value)
			vi.stubEnv('PUBLIC_CLAIM_SIGNER', variables.PUBLIC_CLAIM_SIGNERS)

			expect(build).toThrow(
				'PUBLIC_CLAIM_SIGNER is replaced by PUBLIC_CLAIM_SIGNERS and PUBLIC_CLAIM_THRESHOLD'
			)
		}
	)
})

describe('vite.config.ts', () => {
	it('runs the build check', async () => {
		const config = (await import('../../../vite.config')).default as { plugins: unknown[] }

		const names = config.plugins.flat(Infinity).map(p => (p as { name?: string } | null)?.name)

		expect(names).toContain('bridge-config')
	})
})
