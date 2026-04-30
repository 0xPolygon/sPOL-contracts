// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.30;

import "forge-std/Script.sol";
import "forge-std/console.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {sPOLController} from "../../src/sPOLController.sol";
import {sPOLChild} from "../../src/sPOLChild.sol";

/// @notice Generic migration health check. Read-only — forks both chains, prints, no broadcast.
///
///         For the L2 child's current (if any) and next pending migration, reports whether the
///         migration's POL would cover `convertSPOLtoPOL(mintedSPOL) + 1` (= Preq, the POL the
///         messenger spends on `buySPOL`) under three APY scenarios and five time offsets,
///         tracking how the rate appreciation across a multisig deliberation window erodes the
///         safety-fee buffer.
///
///         Also reports the L2-buy staleness deadline:
///         `lastExchangeRateUpdate + maxExchangeRateUpdateDelay - block.timestamp`. Once that
///         hits zero, `sPOLChild.buySPOL` reverts with `ExchangeRateUpdateTooOld` until the
///         next cross-chain rate sync arrives.
///
/// @dev    Usage:
///         forge script script/operations/MigrationHealth.s.sol \
///             --sig "run(string)" "mainnet"
///         (no --broadcast). Set L1_RPC_URL and L2_RPC_URL.
contract MigrationHealth is Script {
    /// APY scenarios (basis points). Baseline tracks the historical net-of-fee L1 staking APY.
    /// Elevated and extreme are stress envelopes — if a migration is unsafe at 5%, it's unsafe.
    uint256[3] internal APY_BPS = [uint256(250), uint256(300), uint256(500)];
    string[3] internal APY_LABEL = ["2.5% baseline", "3.0% elevated", "5.0% extreme "];

    /// Time offsets (days from now). T0+30d is a long-tail upper bound; the further out the
    /// projection, the looser it gets — staking parameters / fee schedule / `feedPOLBalance`
    /// can all move and the linear projection misses any of them.
    uint256[5] internal OFFSETS_DAYS = [uint256(0), uint256(3), uint256(7), uint256(14), uint256(30)];

    uint256 internal constant BPS = 10_000;
    uint256 internal constant SECONDS_PER_YEAR = 365 days;

    struct State {
        // L1 controller
        uint256 totalsPOL;
        uint256 totaldPOL;
        uint256 feedPOL;
        uint256 messengerPOL;
        uint256 l1Now;
        // L2 child
        bool onGoingMigration;
        uint256 backMigratingSPOL;
        uint256 polBalance;
        uint256 locallyMintedSPOL;
        uint256 lastExchangeRateUpdate;
        uint256 maxExchangeRateUpdateDelay;
        uint256 l1SPOLBalance; // L2-cached snapshot of L1 totalsPOLBalance
        uint256 l1DPOLBalance; // L2-cached snapshot of L1 (totaldPOLBalance - feedPOLBalance)
        uint256 safetyFee; // bps, denom 10_000
        uint256 l2Now;
    }

    function run(string calldata _network) external {
        State memory s = _loadState(_network);
        _printHeader(_network, s);
        _printRateDivergence(s);
        _printL2BuyDeadline(s);
        if (s.onGoingMigration) {
            _printCurrentMigration(s);
        } else {
            console.log("");
            console.log("--- Current migration -------------------------------------------");
            console.log("No migration in flight (sPOLChild.onGoingMigration == false).");
        }
        _printNextMigration(s);
        _printPlasmaPreflight(_network);
    }

    // ----------------------------------------------------------------------- state

    function _loadState(string calldata _network) internal returns (State memory s) {
        string memory deployJson = vm.readFile(string.concat("script/deployment-", _network, ".json"));
        string memory inputJson = vm.readFile("script/input.json");
        string memory scenario = _isMainnet(_network) ? "ethereum-polygon" : "sepolia-amoy";

        address sPOLControllerProxy = vm.parseJsonAddress(deployJson, ".sPOL_L1.sPOLControllerProxy");
        address sPOLMessengerProxy = vm.parseJsonAddress(deployJson, ".sPOL_L1.sPOLMessengerProxy");
        address sPOLChildProxy = vm.parseJsonAddress(deployJson, ".sPOL_L2.sPOLChildProxy");
        address polTokenL1 = vm.parseJsonAddress(inputJson, string.concat(".", scenario, ".polTokenL1"));

        // L1
        vm.createSelectFork(vm.envString("L1_RPC_URL"));
        sPOLController controller = sPOLController(sPOLControllerProxy);
        s.totalsPOL = controller.totalsPOLBalance();
        s.totaldPOL = controller.totaldPOLBalance();
        s.feedPOL = controller.feedPOLBalance();
        s.messengerPOL = IERC20(polTokenL1).balanceOf(sPOLMessengerProxy);
        s.l1Now = block.timestamp;

        // L2
        vm.createSelectFork(vm.envString("L2_RPC_URL"));
        sPOLChild child = sPOLChild(payable(sPOLChildProxy));
        s.onGoingMigration = child.onGoingMigration();
        s.backMigratingSPOL = child.backMigratingSPOL();
        s.polBalance = child.polBalance();
        s.locallyMintedSPOL = child.locallyMintedSPOL();
        s.lastExchangeRateUpdate = child.lastExchangeRateUpdate();
        s.maxExchangeRateUpdateDelay = child.maxExchangeRateUpdateDelay();
        s.l1SPOLBalance = child.l1SPOLBalance();
        s.l1DPOLBalance = child.l1DPOLBalance();
        s.safetyFee = uint256(child.safetyFee());
        s.l2Now = block.timestamp;
    }

    // ----------------------------------------------------------------------- header

    function _printHeader(string calldata _network, State memory s) internal pure {
        console.log("=================================================================");
        console.log("Migration health (network: %s)", _network);
        console.log("=================================================================");
        console.log("L1 fork timestamp: %s", s.l1Now);
        console.log("L2 fork timestamp: %s", s.l2Now);
        console.log("");
        console.log("--- L1 controller state ---");
        _printAmount("  totalsPOLBalance ", s.totalsPOL);
        _printAmount("  totaldPOLBalance ", s.totaldPOL);
        _printAmount("  feedPOLBalance   ", s.feedPOL);
        _printAmount("  messenger POL bal", s.messengerPOL);
        console.log("");
        console.log("--- L2 child state ---");
        console.log("  onGoingMigration : %s", s.onGoingMigration ? "true" : "false");
        _printAmountSPOL("  backMigratingSPOL", s.backMigratingSPOL);
        _printAmount("  polBalance       ", s.polBalance);
        _printAmountSPOL("  locallyMintedSPOL", s.locallyMintedSPOL);
    }

    // ----------------------------------------------------------------------- L1 vs L2 rate

    function _printRateDivergence(State memory s) internal pure {
        console.log("");
        console.log("--- L1 vs L2 rate divergence ------------------------------------");
        // Both rates are POL-per-sPOL. The messenger pushes (totalsPOL, totaldPOL-feedPOL)
        // to L2 as (l1SPOLBalance, l1DPOLBalance), so they share a formula and compare
        // directly. The L2 cached rate is "frozen" until the next updateL2ExchangeRate.
        uint256 l1Num = s.totaldPOL - s.feedPOL;
        uint256 l1Den = s.totalsPOL;
        uint256 l2Num = s.l1DPOLBalance;
        uint256 l2Den = s.l1SPOLBalance;

        console.log(string.concat("  L1 live rate    : ", _rateFmt((l1Num * 1e18) / l1Den), " POL per sPOL"));
        console.log(string.concat("  L2 cached rate  : ", _rateFmt((l2Num * 1e18) / l2Den), " POL per sPOL"));

        uint256 ageSec = s.l2Now > s.lastExchangeRateUpdate ? s.l2Now - s.lastExchangeRateUpdate : 0;
        console.log("  Last L2 sync    : %s s ago  (%s h, %s d)", ageSec, ageSec / 1 hours, ageSec / 1 days);

        // Divergence in 0.01-bps precision: (l1Num*l2Den - l2Num*l1Den) * 1_000_000 / (l2Num*l1Den).
        // Normal direction is L1 > L2 (rate appreciates between syncs). Negative would be
        // surprising and is flagged.
        uint256 a = l1Num * l2Den;
        uint256 b = l2Num * l1Den;
        uint256 denom = l2Num * l1Den;
        int256 diffBpsX100;
        if (a >= b) {
            diffBpsX100 = int256((a - b) * 1_000_000 / denom);
        } else {
            diffBpsX100 = -int256((b - a) * 1_000_000 / denom);
        }

        if (diffBpsX100 >= 0) {
            console.log(string.concat("  Divergence      : +", _bpsFmtX100(uint256(diffBpsX100)), " bps  (L1 rate has appreciated)"));
        } else {
            console.log(string.concat("  Divergence      : -", _bpsFmtX100(uint256(-diffBpsX100)), " bps  (L2 cached > L1 live -- unexpected)"));
        }

        console.log(string.concat("  Stored safetyFee: ", _bpsFmtX100(s.safetyFee * 100), " bps"));

        // safetyFee is the discount applied to L2 buys. It is the protocol's headroom against
        // a stale L2 rate. If L1 has appreciated by more than safetyFee, an L2 buyer can
        // arbitrage immediately by buying on L2 and selling at the L1 rate.
        int256 safetyFeeX100 = int256(s.safetyFee * 100);
        int256 bufferX100 = safetyFeeX100 - diffBpsX100; // positive = safe
        if (bufferX100 >= 0) {
            console.log(
                string.concat(
                    "  Buffer (fee-div): +",
                    _bpsFmtX100(uint256(bufferX100)),
                    " bps  [SAFE -- L1 appreciation is within safetyFee headroom]"
                )
            );
        } else {
            console.log(
                string.concat(
                    "  Buffer (fee-div): -",
                    _bpsFmtX100(uint256(-bufferX100)),
                    " bps  [ARBITRAGEABLE -- L1 rate has run past safetyFee. Push updateL2ExchangeRate now.]"
                )
            );
        }
    }

    // ----------------------------------------------------------------------- L2 buy deadline

    function _printL2BuyDeadline(State memory s) internal pure {
        console.log("");
        console.log("--- L2 buy staleness deadline -----------------------------------");
        uint256 deadline = s.lastExchangeRateUpdate + s.maxExchangeRateUpdateDelay;
        if (deadline <= s.l2Now) {
            uint256 overdueSec = s.l2Now - deadline;
            console.log("L2 buys are ALREADY BLOCKED.");
            console.log("  ExchangeRateUpdateTooOld revert fires on every buySPOL call.");
            console.log(
                "  Overdue by: %s s  (%s h, %s d)", overdueSec, overdueSec / 1 hours, overdueSec / 1 days
            );
            console.log("  -> push a fresh exchange rate via sPOLMessenger.updateL2ExchangeRate()");
            console.log("     and wait for state-sync delivery (~20-30 min).");
            return;
        }
        uint256 remaining = deadline - s.l2Now;
        console.log("L2 buys block at L2 timestamp: %s", deadline);
        console.log(
            "  remaining: %s s  (%s h, %s d)", remaining, remaining / 1 hours, remaining / 1 days
        );
        if (remaining < 1 days) {
            console.log("  WARNING: < 24h. Push exchange rate now or buys will block.");
        } else if (remaining < 3 days) {
            console.log("  CAUTION: < 72h. Schedule the next exchange-rate push.");
        }
    }

    // ----------------------------------------------------------------------- migrations

    function _printCurrentMigration(State memory s) internal view {
        console.log("");
        console.log("--- Current migration (onGoingMigration = true) -----------------");
        console.log("Sized from L2 child state:");
        _printAmountSPOL("  backMigratingSPOL", s.backMigratingSPOL);
        console.log("");
        console.log("L1 effects on migration completion:");
        console.log("  - messenger pulls Pproof POL from bridger via takePOLL1");
        console.log("  - messenger spends Preq POL on controller.buySPOL");
        console.log("  - controller mints ~backMigratingSPOL sPOL to messenger");
        console.log("  - messenger bridges that sPOL back to L2 -> closes onGoingMigration");
        console.log("  - L1 sPOL totalSupply grows by ~backMigratingSPOL");
        console.log("  - surplus (Pproof - Preq) goes to controller as fee dust");
        console.log("");
        console.log("This script does NOT decode Pproof (it lives in the state-sync proof file).");
        console.log("Compare the Preq matrix below against your Pproof:");
        console.log("  - bridger can exit (live):  donation_needed = max(0, Preq - Pproof)");
        console.log("  - bridger is stuck:         donation_needed = Preq  (no Pproof revenue)");
        console.log("");
        // For current migration we show the Preq matrix only (no available comparison),
        // because available depends on whether the bridger can exit (operator-known).
        _printPreqMatrix(s.backMigratingSPOL, s);
    }

    function _printNextMigration(State memory s) internal view {
        console.log("");
        console.log("--- Next migration ----------------------------------------------");
        if (s.locallyMintedSPOL == 0 || s.polBalance == 0) {
            console.log("No accumulated POL on the child. Next migration is empty.");
            return;
        }
        console.log("Sized from L2 child state:");
        _printAmount("  polBalance       (exits via Plasma -> Pnext)", s.polBalance);
        _printAmountSPOL("  locallyMintedSPOL                          ", s.locallyMintedSPOL);
        console.log("");
        console.log("L1 effects on migration completion:");
        console.log("  - messenger pulls Pnext POL from bridger via takePOLL1");
        console.log("  - messenger spends Preq POL on controller.buySPOL (Preq <= Pnext expected)");
        console.log("  - controller mints ~locallyMintedSPOL sPOL to messenger");
        console.log("  - messenger bridges that sPOL back to L2 -> closes the migration");
        console.log("  - L1 sPOL totalSupply grows by ~locallyMintedSPOL");
        console.log("  - surplus (Pnext - Preq) goes to controller as fee dust");
        console.log("");
        uint256 available = s.polBalance + s.messengerPOL;
        _printHealthMatrix(s.locallyMintedSPOL, available, s);
        console.log("");
        _printSPOLMatrix(s.locallyMintedSPOL, available, s);
        console.log("");
        _printVerdict(s.locallyMintedSPOL, available, s);
    }

    /// Prints a (5 offsets) x (3 APYs) Preq matrix in POL.YY units. Used only for the
    /// current-migration block, where the operator must combine Preq with their off-script
    /// Pproof to reason about donations.
    function _printPreqMatrix(uint256 spol, State memory s) internal view {
        console.log("Preq matrix (POL the messenger will spend on controller.buySPOL):");
        console.log(string.concat("  offset  | ", APY_LABEL[0], " | ", APY_LABEL[1], " | ", APY_LABEL[2]));
        for (uint256 i = 0; i < OFFSETS_DAYS.length; i++) {
            string memory row = string.concat("  ", _offsetLabel(OFFSETS_DAYS[i]), "  |");
            for (uint256 j = 0; j < APY_BPS.length; j++) {
                uint256 preq = _preqAt(spol, s, OFFSETS_DAYS[i], APY_BPS[j]);
                string memory sep = j + 1 == APY_BPS.length ? "" : " |";
                row = string.concat(row, " ", _padRight(_polFmt(preq), 13), sep);
            }
            console.log(row);
        }
        console.log("  (T0+30d projection is loose: staking parameters and feedPOL can drift.)");
    }

    /// POL view: per (offset, APY) cell, prints `[OK] +delta` or `[!!] -delta` in POL.YY.
    /// **Marker decision is exact-wei** (`available >= preq`) — the printed POL value is rounded
    /// to 2 decimals for display only.
    function _printHealthMatrix(uint256 spol, uint256 available, State memory s) internal view {
        console.log(string.concat("Available (Pnext + messengerPOL): ", _polFmt(available), " POL"));
        console.log("");
        console.log("POL view: delta = available - Preq (marker exact-wei):");
        console.log(string.concat("  offset  | ", APY_LABEL[0], " | ", APY_LABEL[1], " | ", APY_LABEL[2]));
        for (uint256 i = 0; i < OFFSETS_DAYS.length; i++) {
            string memory row = string.concat("  ", _offsetLabel(OFFSETS_DAYS[i]), "  |");
            for (uint256 j = 0; j < APY_BPS.length; j++) {
                uint256 preq = _preqAt(spol, s, OFFSETS_DAYS[i], APY_BPS[j]);
                string memory sep = j + 1 == APY_BPS.length ? "" : " |";
                row = string.concat(row, " ", _padRight(_cellFmt(available, preq), 13), sep);
            }
            console.log(row);
        }
        console.log("  (T0+30d projection is loose: staking parameters and feedPOL can drift.)");
    }

    /// sPOL view: per (offset, APY) cell, prints how much sPOL we could mint by spending
    /// `available` POL on `controller.buySPOL` at the projected rate. Compare against
    /// `requiredSPOL` (printed in the table header) — if a cell is below it, the migration
    /// can't fully mint locallyMintedSPOL on L1 from the available POL alone.
    function _printSPOLMatrix(uint256 requiredSPOL, uint256 available, State memory s) internal view {
        console.log(string.concat("sPOL required (locallyMintedSPOL): ", _polFmt(requiredSPOL), " sPOL"));
        console.log("");
        console.log("sPOL view: amount mintable by spending available POL (= Pnext + messengerPOL):");
        console.log(string.concat("  offset  | ", APY_LABEL[0], " | ", APY_LABEL[1], " | ", APY_LABEL[2]));
        for (uint256 i = 0; i < OFFSETS_DAYS.length; i++) {
            string memory row = string.concat("  ", _offsetLabel(OFFSETS_DAYS[i]), "  |");
            for (uint256 j = 0; j < APY_BPS.length; j++) {
                uint256 spol = _spolFromPolAt(available, s, OFFSETS_DAYS[i], APY_BPS[j]);
                string memory sep = j + 1 == APY_BPS.length ? "" : " |";
                row = string.concat(row, " ", _padRight(_polFmt(spol), 13), sep);
            }
            console.log(row);
        }
        console.log("  (each cell shrinks vs T0 as the L1 rate appreciates -- POL buys less sPOL.)");
    }

    /// Verdict block: for each APY scenario, find the first time-offset at which Preq exceeds
    /// `available` (exact wei). If none within the 30-day window, the scenario is SAFE.
    function _printVerdict(uint256 spol, uint256 available, State memory s) internal view {
        console.log("Verdict (exact wei comparison):");
        for (uint256 j = 0; j < APY_BPS.length; j++) {
            uint256 firstFailDay = type(uint256).max;
            for (uint256 i = 0; i < OFFSETS_DAYS.length; i++) {
                uint256 preq = _preqAt(spol, s, OFFSETS_DAYS[i], APY_BPS[j]);
                if (preq > available) {
                    firstFailDay = OFFSETS_DAYS[i];
                    break;
                }
            }
            if (firstFailDay == type(uint256).max) {
                console.log("  %s: SAFE through T0+30d", APY_LABEL[j]);
            } else if (firstFailDay == 0) {
                console.log("  %s: UNDERFUNDED at T0", APY_LABEL[j]);
            } else {
                console.log("  %s: underfunded by T0+%sd", APY_LABEL[j], firstFailDay);
            }
        }
    }

    /// Preq at offset `daysOffset` under `apyBps`, in wei.
    /// Preq = convertSPOLtoPOL(spol) + 1 = spol * (totaldPOL - feedPOL) / totalsPOL + 1
    /// Projected: Preq_t = Preq_0 * (1 + apyBps * dt / (BPS * SECONDS_PER_YEAR)).
    function _preqAt(uint256 spol, State memory s, uint256 daysOffset, uint256 apyBps)
        internal
        pure
        returns (uint256)
    {
        if (spol == 0) return 0;
        uint256 preq0 = (spol * (s.totaldPOL - s.feedPOL)) / s.totalsPOL + 1;
        uint256 dt = daysOffset * 1 days;
        uint256 mult1e18 = 1e18 + (1e18 * apyBps * dt) / (BPS * SECONDS_PER_YEAR);
        return (preq0 * mult1e18) / 1e18;
    }

    /// sPOL mintable from `pol` POL at offset `daysOffset` under `apyBps`, in wei.
    /// At T0+t the projected effective rate is (totaldPOL - feedPOL) * mult / totalsPOL,
    /// so convertPOLtoSPOL_t(pol) = pol * totalsPOL / ((totaldPOL - feedPOL) * mult / 1e18).
    function _spolFromPolAt(uint256 pol, State memory s, uint256 daysOffset, uint256 apyBps)
        internal
        pure
        returns (uint256)
    {
        if (pol == 0) return 0;
        uint256 dt = daysOffset * 1 days;
        uint256 mult1e18 = 1e18 + (1e18 * apyBps * dt) / (BPS * SECONDS_PER_YEAR);
        uint256 denomScaled = ((s.totaldPOL - s.feedPOL) * mult1e18) / 1e18;
        return (pol * s.totalsPOL) / denomScaled;
    }

    // ----------------------------------------------------------------------- plasma preflight

    function _printPlasmaPreflight(string calldata _network) internal {
        string memory inputJson = vm.readFile("script/input.json");
        string memory scenario = _isMainnet(_network) ? "ethereum-polygon" : "sepolia-amoy";
        address registry = vm.parseJsonAddress(inputJson, string.concat(".", scenario, ".registry"));
        address polTokenL1Cfg = vm.parseJsonAddress(inputJson, string.concat(".", scenario, ".polTokenL1"));
        address maticTokenL1Cfg = vm.parseJsonAddress(inputJson, string.concat(".", scenario, ".maticTokenL1"));
        address polTokenL2Cfg = vm.parseJsonAddress(inputJson, string.concat(".", scenario, ".polTokenL2"));

        // _loadState left us on L2; flip back to L1 to query Plasma.
        vm.createSelectFork(vm.envString("L1_RPC_URL"));

        address erc20Predicate = _stat(registry, abi.encodeWithSignature("erc20Predicate()"));
        address withdrawManager = _stat(registry, abi.encodeWithSignature("getWithdrawManagerAddress()"));
        address depositManager = _stat(registry, abi.encodeWithSignature("getDepositManagerAddress()"));
        address registryMatic = _stat(registry, abi.encodeWithSignature("contractMap(bytes32)", keccak256("matic")));
        address registryPol = _stat(registry, abi.encodeWithSignature("contractMap(bytes32)", keccak256("pol")));
        address mappedChild = _stat(registry, abi.encodeWithSignature("rootToChildToken(address)", maticTokenL1Cfg));
        // Predicate authorization status: returns enum (0=Invalid,1=ERC20,2=ERC721,3=Custom)
        uint256 predicateType =
            uint256(uint160(_stat(registry, abi.encodeWithSignature("predicates(address)", erc20Predicate))));
        // HALF_EXIT_PERIOD is governance-mutable via WithdrawManager.updateExitPeriod(uint256).
        uint256 halfExitPeriod;
        {
            (bool ok, bytes memory ret) = withdrawManager.staticcall(abi.encodeWithSignature("HALF_EXIT_PERIOD()"));
            require(ok && ret.length >= 32, "could not read HALF_EXIT_PERIOD");
            halfExitPeriod = abi.decode(ret, (uint256));
        }

        console.log("");
        console.log("=================================================================");
        console.log("Plasma preflight");
        console.log("=================================================================");
        _printAddrCheck("registry.erc20Predicate()           ", erc20Predicate, "");
        _printPredicateTypeCheck("  predicates[erc20Predicate]._type ", predicateType);
        _printAddrCheck("registry.contractMap(WITHDRAW_MANAGER)", withdrawManager, "");
        _printAddrCheck("registry.contractMap(DEPOSIT_MANAGER) ", depositManager, "");
        _printAddrCheck(
            "registry.contractMap(matic)        == cfg.maticTokenL1 ", registryMatic, _toString(maticTokenL1Cfg)
        );
        require(registryMatic == maticTokenL1Cfg, "registry.matic != cfg.maticTokenL1 -- exit will not auto-pay POL");
        _printAddrCheck(
            "registry.contractMap(pol)          == cfg.polTokenL1   ", registryPol, _toString(polTokenL1Cfg)
        );
        require(registryPol == polTokenL1Cfg, "registry.pol != cfg.polTokenL1 -- bridger will not receive expected POL");
        _printAddrCheck(
            "registry.rootToChildToken(matic)   == cfg.polTokenL2   ", mappedChild, _toString(polTokenL2Cfg)
        );
        require(mappedChild == polTokenL2Cfg, "rootToChildToken[matic] != polTokenL2 -- exits would fail");
        console.log("WithdrawManager.HALF_EXIT_PERIOD          : %s seconds", halfExitPeriod);
        if (halfExitPeriod < 60) {
            console.log("  -> exit challenge window is effectively next-block. Migration finishes in hours.");
        } else if (halfExitPeriod <= 302_400) {
            console.log("  -> nominal half-period. Plasma exit is up to %s days.", halfExitPeriod / 1 days);
        } else {
            console.log("  -> half-period unusually long (%s days). Re-plan timeline.", halfExitPeriod / 1 days);
        }
        console.log("Plasma preflight passed.");
    }

    // ----------------------------------------------------------------------- helpers

    function _stat(address target, bytes memory data) internal view returns (address) {
        (bool ok, bytes memory ret) = target.staticcall(data);
        require(ok && ret.length >= 32, "registry call failed");
        return address(uint160(uint256(bytes32(ret))));
    }

    function _printAddrCheck(string memory label, address got, string memory expected) internal view {
        if (bytes(expected).length == 0) {
            console.log(string.concat(label, ": %s"), got);
        } else {
            console.log(string.concat(label, ": %s   (expected %s)"), got, expected);
        }
    }

    function _printPredicateTypeCheck(string memory label, uint256 t) internal view {
        if (t == 1) {
            console.log(string.concat(label, ": ERC20 (authorised)"));
        } else if (t == 0) {
            revert("erc20Predicate is NOT authorised in registry.predicates -- exits would revert");
        } else {
            console.log(string.concat(label, ": type=%s (unexpected, but non-zero)"), t);
        }
    }

    function _toString(address a) internal view returns (string memory) {
        return vm.toString(a);
    }

    function _printAmount(string memory label, uint256 value) internal pure {
        console.log(string.concat(label, ": %s wei  (~%s POL)"), value, value / 1e18);
    }

    function _printAmountSPOL(string memory label, uint256 value) internal pure {
        console.log(string.concat(label, ": %s wei  (~%s sPOL)"), value, value / 1e18);
    }

    /// Formats a wei amount as "X.YY" POL (truncated; for display only — never used for
    /// safety judgments).
    function _polFmt(uint256 weiAmt) internal pure returns (string memory) {
        uint256 cents = (weiAmt * 100) / 1e18;
        uint256 polPart = cents / 100;
        uint256 fracPart = cents % 100;
        string memory frac = fracPart < 10 ? string.concat("0", vm.toString(fracPart)) : vm.toString(fracPart);
        return string.concat(vm.toString(polPart), ".", frac);
    }

    /// Formats a 1e18-fixed value as "X.YYYYYY" (6 decimals). For rate display.
    function _rateFmt(uint256 fixed1e18) internal pure returns (string memory) {
        uint256 micro = fixed1e18 / 1e12; // value * 1e6
        uint256 whole = micro / 1e6;
        uint256 frac = micro % 1e6;
        // Left-pad frac to 6 chars with zeros.
        string memory fracStr = vm.toString(frac);
        bytes memory pad;
        if (frac < 10) pad = "00000";
        else if (frac < 100) pad = "0000";
        else if (frac < 1000) pad = "000";
        else if (frac < 10000) pad = "00";
        else if (frac < 100000) pad = "0";
        else pad = "";
        return string.concat(vm.toString(whole), ".", string(pad), fracStr);
    }

    /// Formats a value scaled by 100 (i.e. 0.01-bps units) as "X.YY" bps.
    /// _bpsFmtX100(3000) -> "30.00"  (i.e. 30 bps = 0.3%)
    /// _bpsFmtX100(523)  -> "5.23"   (5.23 bps = 0.0523%)
    function _bpsFmtX100(uint256 bpsX100) internal pure returns (string memory) {
        uint256 whole = bpsX100 / 100;
        uint256 frac = bpsX100 % 100;
        string memory fracStr = frac < 10 ? string.concat("0", vm.toString(frac)) : vm.toString(frac);
        return string.concat(vm.toString(whole), ".", fracStr);
    }

    /// "T0+ 0d" / "T0+30d" — fixed 6-char width.
    function _offsetLabel(uint256 d) internal pure returns (string memory) {
        if (d < 10) return string.concat("T0+ ", vm.toString(d), "d");
        return string.concat("T0+", vm.toString(d), "d");
    }

    /// Cell content. Marker chosen by exact-wei comparison; numeric value rounded for display.
    function _cellFmt(uint256 available, uint256 preq) internal pure returns (string memory) {
        if (available >= preq) {
            return string.concat("[OK] +", _polFmt(available - preq));
        } else {
            return string.concat("[!!] -", _polFmt(preq - available));
        }
    }

    function _padRight(string memory s, uint256 width) internal pure returns (string memory) {
        bytes memory b = bytes(s);
        if (b.length >= width) return s;
        bytes memory pad = new bytes(width - b.length);
        for (uint256 i; i < pad.length; i++) {
            pad[i] = 0x20;
        }
        return string.concat(s, string(pad));
    }

    function _isMainnet(string memory _network) internal pure returns (bool) {
        return keccak256(bytes(_network)) == keccak256(bytes("mainnet"));
    }
}
