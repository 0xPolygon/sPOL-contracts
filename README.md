# sPOL

Liquid staking protocol for POL on Polygon PoS. Users deposit POL and receive sPOL, a transferable ERC-20 that represents a share of the staked pool. The protocol delegates across a managed set of validators, compounds rewards, and exposes the token on both Ethereum (L1) and Polygon (L2) via Polygon's state-sync bridge.

## Architecture

| Contract | Chain | Role |
|---|---|---|
| `sPOLController` | L1 | Core staking logic -- validator management, POL/sPOL conversions, reward compounding, unbonding queue |
| `sPOL` | L1 | ERC-20 token (mint/burn gated to the controller) with EIP-2612 permit support |
| `sPOLMessenger` | L1 | Bridge coordinator -- relays exchange-rate updates, processes migration and backfill proofs from L2 |
| `sPOLChild` | L2 | L2 sPOL ERC-20 + buy operations using a cached exchange rate, initiates surplus-POL migrations to L1 |
| `PolBridger` | L1 + L2 | Handles POL bridging between chains via the Polygon PoS bridge |
| `MsgCoder` | -- | Shared logic for cross-chain message encoding/decoding |

## Setup

Requires [Foundry](https://book.getfoundry.sh/getting-started/installation).

```sh
# Install dependencies
forge soldeer install

# Build
forge build
```

Copy `.env.example` to `.env` and fill in the values:

```sh
cp .env.example .env
```

You will need:
- `DEPLOYER_PRIVATE_KEY` -- deployer account private key
- `L1_RPC_URL` -- Ethereum RPC endpoint
- `L2_RPC_URL` -- Polygon PoS RPC endpoint

## Testing

```sh
# Unit and integration tests
forge test

# Coverage (excludes scripts, mocks, messaging libs, and integration tests)
forge coverage --no-match-coverage "(script|mocks|msg|integration)"
```

Integration tests fork mainnet and require `L1_RPC_URL` / `L2_RPC_URL` to be set.

## Audits

Reports are in `audits/` sorted by tag:

- ChainSecurity -- Polygon sPOL audit
- Certora -- Polygon sPOL staking audit

## License

Copyright © 2026 PT Services DMCC  
Licensed under either of  
- Apache License, Version 2.0, (LICENSE-APACHE or http://www.apache.org/licenses/LICENSE-2.0)  
- MIT license (LICENSE-MIT or http://opensource.org/licenses/MIT)  

at your option.  
The SPDX license identifier for this project is MIT OR Apache-2.0.