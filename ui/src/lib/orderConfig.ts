import type { Hex, Address } from 'viem'
import { bridge } from './config'
import { HOLO_VAULT_ID } from './network'

export interface OrderConfig {
	orderHash: Hex
	owner: Address
	// The N signers the order lists: a claim carries a coupon signed by `threshold`
	// of them, each a different one.
	signers: Address[]
	threshold: number
	store: Address
	outputToken: Address
	outputVaultId: Hex
}

/** The claim order HoloLockVault added, from this build's variables. */
export const CLAIM_ORDER: OrderConfig = {
	orderHash: bridge.claimOrder.orderHash,
	owner: bridge.lockVaultAddress,
	signers: bridge.claimOrder.signers,
	threshold: bridge.claimOrder.threshold,
	store: bridge.claimOrder.store,
	outputToken: bridge.tokenAddress,
	outputVaultId: HOLO_VAULT_ID
}

export function getOrderConfig(orderHash: string): OrderConfig | undefined {
	const normalizedHash = orderHash.toLowerCase()
	if (normalizedHash === CLAIM_ORDER.orderHash.toLowerCase()) {
		return CLAIM_ORDER
	}
	return undefined
}
