# Cross-chain fork tests for sPOL upgrades

How to write Foundry fork tests that exercise an upgrade end-to-end across
Ethereum (L1) and Polygon (L2).

## Where upgrade fork tests live

**Always under `test/upgrades/`.** Never under `test/integration/`.

Upgrade fork tests fork pre-upgrade mainnet state and rehearse the upgrade
on it. Once the upgrade lands on mainnet they will start failing — the
forked state has moved on, the addresses they call have new code, the
state-machine they assert against has progressed. That's expected and
fine, but their failures must not block PRs.

CI takes care of the skip:

```yaml
# .github/workflows/test.yml
forge test -vvv --no-match-path "test/upgrades/*"
```

The directory pattern is the contract — anything under `test/upgrades/`
is opt-out of CI, anything under `test/integration/` is in CI. Match the
location to the lifecycle:

| Path | Lifecycle | CI |
|---|---|---|
| `test/unit/`, `test/integration/`, `test/gas/` | Run on every PR forever | Run |
| `test/upgrades/` | Valid only until the upgrade ships, then deleted | Skipped |
| `test/mocks/` | Helpers, not tests | (no tests inside) |

When the upgrade ships, delete `test/upgrades/<upgrade-name>*.t.sol` along
with the rest of the upgrade-specific artifacts (see SKILL.md).

### Upgrade fork tests are not a substitute for unit + integration tests

The upgrade fork test rehearses the *upgrade procedure* — that's its
entire job, and it gets deleted post-ship. It does **not** cover the new
behaviour the upgrade introduces. Any contract code the upgrade adds or
changes also needs:

- **Unit tests** under `test/unit/` for every new external/public function
  (happy path + each revert), and updates to existing unit tests for any
  changed function. If a function is removed, delete its unit test rather
  than letting it rot.
- **Integration tests** under `test/integration/` for cross-chain behaviour
  only reachable through the messaging layer (a new `_handle*` branch, a
  changed migration flow, etc.). Use the greenfield `Deploy.s.sol` setup
  — these run in CI on every PR.

These tests **stay**. They aren't part of the upgrade artifact set; they
become part of the protocol's permanent test suite.

## Two flavors of upgrade fork test

Pick the right one for the upgrade shape — they have different setup costs and
different blast radii.

### Flavor A: Pre-upgrade dry-run (drive the upgrade script in-test)

**When:** the upgrade is new code that will be deployed via a one-shot
upgrade script (`script/upgrades/<UpgradeX>.s.sol`) and signed off via
multisig calldata. You want to fork mainnet, run the upgrade in-test exactly
as the operator will run it, then drive the post-upgrade flow.

**Critical convention — read this before writing the test.**

Do **not** inherit `script/Deploy.s.sol` in fork tests. `Deploy.s.sol` is the
greenfield deploy used by unit / fresh-state integration tests
(e.g. `sPOLControllerFullL1.t.sol`); it deploys the *whole* protocol from
scratch and bears no resemblance to what an in-flight upgrade does to
mainnet. Inheriting it in a fork test gives you a parallel sPOL universe on
top of forked mainnet state — which is what `sPOLMigrationBackfill.t.sol`
did, and is exactly the wrong shape going forward.

The standard flow for the next upgrade is:

1. **Write the upgrade script first** (`script/upgrades/<UpgradeX>.s.sol`).
   It deploys the new contracts, prints the multisig calldata, and writes
   addresses to `deployment-*.json`. This is what the operator will actually
   broadcast. Structure it as outer `runBoth(string)` / `runL1` / `runL2`
   wrappers that handle `vm.startBroadcast`, plus inner `_deployL1(cfg, deployer)`
   / `_deployL2(cfg, deployer)` that contain the actual deploy logic with
   no broadcast inside. The inner helpers are what tests will call. Drop
   the L2 leg if the upgrade only touches one chain.
2. **The fork test inherits the upgrade script** — `is Test, UpgradeX`
   (and only `CheckpointData` if you need to simulate validator rewards;
   see "CheckpointData" below — most upgrade fork tests don't need it). The
   test calls the script's `_deployL1` / `_deployL2` directly, no
   `new UpgradeX()`, no separate "for-test" wrappers, no broadcast. The
   script's structs (`Config`, `DeployedL1`, `DeployedL2`) are visible by
   inheritance.
3. **Drive the post-upgrade flow** with the prank rules in the next section.

This means the fork test *is* the upgrade script (by inheritance) — the
same code path the operator runs, just driven from a Foundry test instead
of `forge script --broadcast`. If the script changes, the test breaks before
mainnet does.

Reference layout (pseudo-code — `Config`, `DeployedL1`, `DeployedL2`,
`cfg.someProxy`, `d1.newImpl`, `initPayload` are placeholders for whatever
the upgrade script actually defines and exposes; substitute with real
struct fields and types before this compiles):

```solidity
import {UpgradeX} from "../../script/upgrades/UpgradeX.s.sol";

contract MyUpgradeForkTest is Test, UpgradeX {
    uint256 networkL1;
    uint256 networkL2;
    address adminSafe;

    // Use unique labels — avoids EOAs that have EIP-7702 delegation code on
    // forked mainnet and would break `prank → call` flows.
    address user1 = makeAddr("user1no7702delegation");

    function setUp() public {
        // Default: latest block on both chains. Pass a block number only if
        // (a) you want RPC-response caching for slow/repeated test runs, or
        // (b) you're using CheckpointData to simulate rewards (then pin L1
        // to FORK_BLOCK_L1 specifically).
        networkL1 = vm.createFork(vm.envString("L1_RPC_URL"));
        networkL2 = vm.createFork(vm.envString("L2_RPC_URL"));

        Config memory cfg = _loadConfig("mainnet");
        address deployer = makeAddr("upgradeDeployer");
        adminSafe = vm.parseJsonAddress(
            vm.readFile("script/deployment-mainnet.json"), ".sPOL_L1.admin"
        );

        // Test inherits UpgradeX. Call the script's internal deploy helpers
        // directly. No broadcast — broadcast only lives in runBoth/runL1/runL2.
        // Wrap in startPrank so msg.sender == deployer (the script's helpers
        // expect the deployer as msg.sender for proxy-admin transfer steps).
        vm.selectFork(networkL1);
        vm.startPrank(deployer);
        DeployedL1 memory d1 = _deployL1(cfg, deployer);
        vm.stopPrank();

        // If single-chain upgrade: drop the L2 fork + L2 deploy block here.
        vm.selectFork(networkL2);
        vm.startPrank(deployer);
        DeployedL2 memory d2 = _deployL2(cfg, deployer);
        vm.stopPrank();

        // Submit each multisig calldata the script printed, the same way the
        // operator will. AccessManager admin can call restricted functions
        // directly — only wrap in execute(...) when targeting ProxyAdmin.
        // Replace the inner reinitialize / payload with whatever the upgrade
        // actually does; "" for upgrades with no init payload.
        vm.selectFork(networkL1);
        vm.prank(adminSafe);
        AccessManager(cfg.accessManagerL1).execute(
            cfg.someProxyAdmin,
            abi.encodeCall(ProxyAdmin.upgradeAndCall,
                (ITransparentUpgradeableProxy(cfg.someProxy), d1.newImpl, initPayload))
        );
        // ...repeat for L2 if applicable
    }
}
```

If the upgrade only touches one chain (e.g. `sPOLController` on L1 only),
drop the L2 fork and the L2 deploy/multisig blocks — the same pattern
applies. If the upgrade adds a new contract without re-pointing existing
contracts, the multisig step may be a single AccessManager-restricted call
rather than `upgradeAndCall(reinitialize)`.

Key points:

- **The fork test inherits the upgrade script.** Not `Deploy.s.sol`. Not via
  `new UpgradeX()`. Inheritance — `is Test, UpgradeX`. This is the same shape
  `sPOLMigrationBackfill.t.sol` used for `Deploy` (the greenfield script);
  the upgrade equivalent is the upgrade script. Add `CheckpointData` to the
  inheritance list **only** if you need to simulate validator rewards (see
  the CheckpointData section below).
- **Call the script's existing internal helpers.** Inner functions like
  `_deployL1(cfg, deployer)` are the test-callable contract because they
  take the deployer as a param, don't read `DEPLOYER_PRIVATE_KEY` from env,
  and don't `vm.broadcast`. The outer `runBoth` / `runL1` / `runL2` wrappers
  hold all of that. **Don't add separate `*ForTest` wrappers** — structure
  the script so the inner helpers are already test-ready.
- **`vm.startPrank(deployer)` instead of broadcast.** The deploy helpers
  rely on `msg.sender == deployer` for the ProxyAdmin transfer step. Pranking
  achieves that without broadcasting.
- **Default to a latest-block fork on both chains.** Pin only when there's
  a concrete reason. Two valid reasons:
  - **Performance.** A pinned block lets Foundry cache RPC responses across
    runs. If the test is slow because of repeated RPC calls — long
    re-runs, large fuzz, integration suite in CI — pin to any recent block
    to enable caching. This is purely a runtime optimisation; pick whatever
    block is convenient.
  - **`CheckpointData`** for simulating validator rewards (next bullet).
    This requires `FORK_BLOCK_L1` specifically (one block before the first
    canned checkpoint), not an arbitrary block. See the CheckpointData
    section.
- **Salt prefix:** the script reads it from `input.json`. The test runs the
  script verbatim — same salt prefix as production. The deploys land at the
  same predicted address the operator will see, and the fork only persists
  for the test run (no real-chain collision risk).
- **Don't re-do production wiring in `setUp`.** Token mapping on
  `RootChainManager`, `StateSender.register` — these are part of the
  initial deploy on mainnet, already there on the fork. Greenfield deploy
  tests had to recreate them; upgrade fork tests do not.

### Flavor B: Post-upgrade snapshot (no redeploy)

**When:** the upgrade is already deployed and you want to verify the live state
is healthy and the next cycle works. No deploy in test — fork mainnet AS-IS
and drive the flow with pranks. Cheap to write, but **it is one-shot** — it
will fail as soon as on-chain state moves past the snapshot.

Reference layout:

```solidity
contract PostUpgradeSnapshotTest is Test {
    // Polygon system entry points — chain-level constants, fine to hardcode.
    address constant STATE_SYNCER_L2     = 0x0000000000000000000000000000000000001001;
    address constant CHILD_CHAIN_MANAGER = 0xA6FA4fB5f76172d178d61B04b0ecd319C5d1C0aa;

    // Protocol addresses — read from deployment JSON, never hardcode.
    address controller;
    address messenger;
    address child;
    address adminSafe;

    uint256 forkL1;
    uint256 forkL2;

    function setUp() public {
        forkL1 = vm.createFork(vm.envString("L1_RPC_URL")); // latest
        forkL2 = vm.createFork(vm.envString("L2_RPC_URL"));

        string memory dep = vm.readFile("script/deployment-mainnet.json");
        controller = vm.parseJsonAddress(dep, ".sPOL_L1.sPOLControllerProxy");
        messenger  = vm.parseJsonAddress(dep, ".sPOL_L1.sPOLMessengerProxy");
        child      = vm.parseJsonAddress(dep, ".sPOL_L2.sPOLChildProxy");
        adminSafe  = vm.parseJsonAddress(dep, ".sPOL_L1.admin");
    }

    function test_nextMigrationCycle() public {
        bytes memory stateSyncData = _phase1_triggerL1();
        _phase2_receiveL2(stateSyncData);
        _phase3_processL1();
        _phase4_closeL2();
    }
}
```

Always **partition the test into named phases** (`_phaseN_*`). Each phase ends
with a fork switch. Helps stack-too-stack and makes the call-chain auditable
in CI logs.

## Cross-chain harness: state-sync via `recordLogs`

The pattern that drives an L1→L2 message in tests is **always the same**:

```solidity
// L1: trigger something that emits StateSynced via the StateSender
vm.selectFork(forkL1);
vm.recordLogs();                                       // BEFORE the call
vm.prank(ADMIN_SAFE);                                  // initial caller only
sPOLMessenger(MESSENGER).updateL2ExchangeRate();       // or any state-syncing fn

Vm.Log[] memory l1Logs = vm.getRecordedLogs();         // AFTER the call
bytes memory stateSyncData;
for (uint256 i = 0; i < l1Logs.length; i++) {
    if (l1Logs[i].topics[0] == keccak256("StateSynced(uint256,address,bytes)")) {
        stateSyncData = abi.decode(l1Logs[i].data, (bytes));
        break;
    }
}
require(stateSyncData.length > 0, "StateSynced not emitted");

// L2: prank as the system state-syncer (0x...1001) to deliver
vm.selectFork(forkL2);
vm.recordLogs();
vm.prank(STATE_SYNCER_L2);
sPOLChild(payable(CHILD)).onStateReceive(0, stateSyncData);

Vm.Log[] memory l2Logs = vm.getRecordedLogs();
// ...assert downstream events here
```

**`recordLogs` rules:**

1. Call `vm.recordLogs()` immediately before the call you want to capture.
   The log buffer is per-fork — selecting a different fork resets nothing,
   but a new `vm.recordLogs()` call starts a fresh buffer.
2. `vm.getRecordedLogs()` **drains** the buffer. Call it once and store the
   result. Calling it twice gives you an empty array the second time.
3. Decode `data` with `abi.decode(...)` matching the Solidity event signature.
   For `StateSynced(uint256,address,bytes)` the bytes payload is itself an
   `abi.encode(bytes)` wrapper — single-decode to get to the inner state-sync
   data.
4. To pull an indexed parameter, read it from `topics[N]`. Example, the L2
   `Withdraw` event: `address fromAddr = address(uint160(uint256(topics[2])));`
5. **Identify logs by `(emitter, topics[0])`, never by absolute index.**
   Two coupled rules:
   - Always check `l2Logs[i].emitter` alongside `topics[0]` —
     `emitter == <expected contract> && <indexed field> == <expected address>`
     is the regression guard. In the PolBridger upgrade the L2-burn `from`
     topic had to match the *new* bridger address, not the old; that one
     assertion is what caught the regression that motivated the upgrade.
   - **Never** index by `logIndex` ("the Nth log"). A single tx can emit
     many events and Foundry's log buffer doesn't preserve the same
     ordering as on-chain receipts. Loop with the `(emitter, topics[0])`
     filter, plus any other indexed topic that disambiguates.

## Driving an L2 deposit via ChildChainManager

Only relevant if the upgrade's flow includes sPOL (or any mapped ERC-20)
arriving on L2 via the PoS bridge — for example, closing a migration cycle.
On L1 someone calls `RootChainManager.depositFor`; the PoS bridge delivers
that to L2 as `ChildChainManager.deposit(receiver, abi.encode(amount))`.
In tests, prank as `childChainManager` (system entry point on L2):

```solidity
vm.selectFork(forkL2);
vm.prank(CHILD_CHAIN_MANAGER);
sPOLChild(payable(child)).deposit(address(child), abi.encode(mintedSPOL));
// In a migration close, this triggers MigrationCompleted + clears
// onGoingMigration / backMigratingSPOL. Most upgrades won't reach here.
```

## Bypassing Plasma proof verification: MocksPOLMessenger

L1 message processing in production uses
`sPOLMessenger.receiveMessage(proof)`, which validates a Plasma checkpoint
inclusion proof. In tests we bypass that with the mock.

`test/mocks/MocksPOLMessenger.sol` is just `sPOLMessenger` with one extra
external function:

```solidity
function expose_processMessageFromChild(bytes memory _message) external {
    _processMessageFromChild(_message);
}
```

Two ways to use it:

### Option 1: deploy + upgrade (in Flavor A tests)

```solidity
function _deployMockMessenger() internal returns (MocksPOLMessenger) {
    vm.selectFork(networkL1);
    MocksPOLMessenger mockImpl = new MocksPOLMessenger(/* same ctor args */);
    bytes memory upgradeData = abi.encodeCall(
        ProxyAdmin.upgradeAndCall,
        (ITransparentUpgradeableProxy(address(sPOLMessengerProxy)), address(mockImpl), "")
    );
    vm.prank(admin);
    accessManagerL1.execute(address(sPOLMessengerproxyAdmin), upgradeData);
    return MocksPOLMessenger(address(sPOLMessengerProxy));
}
```

This is the "real" path — the AccessManager owns the ProxyAdmin in production,
so the test mirrors production access control.

### Option 2: `vm.etch` over the existing impl (in Flavor B tests)

```solidity
MocksPOLMessenger mockTemplate = new MocksPOLMessenger(/* same ctor args */);
vm.etch(MESSENGER_IMPL, address(mockTemplate).code);
// Now the live messenger proxy delegates into mock code.
```

Faster, no AccessManager dance. But you must construct the template with
**exactly the same constructor args** (immutables become baked-in bytecode), or
the etched code's reads will return the test template's values instead of the
production ones.

## Prank rules — the load-bearing one

There is a global rule in `~/.claude/CLAUDE.md`. The short form for this repo:

**Integration tests:** only prank the *initial* caller. That means:

- A real EOA / multisig, e.g. `ADMIN_SAFE`, a user wallet via `makeAddr`.
- A legitimate **system entry point** on the chain in question, e.g.
  `STATE_SYNCER_L2 = 0x...1001` for `child.onStateReceive`,
  `CHILD_CHAIN_MANAGER` for `child.deposit`.

**Do NOT prank:**

- An address that sits in the middle of a real call chain. Example: don't
  prank the messenger to call the bridger. Drive it from
  `admin.updateL2ExchangeRate()` and let the call chain unfold.
- An address that **cannot take the action in reality** — typically a broken
  or deprecated contract whose real bytecode wouldn't reach that endpoint.
- The AccessManager / authority contract. **Never.**

**Unit tests:** prank is fair game — impersonating any address to test a single
function in isolation is fine, including mid-chain addresses.

**AccessManager wrap rule:** an admin with `ADMIN_ROLE` can call `restricted`
functions on AccessManaged contracts directly — `AccessManager.canCall`
returns true. **Only** wrap in `accessManager.execute(target, data)` when the
target is actually owned by the AccessManager (e.g. `ProxyAdmin.upgradeAndCall`).
Wrapping unnecessarily inflates Safe calldata and makes tests harder to read.

## EIP-7702 footgun

EIP-7702 is live on Ethereum mainnet, so some EOAs returned by
`makeAddr("user1")`-style labels collide with addresses that already have
delegation code installed on the forked chain. That breaks tests that assume
the address is a pure EOA (e.g. `vm.prank(user); token.transfer(...)` may run
through delegation-installed code).

**Mitigation:** use unique, unusual labels:

```solidity
address user1 = makeAddr("user1no7702delegation");
```

Apply this on every account that will originate a transaction on a forked L1.
For pure L2 forks the risk is lower today but the convention is the same —
keep it consistent.

## CheckpointData

**Don't inherit this by default.** `test/integration/CheckpointData.sol`
carries hard-coded `RootChain.submitCheckpoint()` calldata for two real
checkpoints plus `FORK_BLOCK_L1` — its sole purpose is to **simulate
validator-reward accrual** in tests by replaying real checkpoint
submissions on top of a pinned L1 fork. Each checkpoint submission triggers
the on-chain reward distribution path, so test code that needs to verify
reward / restake / fee-accrual behaviour can call `_submitCheckpoint1()` /
`_submitCheckpoint2()` to advance the staking state.

If your test isn't checking reward accrual, don't inherit `CheckpointData`
— fork at latest, run the upgrade flow, done. (You may still pin to an
arbitrary recent block for RPC-cache speedup; that's a separate concern
from `CheckpointData` and doesn't require it.)

**When you do need it:** inherit `CheckpointData`, pass `FORK_BLOCK_L1`
into `vm.createFork(L1_RPC_URL, FORK_BLOCK_L1)` so the fork is positioned
exactly one block before checkpoint 1, then call `_submitCheckpoint1()` /
`_submitCheckpoint2()` between staking actions to advance reward state.

**The data goes stale** when the L1 RPC prunes. The current values are
pinned to 2026-03-19. When the test fails with "Checkpoint submission
failed":

1. Pick two consecutive checkpoint txs on Ethereum mainnet
   (RootChain `0x86E4...C287`, function `0x4e43e495`).
2. Pull each tx's calldata via `cast tx <hash> --json | jq .input`.
3. Update `rewardIncreaseCall1`, `rewardIncreaseCall2`, `FORK_BLOCK_L1`
   (block before the first checkpoint) and the docblock dates.

## Phase pattern for stack-too-deep

Solidity's stack limit bites hard in long fork tests. Two techniques:

1. **One internal function per phase**, each returning the small slice of
   state the next phase needs.
2. **Capture across phases via contract state**, not stack:
   ```solidity
   uint256 captPolAmount;
   uint256 captMintedSPOL;
   ```
   Set these in phase 2, read in phase 3+. Do not use a single big function
   with all locals.

## What to assert

A good cross-chain test asserts at **every fork switch**:

- The expected event was emitted (signature + emitter + decoded data).
- The relevant state mutated as expected (`onGoingMigration`, balances,
  `totalSupply`).
- A regression invariant: e.g. "the L2 burn `from` topic is the NEW bridger,
  not the OLD one" — this is the assertion that catches a wiring regression.

Don't only assert on final state — by the time you check it, you've lost the
event chain.
