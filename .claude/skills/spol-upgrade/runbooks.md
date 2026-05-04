# Upgrade runbooks: PLAN / PROTOCOL / SAFETY-SUMMARY / INTEGRATOR-NOTES

Each upgrade keeps five runbook documents under `script/upgrades/`.

| File | Audience | When written | What it answers |
|---|---|---|---|
| `<UPGRADE>-PLAN.md` | Engineers + reviewers + Safe signers | Before any code | "What are we doing, why, in what order, with what rollback?" |
| `<UPGRADE>-SAFETY-SUMMARY.md` | Safe signers + non-engineering reviewers | After the plan stabilises, before testnet | "What's at risk and why is each step safe?" One page, no jargon. |
| `<UPGRADE>-INTEGRATOR-NOTES.md` | UI / app / indexer teams | Once contracts are frozen, before mainnet | "What's the diff in addresses / ABIs / events I need to handle?" Short, technical, machine-friendly. |
| `<UPGRADE>-TESTNET-DRY-RUN-PROTOCOL.md` | Operator running testnet | Live, during testnet run | "What did we actually do, when, with what tx hash, what did we read." |
| `<UPGRADE>-PROTOCOL.md` | Operator + post-mortem | Live, during mainnet run | Same as testnet protocol, on mainnet. Becomes the historical record. |

The templates below capture the shape so the next upgrade starts from a known good skeleton.

---

## `<UPGRADE>-PLAN.md` template

The plan is the contract between the engineer driving the upgrade and
everyone reviewing it. Write it first. If you can't write the plan, you can't
ship the upgrade.

Required sections, in order:

### 1. Header

- One-paragraph summary: what this upgrade changes, who initiated it, what
  the failure mode looks like if we ship a buggy version.
- Pre-state description **only if** the upgrade is reacting to something
  unusual — a stuck migration, a deprecated dependency, a broken
  invariant. Most routine upgrades have nothing to put here; skip the
  section. (The PolBridger upgrade had a long pre-state block because the
  old bridger had burned POL into a dead Plasma predicate.)

### 2. Stage 0 — Pre-flight

Required for every upgrade. At minimum:

- **Snapshot on-chain state.** Block numbers, every getter the success
  criteria will compare against, balances on every contract that the
  upgrade touches.
- **Pause automated services with chain-mutating side effects** during the
  upgrade window. State-sync rate-update jobs, scheduled cron deposits,
  anything that calls a contract you're about to swap. Verify in the
  operator console *and* that no scheduled job will fire during the window.
  Reason: a state-sync arriving mid-deliberation can hit the OLD impl with
  fresh data. Even with a single-tx upgrade where the impl swap is atomic,
  signing latency creates a window where the multisig is reasoning about
  the old code while the chain still runs it.
- **Run the migration health script** (see SKILL.md). Even if the upgrade
  doesn't touch migration code, this verifies L2-buy staleness and Plasma
  registry posture — both can break orthogonal to your changes.
- **Predict and check CREATE2 addresses** on every chain the script could
  broadcast to.

### 3. Stages, numbered Stage 1 → Stage N

Granularity: **one stage per "thing that has to be true before the next thing
can start."** Don't merge a deploy with its post-deploy sanity check.

Each stage block contains:

- **Goal** — one sentence.
- **Actor** — deployer EOA / admin Safe / permissionless / automatic
  (e.g. PoS bridge state-sync). Naming the actor makes the runbook
  executable by someone other than the author.
- **Steps** — exact commands. Use code blocks. Include flags. If a step
  reads a file (e.g. proof JSON), name it.
- **Verification** — what to check after the step. Tx hash format, expected
  events, expected state reads (`cast call`).
- **Rollback / next-step coupling** — "if this fails, you can / cannot stop
  here." Mark explicitly which stage is the **point of no return** (in the
  PolBridger upgrade that was Stage 2 — the impl swap; nothing on-chain can
  reverse a proxy-impl swap once committed).

#### Single-tx vs two-tx upgrade flows

If the upgrade swaps an impl AND sets a new state pointer (a new dependency
address, a new role, etc.), prefer a **single-tx** flow:

```
ProxyAdmin.upgradeAndCall(proxy, newImpl, abi.encodeCall(NewImpl.reinitialize, (...)))
```

with `reinitialize` gated by:
- `reinitializer(N)` (one-shot) — second call reverts.
- `msg.sender == ERC1967Utils.getAdmin()` (only the ProxyAdmin can call).

This closes the frontrunning window where someone could call
`reinitialize(maliciousArg)` between the impl-swap tx and a separate
pointer-set tx. A two-tx flow is acceptable only if the new impl reverts on
any state-mutating call until initialised; if it doesn't, the window is
exploitable.

### 4. Success criteria

Bullet list of post-condition reads. Used by the operator to declare done.

### 5. Rollback

What you can and cannot reverse. Be explicit about the no-rollback boundary.

### 6. Artifacts to preserve

What gets committed back to the repo after the run: tx hashes, snapshot
diffs, sanity-script output. This is what makes the post-mortem possible.

### 7. Open items to confirm before go

Checkbox list. Operator ticks them off live. The ticking is logged in the
PROTOCOL document.

### 8. Lessons / appendix

If the plan went through revisions, document them. Things to consider
recording here:
- Proof-validation gotchas.
- Wrong-RPC broadcasts caught by salt-prefix differences.
- L2-buy staleness deadlines that became hard mid-upgrade clocks.
- Anything operator-discovered that the plan missed in v1.

---

## `<UPGRADE>-SAFETY-SUMMARY.md` template

One page. Audience: someone reviewing the upgrade who has 15 minutes.

Each migration / state transition / value movement gets its own section:

```markdown
## Migration A — <one-line label>

**What:** the thing that's moving and how big it is, in the unit that
matters (POL, sPOL, ETH).

**Path:** the call chain from initial actor to final state, named contracts.

**Donation sizing / value at risk:**

| Recipient | Amount | Why |
|---|---|---|
| ... | ... | ... |

**Safety assumption:** the *one* thing that has to be true for this to be
safe. If it isn't, what breaks.

**Loss acknowledgement:** if value is lost (e.g. stuck in a deprecated
contract), name it. Owners of the protocol need to consciously sign this.
```

End with a "things that would force us to abort" list. Three to five items,
each one observable on chain.

---

## `<UPGRADE>-INTEGRATOR-NOTES.md` template

Audience: UI / app / indexer / monitoring teams. They don't care about the
multisig flow — they care about what their code needs to change. Keep this
short, technical, and **machine-readable wherever possible** (tables, exact
function signatures, exact event topics).

Write it once contracts are frozen for testnet. Update it once if anything
moves before mainnet broadcast. Publish it the day mainnet ships.

**Examples below are illustrative — substitute the actual diff from the
upgrade you're shipping.** Empty tables are valid (and informative — they
confirm you considered the section).

Required sections:

### 1. Header

- Upgrade name + mainnet ship date.
- One sentence on what the upgrade does, end-user-visible.
- Link to the (frozen) PLAN commit hash for context, no narrative.

### 2. Address changes

```markdown
| Contract | Old address | New address | Notes |
|---|---|---|---|
| `<contract>` proxy | `0x...AAAA` | `0x...AAAA` (unchanged) | Proxy unchanged; impl swapped |
| `<contract>` impl  | `0x...BBBB` | `0x...CCCC` | New impl |
| `<helper>`         | `0x...DDDD` | `0x...EEEE` | **Address change.** UIs tracking this contract must update. |
```

Always state explicitly: did the **proxy address** change? In most upgrades
the proxy is stable and only the impl swaps; helper / non-proxy addresses
can change. UIs care about the distinction.

### 3. ABI changes

Three subsections, each a table. Empty tables are fine — leave the heading
in so the reader knows you considered it.

#### 3a. New functions

```markdown
| Contract | Signature | Access | Notes |
|---|---|---|---|
| `<contract>` | `reinitialize(<args>)` | `restricted` (ProxyAdmin only) | One-shot, gated by `reinitializer(N)`. Not callable post-upgrade. |
| `<contract>` | `<newFn>(...)` | `<modifier>` | What it does. |
```

#### 3b. Changed functions

Includes renamed getters, signature changes, behavior changes that don't
change the signature.

```markdown
| Contract | Old | New | Migration |
|---|---|---|---|
| `<contract>` | `<oldFn>() returns (address)` | `<newFn>() returns (address)` | Rename. Old getter removed; UIs must switch. |
| `<contract>` | `<unchangedFn>` | (unchanged) | Behavior identical. |
```

#### 3c. Removed functions

```markdown
| Contract | Signature | Replacement |
|---|---|---|
| `<contract>` | `<removedFn>(...)` | <what to use instead, or "None — pattern X removed"> |
```

### 4. Event changes

Events get their own top-level section because indexers break loudly when
events change. **Always include the topic-0 hash**, signed integers and
indexed flags, and a one-line semantic note.

```markdown
| Contract | Event | Topic 0 | Status | Notes |
|---|---|---|---|---|
| `<contract>` | `<EventName>(<args>)` | `0x...` | Unchanged | — |
| `<contract>` | `<NewEvent>(<args>)` | `0x...` | **NEW** | <reason> |
| `<contract>` | `<RenamedOrChangedEvent>(<args>)` | `0x...` | **CHANGED** | E.g. an arg now indexed (was non-indexed). Old topic-0 retired; new topic-0 differs because indexed-ness affects the signature. |
```

Specifically call out:
- **New events** (indexers must add handlers).
- **Removed events** (indexers can drop handlers, but only after the upgrade
  block — log them as deprecated, not deleted).
- **Indexed-flag changes** — these change topic-0, so they're effectively
  a new event from an indexer's POV. UI search-by-address breaks silently
  if the indexed flag flips.
- **Field-order or type changes** — same risk class as indexed-flag changes.

### 5. State / storage changes

Anything that changed the meaning or value of a publicly readable storage
slot. UIs reading via `cast call` need to know.

```markdown
| Contract | Field | Before | After |
|---|---|---|---|
| `<contract>` | `<getter>()` | <prev behaviour> | <new behaviour> |
```

### 6. Block boundary

```markdown
| Chain | Upgrade tx | Block | Timestamp |
|---|---|---|---|
| Ethereum mainnet | `0x...` | `12345678` | `2026-04-28 13:14 UTC` |
| Polygon mainnet | `0x...` | `87654321` | `2026-04-28 13:18 UTC` |
```

Indexers use this to decide where to switch ABIs. Without it they have to
guess.

---

## `<UPGRADE>-TESTNET-DRY-RUN-PROTOCOL.md` template

Live log of the testnet run. Pattern: mirror the plan stage-for-stage, fill
in the **actual** numbers and tx hashes as you go.

Per stage:

```markdown
## Stage X — <name>

**Started:** YYYY-MM-DD HH:MM UTC
**Operator:** <handle>
**Network:** <testnet L1> (chainId X) / <testnet L2> (chainId Y)

### X.1 <step name>

| | |
|---|---|
| Command | `forge script ... --sig "..." --broadcast` |
| Tx hash | `0x...` |
| Block | `1234567` |
| Gas used | `123,456` |

Pre-read: <table of relevant getter values>
Post-read: <same getters, after>

**Notes:** what surprised us, what was different from the plan. If the plan
is wrong, edit the plan and reference the commit.
```

Capture **every read** with timestamp + block. The testnet protocol is the
authoritative source for the mainnet protocol's "what to expect" sections.

End the file with:

- Total deltas (gas, time-on-the-clock, multisig signing latency).
- Plan corrections that need to flow back into `<UPGRADE>-PLAN.md` before
  mainnet.

### Proof handling

If the upgrade involves submitting a Plasma state-sync or burn proof on L1,
the testnet run is where you find out the proof is wrong — *before*
mainnet.

- **Range check before submitting any proof:**
  `headerBlocks(headerId).start <= burnBlock <= end`. A proof for a
  not-yet-checkpointed block reverts at submission, not at validation, so
  this check saves a wasted gas tx.
- **If you hit a Merkle / leaf-hash error on chain, validate offline first
  before retrying.** The proof-API bug history means it's still worth a
  10-minute local check rather than burning gas guessing.
  - **Single-leaf tries:** recompute the leaf hash from the proof's
    `receiptProof` field and `cast keccak` it; assert it matches the burn
    block's `receiptsRoot`
    (`cast block <num> --json | jq -r .receiptsRoot`).
  - **Multi-leaf tries:** dry-run the proof via `cast call` against the
    receiving contract, no broadcast. A successful call means the proof is
    accepted on-chain.

---

## `<UPGRADE>-PROTOCOL.md` template

Same shape as the testnet protocol. Two differences:

1. **Pre-broadcast snapshot section** at the top — itemise every value the
   operator wants frozen so post-mortem can compare. The PolBridger
   protocol pinned 30+ reads at a known block. Cover at minimum:
   - **Contract state** for every contract the upgrade touches: every
     getter the success criteria will reference, plus a few "should not
     change" sentinels (totalSupply, exchange-rate snapshot).
   - **Role / authority layout** — for AccessManaged contracts, list every
     `roleMembers` for roles touched by the upgrade.
   - **Balances** on every contract that holds tokens (POL, MATIC, sPOL).
   - **Migration health output** — paste the `MigrationHealth.s.sol` run
     verbatim.
   - **Proof validity** — if shipping a proof, paste the offline-validation
     output (see "Proof handling" above).
   - **Plasma registry posture** — predicate authorised, contractMap
     entries, `HALF_EXIT_PERIOD`. Already in `MigrationHealth.s.sol`'s
     output; just confirm.
2. **Sign-off + post-mortem** at the bottom. Did all success criteria hold?
   Anything to feed back into the next upgrade.

The mainnet protocol becomes a historical record. Don't overwrite — version
it if a re-attempt is needed (`<UPGRADE>-PROTOCOL-v2.md`).

---

## Conventions

- **Timestamps in UTC, absolute.** "Tomorrow morning" rots; `2026-04-28
  13:14 UTC` doesn't.
- **Always link to the commit hash** the plan was pinned at when execution
  started. Plans drift; the protocol references a frozen plan version.
- **`cast call` rather than block explorer.** Block explorers cache and
  re-render. `cast call` output goes in the protocol verbatim.
- **Tenderly simulations for every Safe tx.** Link the simulation URL in the
  plan and re-link in the protocol once it's been signed.
- **Calldata blocks, not screenshots.** Hex you can copy-paste survives.
  Screenshots don't.

---

## What lives where

Quick reference for the next upgrade — keep documents in `script/upgrades/`:

```
script/upgrades/
├── <UpgradeX>.s.sol                 # the upgrade script
├── <UPGRADE>-PLAN.md                # written first
├── <UPGRADE>-SAFETY-SUMMARY.md      # written second
├── <UPGRADE>-INTEGRATOR-NOTES.md    # written third (once contracts frozen)
├── <UPGRADE>-TESTNET-DRY-RUN-PROTOCOL.md  # written fourth, live
└── <UPGRADE>-PROTOCOL.md            # written fifth, live
```
