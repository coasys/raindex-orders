// Contract ABIs for HOT Bridge.
//
// orderbookAbi is Raindex V6: `forge inspect IRaindexV6 abi --json` on
// raindex-interface 0.1.7 (the release src/Constants.sol names), plus the
// errors RaindexV6.sol and Rainlang's LibContext.sol declare outside the
// interface, which a claim can revert with: InvalidSignature, MinimumIO,
// TokenMismatch, NotOrderOwner and the rest. Every amount is a decimal float,
// a bytes32 (ui/src/lib/coupon.ts). Regenerate it from the repo root with
//   forge inspect IRaindexV6 abi --json
// and keep those errors.

//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
// Orderbook (RaindexV6)
//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

export const orderbookAbi = [
	{
		type: 'error',
		name: 'ClearZeroAmount',
		inputs: [],
	},
	{
		type: 'error',
		name: 'InvalidSignature',
		inputs: [
			{
				name: 'i',
				type: 'uint256',
				internalType: 'uint256',
			},
		],
	},
	{
		type: 'error',
		name: 'MinimumIO',
		inputs: [
			{
				name: 'minimumIO',
				type: 'bytes32',
				internalType: 'Float',
			},
			{
				name: 'actualIO',
				type: 'bytes32',
				internalType: 'Float',
			},
		],
	},
	{
		type: 'error',
		name: 'NegativeBounty',
		inputs: [],
	},
	{
		type: 'error',
		name: 'NegativePull',
		inputs: [],
	},
	{
		type: 'error',
		name: 'NegativePush',
		inputs: [],
	},
	{
		type: 'error',
		name: 'NegativeVaultBalance',
		inputs: [
			{
				name: 'vaultBalance',
				type: 'bytes32',
				internalType: 'Float',
			},
		],
	},
	{
		type: 'error',
		name: 'NegativeVaultBalanceChange',
		inputs: [
			{
				name: 'amount',
				type: 'bytes32',
				internalType: 'Float',
			},
		],
	},
	{
		type: 'error',
		name: 'NoOrders',
		inputs: [],
	},
	{
		type: 'error',
		name: 'NotOrderOwner',
		inputs: [
			{
				name: 'owner',
				type: 'address',
				internalType: 'address',
			},
		],
	},
	{
		type: 'error',
		name: 'OrderNoHandleIO',
		inputs: [],
	},
	{
		type: 'error',
		name: 'OrderNoInputs',
		inputs: [],
	},
	{
		type: 'error',
		name: 'OrderNoOutputs',
		inputs: [],
	},
	{
		type: 'error',
		name: 'OrderNoSources',
		inputs: [],
	},
	{
		type: 'error',
		name: 'ReentrancyGuardReentrantCall',
		inputs: [],
	},
	{
		type: 'error',
		name: 'SameOwner',
		inputs: [],
	},
	{
		type: 'error',
		name: 'TokenMismatch',
		inputs: [],
	},
	{
		type: 'error',
		name: 'TokenSelfTrade',
		inputs: [],
	},
	{
		type: 'error',
		name: 'UnsupportedCalculateOutputs',
		inputs: [
			{
				name: 'outputs',
				type: 'uint256',
				internalType: 'uint256',
			},
		],
	},
	{
		type: 'error',
		name: 'ZeroDepositAmount',
		inputs: [
			{
				name: 'sender',
				type: 'address',
				internalType: 'address',
			},
			{
				name: 'token',
				type: 'address',
				internalType: 'address',
			},
			{
				name: 'vaultId',
				type: 'bytes32',
				internalType: 'bytes32',
			},
		],
	},
	{
		type: 'error',
		name: 'ZeroMaximumIO',
		inputs: [],
	},
	{
		type: 'error',
		name: 'ZeroVaultId',
		inputs: [
			{
				name: 'sender',
				type: 'address',
				internalType: 'address',
			},
			{
				name: 'token',
				type: 'address',
				internalType: 'address',
			},
		],
	},
	{
		type: 'error',
		name: 'ZeroWithdrawTargetAmount',
		inputs: [
			{
				name: 'sender',
				type: 'address',
				internalType: 'address',
			},
			{
				name: 'token',
				type: 'address',
				internalType: 'address',
			},
			{
				name: 'vaultId',
				type: 'bytes32',
				internalType: 'bytes32',
			},
		],
	},
	{
		type: 'event',
		name: 'AddOrderV3',
		inputs: [
			{
				name: 'sender',
				type: 'address',
				indexed: false,
				internalType: 'address',
			},
			{
				name: 'orderHash',
				type: 'bytes32',
				indexed: false,
				internalType: 'bytes32',
			},
			{
				name: 'order',
				type: 'tuple',
				indexed: false,
				internalType: 'struct OrderV4',
				components: [
					{
						name: 'owner',
						type: 'address',
						internalType: 'address',
					},
					{
						name: 'evaluable',
						type: 'tuple',
						internalType: 'struct EvaluableV4',
						components: [
							{
								name: 'interpreter',
								type: 'address',
								internalType: 'contract IInterpreterV4',
							},
							{
								name: 'store',
								type: 'address',
								internalType: 'contract IInterpreterStoreV3',
							},
							{
								name: 'bytecode',
								type: 'bytes',
								internalType: 'bytes',
							},
						],
					},
					{
						name: 'validInputs',
						type: 'tuple[]',
						internalType: 'struct IOV2[]',
						components: [
							{
								name: 'token',
								type: 'address',
								internalType: 'address',
							},
							{
								name: 'vaultId',
								type: 'bytes32',
								internalType: 'bytes32',
							},
						],
					},
					{
						name: 'validOutputs',
						type: 'tuple[]',
						internalType: 'struct IOV2[]',
						components: [
							{
								name: 'token',
								type: 'address',
								internalType: 'address',
							},
							{
								name: 'vaultId',
								type: 'bytes32',
								internalType: 'bytes32',
							},
						],
					},
					{
						name: 'nonce',
						type: 'bytes32',
						internalType: 'bytes32',
					},
				],
			},
		],
		anonymous: false,
	},
	{
		type: 'event',
		name: 'AfterClearV2',
		inputs: [
			{
				name: 'sender',
				type: 'address',
				indexed: false,
				internalType: 'address',
			},
			{
				name: 'clearStateChange',
				type: 'tuple',
				indexed: false,
				internalType: 'struct ClearStateChangeV2',
				components: [
					{
						name: 'aliceOutput',
						type: 'bytes32',
						internalType: 'Float',
					},
					{
						name: 'bobOutput',
						type: 'bytes32',
						internalType: 'Float',
					},
					{
						name: 'aliceInput',
						type: 'bytes32',
						internalType: 'Float',
					},
					{
						name: 'bobInput',
						type: 'bytes32',
						internalType: 'Float',
					},
				],
			},
		],
		anonymous: false,
	},
	{
		type: 'event',
		name: 'ClearV3',
		inputs: [
			{
				name: 'sender',
				type: 'address',
				indexed: false,
				internalType: 'address',
			},
			{
				name: 'alice',
				type: 'tuple',
				indexed: false,
				internalType: 'struct OrderV4',
				components: [
					{
						name: 'owner',
						type: 'address',
						internalType: 'address',
					},
					{
						name: 'evaluable',
						type: 'tuple',
						internalType: 'struct EvaluableV4',
						components: [
							{
								name: 'interpreter',
								type: 'address',
								internalType: 'contract IInterpreterV4',
							},
							{
								name: 'store',
								type: 'address',
								internalType: 'contract IInterpreterStoreV3',
							},
							{
								name: 'bytecode',
								type: 'bytes',
								internalType: 'bytes',
							},
						],
					},
					{
						name: 'validInputs',
						type: 'tuple[]',
						internalType: 'struct IOV2[]',
						components: [
							{
								name: 'token',
								type: 'address',
								internalType: 'address',
							},
							{
								name: 'vaultId',
								type: 'bytes32',
								internalType: 'bytes32',
							},
						],
					},
					{
						name: 'validOutputs',
						type: 'tuple[]',
						internalType: 'struct IOV2[]',
						components: [
							{
								name: 'token',
								type: 'address',
								internalType: 'address',
							},
							{
								name: 'vaultId',
								type: 'bytes32',
								internalType: 'bytes32',
							},
						],
					},
					{
						name: 'nonce',
						type: 'bytes32',
						internalType: 'bytes32',
					},
				],
			},
			{
				name: 'bob',
				type: 'tuple',
				indexed: false,
				internalType: 'struct OrderV4',
				components: [
					{
						name: 'owner',
						type: 'address',
						internalType: 'address',
					},
					{
						name: 'evaluable',
						type: 'tuple',
						internalType: 'struct EvaluableV4',
						components: [
							{
								name: 'interpreter',
								type: 'address',
								internalType: 'contract IInterpreterV4',
							},
							{
								name: 'store',
								type: 'address',
								internalType: 'contract IInterpreterStoreV3',
							},
							{
								name: 'bytecode',
								type: 'bytes',
								internalType: 'bytes',
							},
						],
					},
					{
						name: 'validInputs',
						type: 'tuple[]',
						internalType: 'struct IOV2[]',
						components: [
							{
								name: 'token',
								type: 'address',
								internalType: 'address',
							},
							{
								name: 'vaultId',
								type: 'bytes32',
								internalType: 'bytes32',
							},
						],
					},
					{
						name: 'validOutputs',
						type: 'tuple[]',
						internalType: 'struct IOV2[]',
						components: [
							{
								name: 'token',
								type: 'address',
								internalType: 'address',
							},
							{
								name: 'vaultId',
								type: 'bytes32',
								internalType: 'bytes32',
							},
						],
					},
					{
						name: 'nonce',
						type: 'bytes32',
						internalType: 'bytes32',
					},
				],
			},
			{
				name: 'clearConfig',
				type: 'tuple',
				indexed: false,
				internalType: 'struct ClearConfigV2',
				components: [
					{
						name: 'aliceInputIOIndex',
						type: 'uint256',
						internalType: 'uint256',
					},
					{
						name: 'aliceOutputIOIndex',
						type: 'uint256',
						internalType: 'uint256',
					},
					{
						name: 'bobInputIOIndex',
						type: 'uint256',
						internalType: 'uint256',
					},
					{
						name: 'bobOutputIOIndex',
						type: 'uint256',
						internalType: 'uint256',
					},
					{
						name: 'aliceBountyVaultId',
						type: 'bytes32',
						internalType: 'bytes32',
					},
					{
						name: 'bobBountyVaultId',
						type: 'bytes32',
						internalType: 'bytes32',
					},
				],
			},
		],
		anonymous: false,
	},
	{
		type: 'event',
		name: 'ContextV2',
		inputs: [
			{
				name: 'sender',
				type: 'address',
				indexed: false,
				internalType: 'address',
			},
			{
				name: 'context',
				type: 'bytes32[][]',
				indexed: false,
				internalType: 'bytes32[][]',
			},
		],
		anonymous: false,
	},
	{
		type: 'event',
		name: 'DepositV2',
		inputs: [
			{
				name: 'sender',
				type: 'address',
				indexed: false,
				internalType: 'address',
			},
			{
				name: 'token',
				type: 'address',
				indexed: false,
				internalType: 'address',
			},
			{
				name: 'vaultId',
				type: 'bytes32',
				indexed: false,
				internalType: 'bytes32',
			},
			{
				name: 'depositAmountUint256',
				type: 'uint256',
				indexed: false,
				internalType: 'uint256',
			},
		],
		anonymous: false,
	},
	{
		type: 'event',
		name: 'OrderExceedsMaxRatio',
		inputs: [
			{
				name: 'sender',
				type: 'address',
				indexed: false,
				internalType: 'address',
			},
			{
				name: 'owner',
				type: 'address',
				indexed: false,
				internalType: 'address',
			},
			{
				name: 'orderHash',
				type: 'bytes32',
				indexed: false,
				internalType: 'bytes32',
			},
		],
		anonymous: false,
	},
	{
		type: 'event',
		name: 'OrderNotFound',
		inputs: [
			{
				name: 'sender',
				type: 'address',
				indexed: false,
				internalType: 'address',
			},
			{
				name: 'owner',
				type: 'address',
				indexed: false,
				internalType: 'address',
			},
			{
				name: 'orderHash',
				type: 'bytes32',
				indexed: false,
				internalType: 'bytes32',
			},
		],
		anonymous: false,
	},
	{
		type: 'event',
		name: 'OrderZeroAmount',
		inputs: [
			{
				name: 'sender',
				type: 'address',
				indexed: false,
				internalType: 'address',
			},
			{
				name: 'owner',
				type: 'address',
				indexed: false,
				internalType: 'address',
			},
			{
				name: 'orderHash',
				type: 'bytes32',
				indexed: false,
				internalType: 'bytes32',
			},
		],
		anonymous: false,
	},
	{
		type: 'event',
		name: 'RemoveOrderV3',
		inputs: [
			{
				name: 'sender',
				type: 'address',
				indexed: false,
				internalType: 'address',
			},
			{
				name: 'orderHash',
				type: 'bytes32',
				indexed: false,
				internalType: 'bytes32',
			},
			{
				name: 'order',
				type: 'tuple',
				indexed: false,
				internalType: 'struct OrderV4',
				components: [
					{
						name: 'owner',
						type: 'address',
						internalType: 'address',
					},
					{
						name: 'evaluable',
						type: 'tuple',
						internalType: 'struct EvaluableV4',
						components: [
							{
								name: 'interpreter',
								type: 'address',
								internalType: 'contract IInterpreterV4',
							},
							{
								name: 'store',
								type: 'address',
								internalType: 'contract IInterpreterStoreV3',
							},
							{
								name: 'bytecode',
								type: 'bytes',
								internalType: 'bytes',
							},
						],
					},
					{
						name: 'validInputs',
						type: 'tuple[]',
						internalType: 'struct IOV2[]',
						components: [
							{
								name: 'token',
								type: 'address',
								internalType: 'address',
							},
							{
								name: 'vaultId',
								type: 'bytes32',
								internalType: 'bytes32',
							},
						],
					},
					{
						name: 'validOutputs',
						type: 'tuple[]',
						internalType: 'struct IOV2[]',
						components: [
							{
								name: 'token',
								type: 'address',
								internalType: 'address',
							},
							{
								name: 'vaultId',
								type: 'bytes32',
								internalType: 'bytes32',
							},
						],
					},
					{
						name: 'nonce',
						type: 'bytes32',
						internalType: 'bytes32',
					},
				],
			},
		],
		anonymous: false,
	},
	{
		type: 'event',
		name: 'TakeOrderV3',
		inputs: [
			{
				name: 'sender',
				type: 'address',
				indexed: false,
				internalType: 'address',
			},
			{
				name: 'config',
				type: 'tuple',
				indexed: false,
				internalType: 'struct TakeOrderConfigV4',
				components: [
					{
						name: 'order',
						type: 'tuple',
						internalType: 'struct OrderV4',
						components: [
							{
								name: 'owner',
								type: 'address',
								internalType: 'address',
							},
							{
								name: 'evaluable',
								type: 'tuple',
								internalType: 'struct EvaluableV4',
								components: [
									{
										name: 'interpreter',
										type: 'address',
										internalType: 'contract IInterpreterV4',
									},
									{
										name: 'store',
										type: 'address',
										internalType: 'contract IInterpreterStoreV3',
									},
									{
										name: 'bytecode',
										type: 'bytes',
										internalType: 'bytes',
									},
								],
							},
							{
								name: 'validInputs',
								type: 'tuple[]',
								internalType: 'struct IOV2[]',
								components: [
									{
										name: 'token',
										type: 'address',
										internalType: 'address',
									},
									{
										name: 'vaultId',
										type: 'bytes32',
										internalType: 'bytes32',
									},
								],
							},
							{
								name: 'validOutputs',
								type: 'tuple[]',
								internalType: 'struct IOV2[]',
								components: [
									{
										name: 'token',
										type: 'address',
										internalType: 'address',
									},
									{
										name: 'vaultId',
										type: 'bytes32',
										internalType: 'bytes32',
									},
								],
							},
							{
								name: 'nonce',
								type: 'bytes32',
								internalType: 'bytes32',
							},
						],
					},
					{
						name: 'inputIOIndex',
						type: 'uint256',
						internalType: 'uint256',
					},
					{
						name: 'outputIOIndex',
						type: 'uint256',
						internalType: 'uint256',
					},
					{
						name: 'signedContext',
						type: 'tuple[]',
						internalType: 'struct SignedContextV1[]',
						components: [
							{
								name: 'signer',
								type: 'address',
								internalType: 'address',
							},
							{
								name: 'context',
								type: 'bytes32[]',
								internalType: 'bytes32[]',
							},
							{
								name: 'signature',
								type: 'bytes',
								internalType: 'bytes',
							},
						],
					},
				],
			},
			{
				name: 'input',
				type: 'bytes32',
				indexed: false,
				internalType: 'Float',
			},
			{
				name: 'output',
				type: 'bytes32',
				indexed: false,
				internalType: 'Float',
			},
		],
		anonymous: false,
	},
	{
		type: 'event',
		name: 'WithdrawV2',
		inputs: [
			{
				name: 'sender',
				type: 'address',
				indexed: false,
				internalType: 'address',
			},
			{
				name: 'token',
				type: 'address',
				indexed: false,
				internalType: 'address',
			},
			{
				name: 'vaultId',
				type: 'bytes32',
				indexed: false,
				internalType: 'bytes32',
			},
			{
				name: 'targetAmount',
				type: 'bytes32',
				indexed: false,
				internalType: 'Float',
			},
			{
				name: 'withdrawAmount',
				type: 'bytes32',
				indexed: false,
				internalType: 'Float',
			},
			{
				name: 'withdrawAmountUint256',
				type: 'uint256',
				indexed: false,
				internalType: 'uint256',
			},
		],
		anonymous: false,
	},
	{
		type: 'function',
		name: 'addOrder4',
		inputs: [
			{
				name: 'config',
				type: 'tuple',
				internalType: 'struct OrderConfigV4',
				components: [
					{
						name: 'evaluable',
						type: 'tuple',
						internalType: 'struct EvaluableV4',
						components: [
							{
								name: 'interpreter',
								type: 'address',
								internalType: 'contract IInterpreterV4',
							},
							{
								name: 'store',
								type: 'address',
								internalType: 'contract IInterpreterStoreV3',
							},
							{
								name: 'bytecode',
								type: 'bytes',
								internalType: 'bytes',
							},
						],
					},
					{
						name: 'validInputs',
						type: 'tuple[]',
						internalType: 'struct IOV2[]',
						components: [
							{
								name: 'token',
								type: 'address',
								internalType: 'address',
							},
							{
								name: 'vaultId',
								type: 'bytes32',
								internalType: 'bytes32',
							},
						],
					},
					{
						name: 'validOutputs',
						type: 'tuple[]',
						internalType: 'struct IOV2[]',
						components: [
							{
								name: 'token',
								type: 'address',
								internalType: 'address',
							},
							{
								name: 'vaultId',
								type: 'bytes32',
								internalType: 'bytes32',
							},
						],
					},
					{
						name: 'nonce',
						type: 'bytes32',
						internalType: 'bytes32',
					},
					{
						name: 'secret',
						type: 'bytes32',
						internalType: 'bytes32',
					},
					{
						name: 'meta',
						type: 'bytes',
						internalType: 'bytes',
					},
				],
			},
			{
				name: 'tasks',
				type: 'tuple[]',
				internalType: 'struct TaskV2[]',
				components: [
					{
						name: 'evaluable',
						type: 'tuple',
						internalType: 'struct EvaluableV4',
						components: [
							{
								name: 'interpreter',
								type: 'address',
								internalType: 'contract IInterpreterV4',
							},
							{
								name: 'store',
								type: 'address',
								internalType: 'contract IInterpreterStoreV3',
							},
							{
								name: 'bytecode',
								type: 'bytes',
								internalType: 'bytes',
							},
						],
					},
					{
						name: 'signedContext',
						type: 'tuple[]',
						internalType: 'struct SignedContextV1[]',
						components: [
							{
								name: 'signer',
								type: 'address',
								internalType: 'address',
							},
							{
								name: 'context',
								type: 'bytes32[]',
								internalType: 'bytes32[]',
							},
							{
								name: 'signature',
								type: 'bytes',
								internalType: 'bytes',
							},
						],
					},
				],
			},
		],
		outputs: [
			{
				name: 'stateChanged',
				type: 'bool',
				internalType: 'bool',
			},
		],
		stateMutability: 'nonpayable',
	},
	{
		type: 'function',
		name: 'clear3',
		inputs: [
			{
				name: 'alice',
				type: 'tuple',
				internalType: 'struct OrderV4',
				components: [
					{
						name: 'owner',
						type: 'address',
						internalType: 'address',
					},
					{
						name: 'evaluable',
						type: 'tuple',
						internalType: 'struct EvaluableV4',
						components: [
							{
								name: 'interpreter',
								type: 'address',
								internalType: 'contract IInterpreterV4',
							},
							{
								name: 'store',
								type: 'address',
								internalType: 'contract IInterpreterStoreV3',
							},
							{
								name: 'bytecode',
								type: 'bytes',
								internalType: 'bytes',
							},
						],
					},
					{
						name: 'validInputs',
						type: 'tuple[]',
						internalType: 'struct IOV2[]',
						components: [
							{
								name: 'token',
								type: 'address',
								internalType: 'address',
							},
							{
								name: 'vaultId',
								type: 'bytes32',
								internalType: 'bytes32',
							},
						],
					},
					{
						name: 'validOutputs',
						type: 'tuple[]',
						internalType: 'struct IOV2[]',
						components: [
							{
								name: 'token',
								type: 'address',
								internalType: 'address',
							},
							{
								name: 'vaultId',
								type: 'bytes32',
								internalType: 'bytes32',
							},
						],
					},
					{
						name: 'nonce',
						type: 'bytes32',
						internalType: 'bytes32',
					},
				],
			},
			{
				name: 'bob',
				type: 'tuple',
				internalType: 'struct OrderV4',
				components: [
					{
						name: 'owner',
						type: 'address',
						internalType: 'address',
					},
					{
						name: 'evaluable',
						type: 'tuple',
						internalType: 'struct EvaluableV4',
						components: [
							{
								name: 'interpreter',
								type: 'address',
								internalType: 'contract IInterpreterV4',
							},
							{
								name: 'store',
								type: 'address',
								internalType: 'contract IInterpreterStoreV3',
							},
							{
								name: 'bytecode',
								type: 'bytes',
								internalType: 'bytes',
							},
						],
					},
					{
						name: 'validInputs',
						type: 'tuple[]',
						internalType: 'struct IOV2[]',
						components: [
							{
								name: 'token',
								type: 'address',
								internalType: 'address',
							},
							{
								name: 'vaultId',
								type: 'bytes32',
								internalType: 'bytes32',
							},
						],
					},
					{
						name: 'validOutputs',
						type: 'tuple[]',
						internalType: 'struct IOV2[]',
						components: [
							{
								name: 'token',
								type: 'address',
								internalType: 'address',
							},
							{
								name: 'vaultId',
								type: 'bytes32',
								internalType: 'bytes32',
							},
						],
					},
					{
						name: 'nonce',
						type: 'bytes32',
						internalType: 'bytes32',
					},
				],
			},
			{
				name: 'clearConfig',
				type: 'tuple',
				internalType: 'struct ClearConfigV2',
				components: [
					{
						name: 'aliceInputIOIndex',
						type: 'uint256',
						internalType: 'uint256',
					},
					{
						name: 'aliceOutputIOIndex',
						type: 'uint256',
						internalType: 'uint256',
					},
					{
						name: 'bobInputIOIndex',
						type: 'uint256',
						internalType: 'uint256',
					},
					{
						name: 'bobOutputIOIndex',
						type: 'uint256',
						internalType: 'uint256',
					},
					{
						name: 'aliceBountyVaultId',
						type: 'bytes32',
						internalType: 'bytes32',
					},
					{
						name: 'bobBountyVaultId',
						type: 'bytes32',
						internalType: 'bytes32',
					},
				],
			},
			{
				name: 'aliceSignedContext',
				type: 'tuple[]',
				internalType: 'struct SignedContextV1[]',
				components: [
					{
						name: 'signer',
						type: 'address',
						internalType: 'address',
					},
					{
						name: 'context',
						type: 'bytes32[]',
						internalType: 'bytes32[]',
					},
					{
						name: 'signature',
						type: 'bytes',
						internalType: 'bytes',
					},
				],
			},
			{
				name: 'bobSignedContext',
				type: 'tuple[]',
				internalType: 'struct SignedContextV1[]',
				components: [
					{
						name: 'signer',
						type: 'address',
						internalType: 'address',
					},
					{
						name: 'context',
						type: 'bytes32[]',
						internalType: 'bytes32[]',
					},
					{
						name: 'signature',
						type: 'bytes',
						internalType: 'bytes',
					},
				],
			},
		],
		outputs: [],
		stateMutability: 'nonpayable',
	},
	{
		type: 'function',
		name: 'deposit4',
		inputs: [
			{
				name: 'token',
				type: 'address',
				internalType: 'address',
			},
			{
				name: 'vaultId',
				type: 'bytes32',
				internalType: 'bytes32',
			},
			{
				name: 'depositAmount',
				type: 'bytes32',
				internalType: 'Float',
			},
			{
				name: 'tasks',
				type: 'tuple[]',
				internalType: 'struct TaskV2[]',
				components: [
					{
						name: 'evaluable',
						type: 'tuple',
						internalType: 'struct EvaluableV4',
						components: [
							{
								name: 'interpreter',
								type: 'address',
								internalType: 'contract IInterpreterV4',
							},
							{
								name: 'store',
								type: 'address',
								internalType: 'contract IInterpreterStoreV3',
							},
							{
								name: 'bytecode',
								type: 'bytes',
								internalType: 'bytes',
							},
						],
					},
					{
						name: 'signedContext',
						type: 'tuple[]',
						internalType: 'struct SignedContextV1[]',
						components: [
							{
								name: 'signer',
								type: 'address',
								internalType: 'address',
							},
							{
								name: 'context',
								type: 'bytes32[]',
								internalType: 'bytes32[]',
							},
							{
								name: 'signature',
								type: 'bytes',
								internalType: 'bytes',
							},
						],
					},
				],
			},
		],
		outputs: [],
		stateMutability: 'nonpayable',
	},
	{
		type: 'function',
		name: 'entask2',
		inputs: [
			{
				name: 'tasks',
				type: 'tuple[]',
				internalType: 'struct TaskV2[]',
				components: [
					{
						name: 'evaluable',
						type: 'tuple',
						internalType: 'struct EvaluableV4',
						components: [
							{
								name: 'interpreter',
								type: 'address',
								internalType: 'contract IInterpreterV4',
							},
							{
								name: 'store',
								type: 'address',
								internalType: 'contract IInterpreterStoreV3',
							},
							{
								name: 'bytecode',
								type: 'bytes',
								internalType: 'bytes',
							},
						],
					},
					{
						name: 'signedContext',
						type: 'tuple[]',
						internalType: 'struct SignedContextV1[]',
						components: [
							{
								name: 'signer',
								type: 'address',
								internalType: 'address',
							},
							{
								name: 'context',
								type: 'bytes32[]',
								internalType: 'bytes32[]',
							},
							{
								name: 'signature',
								type: 'bytes',
								internalType: 'bytes',
							},
						],
					},
				],
			},
		],
		outputs: [],
		stateMutability: 'nonpayable',
	},
	{
		type: 'function',
		name: 'flashFee',
		inputs: [
			{
				name: 'token',
				type: 'address',
				internalType: 'address',
			},
			{
				name: 'amount',
				type: 'uint256',
				internalType: 'uint256',
			},
		],
		outputs: [
			{
				name: '',
				type: 'uint256',
				internalType: 'uint256',
			},
		],
		stateMutability: 'view',
	},
	{
		type: 'function',
		name: 'flashLoan',
		inputs: [
			{
				name: 'receiver',
				type: 'address',
				internalType: 'contract IERC3156FlashBorrower',
			},
			{
				name: 'token',
				type: 'address',
				internalType: 'address',
			},
			{
				name: 'amount',
				type: 'uint256',
				internalType: 'uint256',
			},
			{
				name: 'data',
				type: 'bytes',
				internalType: 'bytes',
			},
		],
		outputs: [
			{
				name: '',
				type: 'bool',
				internalType: 'bool',
			},
		],
		stateMutability: 'nonpayable',
	},
	{
		type: 'function',
		name: 'maxFlashLoan',
		inputs: [
			{
				name: 'token',
				type: 'address',
				internalType: 'address',
			},
		],
		outputs: [
			{
				name: '',
				type: 'uint256',
				internalType: 'uint256',
			},
		],
		stateMutability: 'view',
	},
	{
		type: 'function',
		name: 'orderExists',
		inputs: [
			{
				name: 'orderHash',
				type: 'bytes32',
				internalType: 'bytes32',
			},
		],
		outputs: [
			{
				name: 'exists',
				type: 'bool',
				internalType: 'bool',
			},
		],
		stateMutability: 'view',
	},
	{
		type: 'function',
		name: 'quote2',
		inputs: [
			{
				name: 'quoteConfig',
				type: 'tuple',
				internalType: 'struct QuoteV2',
				components: [
					{
						name: 'order',
						type: 'tuple',
						internalType: 'struct OrderV4',
						components: [
							{
								name: 'owner',
								type: 'address',
								internalType: 'address',
							},
							{
								name: 'evaluable',
								type: 'tuple',
								internalType: 'struct EvaluableV4',
								components: [
									{
										name: 'interpreter',
										type: 'address',
										internalType: 'contract IInterpreterV4',
									},
									{
										name: 'store',
										type: 'address',
										internalType: 'contract IInterpreterStoreV3',
									},
									{
										name: 'bytecode',
										type: 'bytes',
										internalType: 'bytes',
									},
								],
							},
							{
								name: 'validInputs',
								type: 'tuple[]',
								internalType: 'struct IOV2[]',
								components: [
									{
										name: 'token',
										type: 'address',
										internalType: 'address',
									},
									{
										name: 'vaultId',
										type: 'bytes32',
										internalType: 'bytes32',
									},
								],
							},
							{
								name: 'validOutputs',
								type: 'tuple[]',
								internalType: 'struct IOV2[]',
								components: [
									{
										name: 'token',
										type: 'address',
										internalType: 'address',
									},
									{
										name: 'vaultId',
										type: 'bytes32',
										internalType: 'bytes32',
									},
								],
							},
							{
								name: 'nonce',
								type: 'bytes32',
								internalType: 'bytes32',
							},
						],
					},
					{
						name: 'inputIOIndex',
						type: 'uint256',
						internalType: 'uint256',
					},
					{
						name: 'outputIOIndex',
						type: 'uint256',
						internalType: 'uint256',
					},
					{
						name: 'signedContext',
						type: 'tuple[]',
						internalType: 'struct SignedContextV1[]',
						components: [
							{
								name: 'signer',
								type: 'address',
								internalType: 'address',
							},
							{
								name: 'context',
								type: 'bytes32[]',
								internalType: 'bytes32[]',
							},
							{
								name: 'signature',
								type: 'bytes',
								internalType: 'bytes',
							},
						],
					},
				],
			},
		],
		outputs: [
			{
				name: 'exists',
				type: 'bool',
				internalType: 'bool',
			},
			{
				name: 'outputMax',
				type: 'bytes32',
				internalType: 'Float',
			},
			{
				name: 'ioRatio',
				type: 'bytes32',
				internalType: 'Float',
			},
		],
		stateMutability: 'view',
	},
	{
		type: 'function',
		name: 'removeOrder3',
		inputs: [
			{
				name: 'order',
				type: 'tuple',
				internalType: 'struct OrderV4',
				components: [
					{
						name: 'owner',
						type: 'address',
						internalType: 'address',
					},
					{
						name: 'evaluable',
						type: 'tuple',
						internalType: 'struct EvaluableV4',
						components: [
							{
								name: 'interpreter',
								type: 'address',
								internalType: 'contract IInterpreterV4',
							},
							{
								name: 'store',
								type: 'address',
								internalType: 'contract IInterpreterStoreV3',
							},
							{
								name: 'bytecode',
								type: 'bytes',
								internalType: 'bytes',
							},
						],
					},
					{
						name: 'validInputs',
						type: 'tuple[]',
						internalType: 'struct IOV2[]',
						components: [
							{
								name: 'token',
								type: 'address',
								internalType: 'address',
							},
							{
								name: 'vaultId',
								type: 'bytes32',
								internalType: 'bytes32',
							},
						],
					},
					{
						name: 'validOutputs',
						type: 'tuple[]',
						internalType: 'struct IOV2[]',
						components: [
							{
								name: 'token',
								type: 'address',
								internalType: 'address',
							},
							{
								name: 'vaultId',
								type: 'bytes32',
								internalType: 'bytes32',
							},
						],
					},
					{
						name: 'nonce',
						type: 'bytes32',
						internalType: 'bytes32',
					},
				],
			},
			{
				name: 'tasks',
				type: 'tuple[]',
				internalType: 'struct TaskV2[]',
				components: [
					{
						name: 'evaluable',
						type: 'tuple',
						internalType: 'struct EvaluableV4',
						components: [
							{
								name: 'interpreter',
								type: 'address',
								internalType: 'contract IInterpreterV4',
							},
							{
								name: 'store',
								type: 'address',
								internalType: 'contract IInterpreterStoreV3',
							},
							{
								name: 'bytecode',
								type: 'bytes',
								internalType: 'bytes',
							},
						],
					},
					{
						name: 'signedContext',
						type: 'tuple[]',
						internalType: 'struct SignedContextV1[]',
						components: [
							{
								name: 'signer',
								type: 'address',
								internalType: 'address',
							},
							{
								name: 'context',
								type: 'bytes32[]',
								internalType: 'bytes32[]',
							},
							{
								name: 'signature',
								type: 'bytes',
								internalType: 'bytes',
							},
						],
					},
				],
			},
		],
		outputs: [
			{
				name: 'stateChanged',
				type: 'bool',
				internalType: 'bool',
			},
		],
		stateMutability: 'nonpayable',
	},
	{
		type: 'function',
		name: 'takeOrders4',
		inputs: [
			{
				name: 'config',
				type: 'tuple',
				internalType: 'struct TakeOrdersConfigV5',
				components: [
					{
						name: 'minimumIO',
						type: 'bytes32',
						internalType: 'Float',
					},
					{
						name: 'maximumIO',
						type: 'bytes32',
						internalType: 'Float',
					},
					{
						name: 'maximumIORatio',
						type: 'bytes32',
						internalType: 'Float',
					},
					{
						name: 'IOIsInput',
						type: 'bool',
						internalType: 'bool',
					},
					{
						name: 'orders',
						type: 'tuple[]',
						internalType: 'struct TakeOrderConfigV4[]',
						components: [
							{
								name: 'order',
								type: 'tuple',
								internalType: 'struct OrderV4',
								components: [
									{
										name: 'owner',
										type: 'address',
										internalType: 'address',
									},
									{
										name: 'evaluable',
										type: 'tuple',
										internalType: 'struct EvaluableV4',
										components: [
											{
												name: 'interpreter',
												type: 'address',
												internalType: 'contract IInterpreterV4',
											},
											{
												name: 'store',
												type: 'address',
												internalType: 'contract IInterpreterStoreV3',
											},
											{
												name: 'bytecode',
												type: 'bytes',
												internalType: 'bytes',
											},
										],
									},
									{
										name: 'validInputs',
										type: 'tuple[]',
										internalType: 'struct IOV2[]',
										components: [
											{
												name: 'token',
												type: 'address',
												internalType: 'address',
											},
											{
												name: 'vaultId',
												type: 'bytes32',
												internalType: 'bytes32',
											},
										],
									},
									{
										name: 'validOutputs',
										type: 'tuple[]',
										internalType: 'struct IOV2[]',
										components: [
											{
												name: 'token',
												type: 'address',
												internalType: 'address',
											},
											{
												name: 'vaultId',
												type: 'bytes32',
												internalType: 'bytes32',
											},
										],
									},
									{
										name: 'nonce',
										type: 'bytes32',
										internalType: 'bytes32',
									},
								],
							},
							{
								name: 'inputIOIndex',
								type: 'uint256',
								internalType: 'uint256',
							},
							{
								name: 'outputIOIndex',
								type: 'uint256',
								internalType: 'uint256',
							},
							{
								name: 'signedContext',
								type: 'tuple[]',
								internalType: 'struct SignedContextV1[]',
								components: [
									{
										name: 'signer',
										type: 'address',
										internalType: 'address',
									},
									{
										name: 'context',
										type: 'bytes32[]',
										internalType: 'bytes32[]',
									},
									{
										name: 'signature',
										type: 'bytes',
										internalType: 'bytes',
									},
								],
							},
						],
					},
					{
						name: 'data',
						type: 'bytes',
						internalType: 'bytes',
					},
				],
			},
		],
		outputs: [
			{
				name: 'totalTakerInput',
				type: 'bytes32',
				internalType: 'Float',
			},
			{
				name: 'totalTakerOutput',
				type: 'bytes32',
				internalType: 'Float',
			},
		],
		stateMutability: 'nonpayable',
	},
	{
		type: 'function',
		name: 'vaultBalance2',
		inputs: [
			{
				name: 'owner',
				type: 'address',
				internalType: 'address',
			},
			{
				name: 'token',
				type: 'address',
				internalType: 'address',
			},
			{
				name: 'vaultId',
				type: 'bytes32',
				internalType: 'bytes32',
			},
		],
		outputs: [
			{
				name: 'balance',
				type: 'bytes32',
				internalType: 'Float',
			},
		],
		stateMutability: 'view',
	},
	{
		type: 'function',
		name: 'withdraw4',
		inputs: [
			{
				name: 'token',
				type: 'address',
				internalType: 'address',
			},
			{
				name: 'vaultId',
				type: 'bytes32',
				internalType: 'bytes32',
			},
			{
				name: 'targetAmount',
				type: 'bytes32',
				internalType: 'Float',
			},
			{
				name: 'tasks',
				type: 'tuple[]',
				internalType: 'struct TaskV2[]',
				components: [
					{
						name: 'evaluable',
						type: 'tuple',
						internalType: 'struct EvaluableV4',
						components: [
							{
								name: 'interpreter',
								type: 'address',
								internalType: 'contract IInterpreterV4',
							},
							{
								name: 'store',
								type: 'address',
								internalType: 'contract IInterpreterStoreV3',
							},
							{
								name: 'bytecode',
								type: 'bytes',
								internalType: 'bytes',
							},
						],
					},
					{
						name: 'signedContext',
						type: 'tuple[]',
						internalType: 'struct SignedContextV1[]',
						components: [
							{
								name: 'signer',
								type: 'address',
								internalType: 'address',
							},
							{
								name: 'context',
								type: 'bytes32[]',
								internalType: 'bytes32[]',
							},
							{
								name: 'signature',
								type: 'bytes',
								internalType: 'bytes',
							},
						],
					},
				],
			},
		],
		outputs: [],
		stateMutability: 'nonpayable',
	},
] as const

//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
// erc20
//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

export const erc20Abi = [
  {
    type: 'event',
    inputs: [
      { name: 'owner', type: 'address', indexed: true },
      { name: 'spender', type: 'address', indexed: true },
      { name: 'value', type: 'uint256', indexed: false },
    ],
    name: 'Approval',
  },
  {
    type: 'event',
    inputs: [
      { name: 'from', type: 'address', indexed: true },
      { name: 'to', type: 'address', indexed: true },
      { name: 'value', type: 'uint256', indexed: false },
    ],
    name: 'Transfer',
  },
  {
    type: 'function',
    inputs: [
      { name: 'owner', type: 'address' },
      { name: 'spender', type: 'address' },
    ],
    name: 'allowance',
    outputs: [{ type: 'uint256' }],
    stateMutability: 'view',
  },
  {
    type: 'function',
    inputs: [
      { name: 'spender', type: 'address' },
      { name: 'amount', type: 'uint256' },
    ],
    name: 'approve',
    outputs: [{ type: 'bool' }],
    stateMutability: 'nonpayable',
  },
  {
    type: 'function',
    inputs: [{ name: 'account', type: 'address' }],
    name: 'balanceOf',
    outputs: [{ type: 'uint256' }],
    stateMutability: 'view',
  },
  {
    type: 'function',
    inputs: [],
    name: 'decimals',
    outputs: [{ type: 'uint8' }],
    stateMutability: 'view',
  },
  {
    type: 'function',
    inputs: [],
    name: 'name',
    outputs: [{ type: 'string' }],
    stateMutability: 'view',
  },
  {
    type: 'function',
    inputs: [],
    name: 'symbol',
    outputs: [{ type: 'string' }],
    stateMutability: 'view',
  },
  {
    type: 'function',
    inputs: [],
    name: 'totalSupply',
    outputs: [{ type: 'uint256' }],
    stateMutability: 'view',
  },
  {
    type: 'function',
    inputs: [
      { name: 'recipient', type: 'address' },
      { name: 'amount', type: 'uint256' },
    ],
    name: 'transfer',
    outputs: [{ type: 'bool' }],
    stateMutability: 'nonpayable',
  },
  {
    type: 'function',
    inputs: [
      { name: 'sender', type: 'address' },
      { name: 'recipient', type: 'address' },
      { name: 'amount', type: 'uint256' },
    ],
    name: 'transferFrom',
    outputs: [{ type: 'bool' }],
    stateMutability: 'nonpayable',
  },
] as const

