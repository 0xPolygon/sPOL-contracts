# sPOL

Liquid staking protocol for POL on Polygon PoS. Users deposit POL, receive sPOL (a non-rebasing ERC-20 whose value accrues via exchange rate appreciation). The protocol delegates across managed validators, compounds rewards, and operates on both Ethereum (L1) and Polygon (L2).

## Quick Reference

- **Solidity 0.8.30**, Prague EVM target
- **OpenZeppelin 5.5.0** (upgradeable + standard)
- **Foundry** with Soldeer for dependency management
- `forge soldeer install && forge build && forge test`
- `.env` needs `DEPLOYER_PRIVATE_KEY`, `L1_RPC_URL`, `L2_RPC_URL`

## Architecture

### Contracts

| Contract | Chain | Upgradeable | Role |
|---|---|---|---|
| `sPOLController` | L1 | Yes | Core: validator delegation, POL/sPOL conversions, reward compounding, unbonding queue, fee collection |
| `sPOL` | L1 | Yes | ERC-20 token. Mint/burn gated to controller only. Supports EIP-2612 permits |
| `sPOLMessenger` | L1 | Yes | Bridge coordinator. Relays exchange rate updates to L2, processes migration and backfill proofs |
| `sPOLChild` | L2 | Yes | L2 sPOL ERC-20 + buy entry point. Caches L1 exchange rate, applies safety fee, coordinates POL migration to L1 |
| `PolBridger` | L1+L2 | No | POL bridging helper. Must be deployed at same address on both chains (Plasma bridge requirement) |
| `MsgCoder` | -- | -- | Abstract. ABI encode/decode helpers for cross-chain messages. Inherited by sPOLChild and sPOLMessenger |

### Cross-Chain Messaging

**L1 to L2 (automatic):** StateSender emits event, Polygon validators relay it, StateReceiver calls `onStateReceive()`. Failed deliveries can be retried by anyone via `replayFailedStateSync()`.

**L2 to L1 (manual):** Polygon PoS submits checkpoints (~20-30 min). Anyone can submit inclusion proof to L1 to execute the action. All L1 proof submissions are permissionless.

### Exchange Rate

Non-rebasing: 1 sPOL represents a growing share of the staked POL pool.

```
POL → sPOL: amount * totalsPOLBalance / (totaldPOLBalance - feedPOLBalance)
sPOL → POL: amount * (totaldPOLBalance - feedPOLBalance) / totalsPOLBalance
```

The rate only goes up. `feedPOLBalance` tracks accrued protocol fees not yet minted as sPOL -- it inflates `totaldPOLBalance` without inflating supply, causing the rate to improve as rewards compound.

On L2, a **safety fee** (default 0.3%) discounts buys to protect against stale exchange rate arbitrage. L2 rate is updated via `EXCHANGE_UPDATE` state sync messages. If the incoming rate would decline (cross-multiplication check: `updatedDPOL * oldSPOL < oldDPOL * updatedSPOL`), the update is silently dropped and an event is emitted.

### Migration

Reconciliation between L1 and L2 is triggered by `balanceWithL1()` (restricted).

**Migration** (surplus POL on L2 needs staking on L1): L2 burns POL via PolBridger, sends `L2_MIGRATION_REQUEST`. L1 messenger stakes it via controller, bridges minted sPOL back to L2. sPOLChild's `deposit()` recognizes the returning sPOL and completes migration without extra minting.
Only one migration can be active at a time.

### Validator Management

Validators have states: `INACTIVE`, `ACTIVE`, `DEACTIVATED`. Only active validators receive deposits. 

`_selectValidators()` uses a greedy algorithm: tries to fit in a single validator first, then spreads across multiple. Honors target `depositShare` weights (must sum to 100% across active validators) with a `maxDivergence` tolerance.

Restaking (`restakeValidator`, `restakeAllActiveValidators`) is permissionless. Protocol fee is taken on each restake and tracked in `feedPOLBalance`. Fees are materialized as sPOL when `takeFee()` is called.

### Unbonding Queue

Sell operations queue withdrawals per-user via a FIFO `DoubleEndedQueue` of nonces. `withdrawPOL()` is permissionless (anyone can trigger it for any user, but POL always goes to the user).

## Key Patterns

- **Access control:** `AccessManagedUpgradeable` everywhere except sPOL.sol which uses simpler `onlyController`. All proxies' ProxyAdmins are owned by the AccessManager.
- **Reentrancy:** `ReentrancyGuardTransient` (OZ transient storage variant, camelCase `nonReentrant`) on all contracts.
- **Permits:** Both buy and sell flows support EIP-2612. sPOL's `consumePermit` resets allowance to 0 after use. Controller's `_applyPermit` verifies nonce incremented by exactly 1.
- **Invalid L2 messages:** sPOLChild emits events and returns (no revert) on invalid message types. No `failedStateSync` risk.
- **CREATE2 deployment:** All contracts use deterministic CREATE2 with salted names. This allows pre-calculating L2 addresses before deploying (needed for L1 messenger constructor).

## Important Invariants and Constraints

- Exchange rate must be monotonically increasing. No slashing assumed.
- dPOL:POL rate is always 1:1 (`ValidatorShare.exchangeRate()` always returns `1e29`).
- `rewardFee` must never be 100% (1000 per-mill) -- causes division by zero.
- `reloadAllValidatorInfo()` must not be called when total sPOL supply is zero.
- Safety fee calibration: must satisfy `safetyFee >= expected rate change during maxExchangeRateUpdateDelay`.
- Restaking should happen before bridging exchange rate to L2 (not enforced in code).
- Initial sPOL seed deposit must be large enough to prevent first-depositor inflation attacks, permanently locked, and never bridged to L2.

## Deployment

Deployment config is in `script/input.json` with two scenarios:
- `ethereum-polygon` -- mainnet (Ethereum L1 chain 1, Polygon L2 chain 137)
- `sepolia-amoy` -- testnet (Sepolia chain 11155111, Amoy chain 80002)

Deploy flow (`script/Deploy.s.sol`): forks L1 first (deploys AccessManager, PolBridger, proxies with dummy impl, then real impls, upgrades, initializes), then forks L2 (same pattern for sPOLChild). Uses `ConfigLoader.s.sol` to read `input.json`.

Post-deploy sequence (order matters):
1. `script/SetupInitialValidators.s.sol` -- configure initial validator set
2. `script/operations/EnableL2.s.sol` -- enables L2 operations
3. `script/roleManagement/` -- assign ExchangeRateUpdater and Pauser roles
4. `script/RevokeDeployer.s.sol` -- revoke deployer access (last step, irreversible)

## Testing

```sh
forge test                    # unit + integration
forge test --match-path "test/unit/*"  # unit only
forge coverage --no-match-coverage "(script|mocks|msg|integration)"
```

Integration tests fork mainnet and require RPC URLs. Unit tests use mocks in `test/mocks/`.

## Working in This Codebase

- **Upgradeable contracts:** sPOLController, sPOLChild, sPOLMessenger, and sPOL use transparent proxies. Never reorder, remove, or change the type of existing storage variables. New storage goes at the end. Check existing `deprecated_` slots in sPOLChild for the pattern.
- **Verify builds:** always run `forge build` after changes. Run `forge test` before considering work done.
- **Cross-chain changes:** modifications to message encoding/decoding (`MsgCoder`) or state sync handling must be coordinated across L1 and L2 contracts simultaneously.
- **Addresses live in `script/`:** currently deployed addresses are in `script/deployment-mainnet.json` and `script/deployment-testnet.json`. Deploy config in `script/input.json`.

## Design Tradeoffs Worth Knowing

1. **L2 operates optimistically** -- local accounting allows immediate user interaction without waiting for L1 confirmation. The safety fee and staleness timeout are the guardrails. If safety fee is miscalibrated, L2 becomes cheaper than L1, enabling arbitrage.

2. **Validator weights are soft constraints** -- `_selectValidators()` tries to honor target shares but falls back to even distribution. Exact allocations are not guaranteed.

3. **PolBridger same-address requirement** -- Plasma bridge design requires identical contract address on both chains. Operational constraint at deployment time.

4. **Messenger is a normal user** -- sPOLMessenger has no special immutable reference in the controller. It interacts via `buySPOL`/`sellSPOL` like any other caller. Access is gated through AccessManager roles.
