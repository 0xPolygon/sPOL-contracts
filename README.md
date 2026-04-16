# sPOL

Liquid staking protocol for POL on Ethereum. Users deposit POL and receive sPOL, a transferable ERC-20 that represents a share of the staked pool. The protocol delegates across a managed set of validators, compounds rewards, and exposes the token on both Ethereum (L1) and Polygon (L2) via Polygon's state-sync bridge.

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


Install dependencies
```sh
forge soldeer install
```
Build
```sh
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

Unit and integration tests
```sh
forge test
```
Coverage (excludes scripts, mocks, messaging libs, and integration tests)
```sh
forge coverage --no-match-coverage "(script|mocks|msg|integration)"
```

Integration tests fork mainnet and require `L1_RPC_URL` / `L2_RPC_URL` to be set.

## Audits

Reports are in `audits/` sorted by tag:

- ChainSecurity -- Polygon sPOL audit
- Certora -- Polygon sPOL staking audit

## Deployments

### Mainnet

**Ethereum**

| Contract | Address |
|---|---|
| sPOL | [`0x3B790d651e950497c7723D47B24E6f61534f7969`](https://etherscan.io/address/0x3B790d651e950497c7723D47B24E6f61534f7969) |
| sPOLController | [`0xEaadA411F2600570796c341552b9869DA708a28B`](https://etherscan.io/address/0xEaadA411F2600570796c341552b9869DA708a28B) |
| sPOLMessenger | [`0x0356e303B375D5a11D9Eb7d57DBF544FeE6972C9`](https://etherscan.io/address/0x0356e303B375D5a11D9Eb7d57DBF544FeE6972C9) |
| AccessManager | [`0x2c91c02793a50f6D55168a88183da687F572d350`](https://etherscan.io/address/0x2c91c02793a50f6D55168a88183da687F572d350) |
| PolBridger | [`0x71663898Df7470e3b64d52663Ff975895E9b06E8`](https://etherscan.io/address/0x71663898Df7470e3b64d52663Ff975895E9b06E8) |

**Polygon PoS**

| Contract | Address |
|---|---|
| sPOLChild | [`0xd1CD49A08AeF3Af93457aEc17C786C2b7F48eCd7`](https://polygonscan.com/address/0xd1CD49A08AeF3Af93457aEc17C786C2b7F48eCd7) |
| AccessManager | [`0x2c91c02793a50f6D55168a88183da687F572d350`](https://polygonscan.com/address/0x2c91c02793a50f6D55168a88183da687F572d350) |
| PolBridger | [`0x71663898Df7470e3b64d52663Ff975895E9b06E8`](https://polygonscan.com/address/0x71663898Df7470e3b64d52663Ff975895E9b06E8) |

### Testnet

**Sepolia**

| Contract | Address |
|---|---|
| sPOL | [`0x98Cf9fD00217420e64a47F3682E5dE06D8Ef635a`](https://sepolia.etherscan.io/address/0x98Cf9fD00217420e64a47F3682E5dE06D8Ef635a) |
| sPOLController | [`0xA637f4BA0E8831Fa2cb7f9939D17BdAF2c48D998`](https://sepolia.etherscan.io/address/0xA637f4BA0E8831Fa2cb7f9939D17BdAF2c48D998) |
| sPOLMessenger | [`0xe5De910D9D943E2a5773a9e6b5488d6b3b72AB03`](https://sepolia.etherscan.io/address/0xe5De910D9D943E2a5773a9e6b5488d6b3b72AB03) |
| AccessManager | [`0xf89F0D616f777fA55c4Afdb4E1D485c81403B585`](https://sepolia.etherscan.io/address/0xf89F0D616f777fA55c4Afdb4E1D485c81403B585) |
| PolBridger | [`0x2B98234D09ed762a047992eD6e163F806CE477Db`](https://sepolia.etherscan.io/address/0x2B98234D09ed762a047992eD6e163F806CE477Db) |

**Amoy**

| Contract | Address |
|---|---|
| sPOLChild | [`0x3c7A9412B9AB03AaD2129A2C2159372516011E45`](https://amoy.polygonscan.com/address/0x3c7A9412B9AB03AaD2129A2C2159372516011E45) |
| AccessManager | [`0xf89F0D616f777fA55c4Afdb4E1D485c81403B585`](https://amoy.polygonscan.com/address/0xf89F0D616f777fA55c4Afdb4E1D485c81403B585) |
| PolBridger | [`0x2B98234D09ed762a047992eD6e163F806CE477Db`](https://amoy.polygonscan.com/address/0x2B98234D09ed762a047992eD6e163F806CE477Db) |

## License

Copyright © 2026 PT Services DMCC  
Licensed under either of  
- Apache License, Version 2.0, (LICENSE-APACHE or http://www.apache.org/licenses/LICENSE-2.0)  
- MIT license (LICENSE-MIT or http://opensource.org/licenses/MIT)  

at your option.  
The SPDX license identifier for this project is MIT OR Apache-2.0.