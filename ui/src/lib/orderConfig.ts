import type { Hex, Address } from 'viem'
import { bridge } from './config'
import { HOLO_VAULT_ID } from './network'

export interface OrderConfig {
	orderHash: Hex
	owner: Address
	// The only signer whose coupons the order accepts.
	signer: Address
	store: Address
	outputToken: Address
	outputVaultId: Hex
}

/** The claim order HoloLockVault added, from this build's variables. */
export const CLAIM_ORDER: OrderConfig = {
	orderHash: bridge.claimOrder.orderHash,
	owner: bridge.lockVaultAddress,
	signer: bridge.claimOrder.signer,
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
