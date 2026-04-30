---
name: spol-upgrade
description: Use this skill when planning, writing tests for, or executing an sPOL contract upgrade — and for steady-state operational checks like L2-buy staleness, migration health, or Plasma registry posture (via script/operations/MigrationHealth.s.sol). Covers cross-chain fork-test patterns (recordLogs, prank discipline, mock messenger) and the PLAN / SAFETY-SUMMARY / INTEGRATOR-NOTES / PROTOCOL runbook structure.
---

# sPOL upgrade onboarding

Patterns for running cross-chain sPOL upgrades end-to-end — fork tests,
runbooks, sanity scripts. The PolBridger-to-proxy upgrade (Apr 2026) was
the first run that produced these notes; the patterns here are intentionally
upgrade-shape-agnostic.

This is the home for patterns that vary per upgrade. Steady-state protocol
documentation lives in `CLAUDE.md`.

## When to use

Trigger this skill when the user is doing any of:

- Writing or revising fork tests that drive an upgrade end-to-end across one
  or both chains.
- Drafting / executing an upgrade runbook (deploy script, multisig calldata,
  sanity scripts, integrator notes).
- Onboarding a new contributor onto the upgrade workflow.

The upgrade may or may not involve a stuck-migration recovery, donations,
or treasury action — those are special cases of the general workflow.

## What's in this skill

Two reference files. Read whichever applies — they're mostly independent.

| File | When to read |
|---|---|
| [fork-tests.md](fork-tests.md) | Writing or reviewing a fork-based integration test for an upgrade. Cross-chain harness (`recordLogs` + `vm.selectFork`), prank rules, mock-messenger pattern, EIP-7702 footgun. |
| [runbooks.md](runbooks.md) | Drafting `MAINNET-UPGRADE-PLAN.md`, `*-PROTOCOL.md`, `*-SAFETY-SUMMARY.md`, `*-INTEGRATOR-NOTES.md`, `TESTNET-DRY-RUN-PROTOCOL.md`. Section template, dos/don'ts, what to commit and when. |

## Quick recipe — next upgrade

The upgrade script is the centre of gravity. Plan, fork tests, runbooks
all reference it. Write it second, after the plan, before anything else.

1. **Plan first.** Draft `script/upgrades/<UPGRADE-NAME>-PLAN.md` using the
   template in `runbooks.md`. Get sign-off before writing code.
2. **Write the upgrade script** (`script/upgrades/<UpgradeX>.s.sol`). This is
   what the operator will broadcast and what the fork test will rehearse.
   - Outer `runBoth(string)` / `runL1` / `runL2` wrappers handle
     `vm.startBroadcast` and read `DEPLOYER_PRIVATE_KEY` from env.
   - Inner `_deployL1(cfg, deployer)` / `_deployL2(cfg, deployer)` take the
     deployer as a param and **don't broadcast or read env** — that's the
     contract that makes them callable from tests.
   - Include `verifyL1(string, address)` / `verifyL2(string, address)`
     view functions that re-derive every CREATE2 address and assert proxy
     impl slots, immutables, ProxyAdmin ownership, and pointer values.
     Run them post-broadcast as the upgrade's first sanity gate.
   - **Assert `block.chainid` matches the expected chain** at the top of
     each `_deployL*` helper.
3. **Predict and check.** Use the script's `verify*` (or a sibling
   address-prediction view) to surface every CREATE2 address the upgrade
   will land on, then `cast code <addr>` on every chain it could broadcast
   to. Reject any non-zero codesize before broadcast.
4. **Run the migration health script.** `script/operations/MigrationHealth.s.sol`
   reports current+next migration sizing under three APY scenarios and five
   time offsets, the L2-buy staleness deadline, and the Plasma-registry
   posture (predicate authorised, contractMap entries, `HALF_EXIT_PERIOD`).
   Re-run close to broadcast — values drift hourly. Even upgrades that
   don't touch migration code should run it as a "current state is healthy"
   check.
5. **Write the upgrade fork test** — see `fork-tests.md`. The test inherits
   the upgrade script (`is Test, UpgradeX`), runs its deploy helpers under
   `vm.startPrank(deployer)`, then submits the printed multisig calldata
   under `vm.prank(adminSafe)`. The test is a literal rehearsal — if the
   script changes, the test breaks before mainnet does. **Goes under
   `test/upgrades/`** (CI-skipped; see fork-tests.md).
6. **Add / update unit and integration tests for any new or changed
   contract behaviour.** Separate from the upgrade fork test — these
   cover the *new code itself*, not the upgrade rehearsal. They live under
   `test/unit/` and `test/integration/`, run in CI on every PR, and **do
   not get deleted post-ship**. Rules:
   - Every new external/public function gets a unit test for the happy
     path plus each revert path.
   - Every changed function: update its existing test. If a test no longer
     makes sense (function removed), delete the test rather than letting
     it rot.
   - Cross-chain behaviour reachable only through the messaging layer
     (e.g. a new `_handle*` branch) gets an integration test against the
     greenfield `Deploy.s.sol` setup.
7. **Safety summary** — write `<UPGRADE>-SAFETY-SUMMARY.md` once the plan
   has stabilised and the contracts are written. One page, plain language,
   for Safe signers and non-engineering reviewers. Each value
   movement / state transition gets its own section: what's moving, the
   call chain, sizing or value-at-risk, the *one* safety assumption,
   loss acknowledgement if any. Template in `runbooks.md`.
8. **Testnet dry run** end-to-end on the matching testnet pair (e.g.
   Sepolia↔Amoy for L1+L2 upgrades; one chain only for single-chain ones).
   Capture the run live in `<UPGRADE>-TESTNET-DRY-RUN-PROTOCOL.md`. See
   `runbooks.md` for what to log.
9. **Integrator notes** once contracts are frozen — diff of addresses,
   ABIs, events for UI/app/indexer teams. Template in `runbooks.md`.
10. **Mainnet protocol.** Mirror the testnet protocol live as
    `<UPGRADE>-PROTOCOL.md`. One section per stage, tx hashes inline,
    timestamps at every read. Sign-off note + post-mortem at the end.

### The Deploy.s.sol boundary

`script/Deploy.s.sol` is the **greenfield** deploy. It is for unit tests,
fresh-state integration tests, and fuzz tests that need a clean sPOL
universe (`sPOLControllerFullL1.t.sol`, `sPOLControllerOther.t.sol`).

Do **not** inherit it in fork tests of mainnet/testnet upgrades. Doing so
gives you a parallel protocol on top of forked state, which doesn't model
what an in-flight upgrade does on chain. Use the upgrade script instead
(see step 2). If the upgrade script doesn't exist yet, write it first —
that's the standard flow.

## What gets deleted after an upgrade ships

These files are one-shot artifacts — delete them post-upgrade and rely on this
skill for the next round:

- `test/upgrades/<upgrade-name>*.t.sol` — fork tests pinned to the upgrade's
  pre-state. **All upgrade fork tests must live under `test/upgrades/`** —
  CI skips that path via `forge test --no-match-path "test/upgrades/*"`
  (see `.github/workflows/test.yml`), so the inevitable post-ship failures
  don't block PRs. Don't put upgrade fork tests in `test/integration/`.
- `script/upgrades/<UpgradeX>.s.sol` — the upgrade script itself.
- `script/upgrades/*Proof.json` — only if applicable. The PolBridger upgrade
  shipped recovery proofs for a stuck migration; routine upgrades don't.
- The upgrade-specific runbooks: `*-PLAN.md`, `*-PROTOCOL.md`,
  `*-SAFETY-SUMMARY.md`, `TESTNET-DRY-RUN*.md`. The `*-INTEGRATOR-NOTES.md`
  is **kept** as the public changelog entry — see `runbooks.md`.

What stays:

- `test/integration/sPOLControllerFullL1.t.sol`, `sPOLControllerOther.t.sol` —
  not upgrade-specific.
- `test/integration/CheckpointData.sol` — needs **periodic refresh** when L1
  RPC prunes. See `fork-tests.md` § "CheckpointData".
- `test/mocks/MocksPOLMessenger.sol` — generic helper, reusable across upgrades.
- `script/operations/MigrationHealth.s.sol` — generic migration-health
  calculator. Read-only; reports current+next migration safety under APY
  scenarios and the L2-buy staleness deadline. Use pre-broadcast and any
  time the operator wants to size donations or check L2 health.
- `script/Deploy.s.sol` — greenfield deploy harness. Used by unit /
  fresh-state integration / fuzz tests only. **Not** used by upgrade fork
  tests (see "Deploy.s.sol boundary" above).
- `calculator/index.html` — unrelated user-facing APY calculator. Leave alone.

## Conventions

- **Foundry auto-loads `.env`.** `forge script` / `forge test` read `.env` at
  the repo root automatically — do **not** `source .env` or prefix a forge
  command with `L1_RPC_URL=... L2_RPC_URL=...`. Just run `forge script ...`.
  The same applies in tests using `vm.envString("L1_RPC_URL")`. If a value
  is missing, edit `.env`, don't pipe it via the shell.

- **RPC and salt safety.** Three rules to avoid broadcasting to the wrong
  chain or colliding with prior deploys:
  1. The upgrade script's `_deployL1` / `_deployL2` must assert
     `block.chainid == cfg.chainIdL1` / `chainIdL2` before any deploy.
     This is the only check that catches a wrong-RPC env var.
  2. Salt prefixes must differ across environments (`testnet-`, `mainnet-`)
     so a wrong-chain broadcast can't silently collide with the real
     deploy. Verify in `script/input.json` before each upgrade.
  3. **Predict every CREATE2 address and `cast code` it on each candidate
     chain before broadcast.** Non-zero codesize means abort.
