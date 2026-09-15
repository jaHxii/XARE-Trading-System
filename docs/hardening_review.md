# XARE v1.0 — Pre-Compilation Hardening Review

Status: **review complete → approved P0 items implemented in v0.17.0**.
Nothing in this document was implemented before being written here (spec §29).
Every "exists" claim was verified by reading the code on 2026-09-15 (commit `82fb323`).
No performance claims are made anywhere in this document.

---

## A. Current architecture audit (what exists and works)

**Layer separation (verified clean):** DATA (`MarketData`) → FEATURES (`Indicators`) → CONTEXT (`MultiTimeframe`, `RegimeEngine`, `StructureEngine`, `SessionEngine`, `LiquidityEngine`) → SIGNALS (`SignalEngine`, 6 setups + NO_TRADE reasons) → SCORING (`ScoreEngine`, 8 components, sum-100 validated) → RISK (`RiskEngine`: pure sizing math + stateful equity/limits) → PLAN (`ExecutionEngine.XareBuildTradePlan`: band→caps→SL→TP→sizing→margin, pure) → GATE (`SafetyEngine.Go`: one choke point, ordered reasons, emergency latch) → SEND (`ExecutionEngine`, the only file containing `OrderSend` — test-enforced) → MANAGE (`PositionManager` state machine + `ExitEngine` pure decisions) → LOG (`Logger`, `ResearchLogger`, journal CSV).

**Strengths to preserve (not rewritten):**
- Pure-math cores everywhere (sizing, SL/TP, states, blackout windows, exits) — all unit-testable, all broker properties injected.
- Dynamic symbol discovery at init; spec-drift warning against the recorded XAUUSDm reference; sizing refuses below-min volume (never pads up).
- Single safety gate with machine-readable ordered block reasons; sticky emergency latch; `OrderSend` confined to one file by regression test.
- Signal-only default; trading off by default; mode/permission sanity validation.
- Hard SL mandatory; tighten-only management ladder (partial → BE → trail); time exits; regime/reversal exits.
- SELF_TEST (15 groups) + 134 Python tests, including layout guards, trade-path guards, and contract mirrors.

**Weaknesses found (drive section C):**
1. **No state persistence** — `PositionManager` has no adopt/sync-on-restart path. After a VPS/terminal restart the EA loses: streak/cooldown, daily/weekly anchors, peak equity, per-position management state (`be_done`, `partial_done`, `bars_in_trade`, entry context). Consequences: duplicate-management risk, reset streaks, wrong daily anchors. **Highest-severity gap.**
2. **News filter is CSV-only** — MT5's built-in Economic Calendar is unused; no importance/currency/caching/failure-detection semantics (§14 hardening).
3. **Adaptive risk is single-factor** — only the DD-state ladder scales risk; no bounded quality/regime/volatility/performance factors (§6).
4. **No DEFENSIVE account-health state** — the ladder is NORMAL→CAUTION→REDUCED→HALTED; no intermediate "trade defensively" state driven by weekly loss / losing days / margin level (§10).
5. **No weekend/Friday policy** — no Friday entry cutoff, no weekend state, nothing prevents a Friday 21:55 entry before the weekend gap (§15).
6. **No margin-level input to safety** — free-margin budget is checked per plan, but a falling account margin level never blocks new entries (§10/§13).
7. **Breakout detection is thin** — BOS + ≥0.10 ATR beyond; no ATR-normalized strength banding beyond one +10 confidence bump, no candle-body/momentum/tick-activity criteria, no per-variant research tagging (BREAKOUT vs +RETEST vs +MOMENTUM vs +MTF) beyond the existing setup enum (§2/§3).
8. **No startup health check** — init logs are verbose but there is no single `XARE HEALTH: READY/BLOCKED` verdict (§21).
9. **No slippage cooldown hook** — execution records slippage but nothing reacts to abnormal slippage (§12/§18).
10. **Dashboard lacks** account stage, weekly P/L, margin level, broker/server info, health verdict (§22).

---

## B. Missing-feature report (competitor categories A–Z)

Legend: ✔ implemented · ◑ partial · ✘ missing. "Useful?" = for XARE's research-grade, single-position XAUUSD scope. "Overfit risk" = of tuning the feature later. "Test" = how to evaluate objectively.

| # | Category | State | Useful for XARE? | Overfit risk | Objective test |
|---|---|---|---|---|---|
| A | MTF trend confirmation | ✔ (H4/H1/M15 alignment + MTF score component) | yes | low | alignment-stratified expectancy |
| B | Breakout detection | ✔ (BOS-based `BREAKOUT` setup) | yes | medium | regime-stratified PF by setup |
| C | Breakout confirmation/buffer | ◑ (0.10 ATR distance + one 0.25 ATR bump) | yes — formalize strength bands | medium | OOS PF per strength band |
| D | Breakout-retest entries | ✔ (`BREAKOUT_RETEST`, BOS memory + retest window) | yes | low | immediate vs retest expectancy A/B |
| E | Pullback confirmation | ✔ (zone touch + rejection candle + RSI band + ROC re-accel) | yes | low | per-component ablation |
| F | ATR-based stops | ✔ (ATR/hybrid/structure + floors) | yes | low | SL-mode A/B OOS |
| G | ATR-based sizing | ✔ (risk-based sizing; ATR enters via SL distance) | yes | low | invariant: loss ≤ risk money |
| H | Partial take profit | ✔ (1-shot partial + managed remainder) | yes | medium | partial on/off OOS |
| I | Break-even | ✔ | yes | low | BE on/off OOS |
| J | Trailing stop | ✔ (ATR trailing, tighten-only) | yes | medium | trail mult sensitivity |
| K | Profit locking | ◑ (BE lock points exist) | yes — add **equity milestone lock** (P1) | medium | lock on/off + threshold sweep |
| L | Session filtering | ✔ (sessions + score component; per-session analytics) | yes | medium | session-stratified results |
| M | News protection | ◑ (CSV-only; no MT5 calendar) | yes — P1: calendar engine | low | blackout-window event study |
| N | Spread protection | ✔ (entry + abnormal gates, logged) | yes | low | spread-stratified expectancy |
| O | Slippage/execution protection | ◑ (recorded; no reaction) | yes — P2: slippage cooldown + stress module | low | stress runs vs baseline |
| P | Daily loss limit | ✔ | yes | low | threshold monotonicity |
| Q | Weekly loss limit | ✔ | yes | low | same |
| R | Max DD circuit breaker | ✔ (HALTED latch + emergency) | yes | low | replay tests |
| S | Consecutive-loss protection | ✔ (streak + cooldown) | yes | low | streak replay |
| T | Re-entry cooldown | ◑ (loss-streak cooldown only) | yes — P1: post-SL + slippage cooldowns | low | trade-frequency analysis |
| U | Broker symbol/volume/margin validation | ✔ (full discovery + per-order margin + drift check) | yes | none | T13/T13b + live SELF_TEST |
| V | Regime-dependent strategy selection | ◑ (gates in SignalEngine; not a formal matrix) | yes — P1: explicit eligibility matrix, documented | medium | matrix-ablation OOS |
| W | Strategy-specific risk allocation | ✘ (single risk per trade) | defer — needs data; premature for v1 | high | per-setup expectancy first |
| X | Equity-aware sizing | ✔ (equity × risk% × state factor) | yes | low | sizing invariants |
| Y | Weekend/Friday protection | ✘ | yes — P1 (gap risk is real on XAUUSD) | low | weekend-gap event study |
| Z | Recovery/restart persistence | ✘ | **critical** — P0 | none | restart integration test |

Additional gaps found beyond the A–Z list: **micro-account minimum-volume risk explanation** (§7: current code refuses silently as `XARE_BR_VOLUME` — must say *why* + show computed risk %), **account capital stages** (§8), **daily circuit-breaker logging** (`TRADING HALTED — REASON`), **margin-level input** (§10), **max consecutive losing days** (§11), **max trades per session** (§12), **execution-quality validation of tick availability** (§13), **calendar failure detection** (§14), **startup health verdict** (§21), **MAE/MFE tracking** (§26 — defer, needs per-bar excursion capture; see D).

---

## C. Features recommended for v1.0 (approved for implementation)

**P0 — correctness/survival (blocking):**
1. **State persistence + crash recovery** (`StateStore.mqh`): atomic JSON state file; save streak/cooldown, day/week/peak anchors, daily/weekly trade counts, Friday cutoff state, per-open-position management context; load + reconcile on init; never duplicate management actions; tester-safe (disabled).
2. **Micro-account clarity**: `XARE_BR_VOLUME` refusal carries the computed risk% of using minimum volume + human-readable `MINIMUM VOLUME TOO RISKY` text (§7). No override by default; existing `allow_min_lot_override` stays OFF and now also logs the exact risk it would take.
3. **Startup health check** (§21): DATA/INDICATORS/SYMBOL/BROKER/MARGIN/PERMISSION/NEWS/TIME/RISK/EXECUTION/STATE/LOGGING checks → single `XARE HEALTH: READY|BLOCKED` line + reasons; BLOCKED blocks sends (not signal evaluation).
4. **Daily/weekly circuit-breaker log lines**: `TRADING HALTED — REASON` emitted once per breach (§11).

**P1 — high-value robustness:**
5. **Adaptive risk engine (§6)**: final risk = base × quality × regime × volatility × account-health × drawdown(already) × recent-performance, each factor hard-bounded [0.5, 1.0] (risk can only shrink or stay), global cap unchanged, product clamped to [0, base]. Pure function + SELF_TEST + Python mirror.
6. **Account survival state DEFENSIVE (§10)** between REDUCED and HALTED: inputs = weekly breach proximity, consecutive losing days, margin level, exec errors. DEFENSIVE blocks counter-trend/mean-reversion setups and halves risk (folded into adaptive-risk health factor). `TRADING HALTED` semantics preserved at HALTED.
7. **Profit lock / capital floor (§9)**: configurable milestone→floor ladder (default OFF), risk-reduction + halt behavior, every transition logged; explicitly documented as unvalidated hypothesis.
8. **Capital stages (§8)**: MICRO/GROWTH/STANDARD/SCALE/DEFENSIVE derived from equity + health state (documented thresholds, default mapping MICRO<500≤GROWTH<5000≤STANDARD<50000≤SCALE), stage only ever *reduces* risk (stage factor in the adaptive product), transitions logged, research-only framing.
9. **Weekend/Friday engine (§15)**: Friday final-entry cutoff (server time), WEEKEND state, optional Friday close-all (default OFF), restart-safe via state store.
10. **Cooldown suite (§12)**: post-stop-loss cooldown (bars), post-abnormal-slippage cooldown, consecutive-losing-days counter, max-trades-per-session cap. All additive to existing streak cooldown.
11. **MT5 Economic Calendar news engine (§14)**: native `CalendarValueHistory` when available; HIGH importance + XAU/USD currencies; pre/post windows; hourly cache; **failure → fail-safe clear** (same as today's CSV mode) with a logged WARNING; entries-only blocking (never auto-closes); cleanly degrades to CSV filter.
12. **Regime-strategy matrix (§5/§23)**: formal, documented, code-level eligibility function `XareSetupAllowedInRegime(setup, regime, health_state)` — current implicit gates made explicit and testable; DEFENSIVE health additionally bans RANGE_REVERSAL/SWEEP counter-trend entries. No behavior change vs today's gates except the DEFENSIVE additions (diff-tested).
13. **Breakout hardening (§2/§3)**: ATR-normalized strength bands (weak/normal/strong) feeding setup confidence; candle-body ≥ fraction of range; momentum check (ROC sign/DI spread); tick-activity context when available; breakout/retest variants already exist and remain the research handle. Additive criteria only; documented hypotheses.
14. **Dashboard extensions (§22)**: account number/broker/server time, weekly P/L, margin level, account stage, health verdict, NO-TRADE reason already present.

**P2 — research tooling (Python):**
15. **Execution-stress module** (`python/xare/stress.py`): journal replay under spread ×1.5/×2 and slippage add-ons; PF/expectancy/DD deltas → verdict warnings (§18).
16. Python mirrors for every new pure function.

## D. Features rejected (and why)

| Feature | Why rejected for v1.0 |
|---|---|
| Strategy-specific risk allocation (W) | Needs per-setup expectancy data that does not exist yet; adding it now would be inventing numbers. Revisit after baseline backtests (spec §40+). |
| MAE/MFE tracking (26) | Requires intrabar excursion capture per open position; valuable but a monitoring change with tester-visible overhead. Deferred to the research-logging iteration that adds it to the journal schema (next milestone). |
| Grid/basket/recovery anything (§24) | Prohibited by the master spec; single position per symbol stands. |
| Martingale / loss-recryption sizing | Prohibited (§31). Adaptive factors are bounded ≤1.0 — risk never grows because of losses. |
| Machine learning (§25) | Prohibited before a deterministic baseline demonstrates robustness (spec §66). |
| Auto-closing positions around news (§14) | No evidence yet; entries-only blocking is the defensible default. Configurable closure stays OFF. |
| Replacing the CSV news filter with calendar-only | Calendar availability differs by broker/tester; keep CSV as fallback. |
| Per-session strategy switching | Matrix (item 12) already encodes regime→setup eligibility; session effects are measured, not enforced, until data justifies it. |
| Aggressive defaults anywhere | All new defaults are OFF or risk-reducing (§63). |

## E. Overfitting-risk assessment

- **Highest risk:** breakout strength bands (13) and matrix thresholds (12) — mitigations: criteria are coarse bands (not continuous magic numbers), logged per-bar for later stratified analysis, defaults documented as hypotheses, and **no optimization until the untouched test protocol runs** (§27).
- **Bounded-by-construction:** adaptive risk factors clamped ≤1.0; capital stages only reduce; profit lock thresholds are config, default OFF; weekend cutoff is one config time.
- **No new "profit-maximizing" surface:** every P0/P1 feature either blocks trades, reduces risk, or adds observability. None can increase profit on a backtest by itself — the honest safeguard against tuning-into-existence.
- Discipline: thresholds live in `Config.mqh` + `docs/parameters.md`; walk-forward will validate §9 lock thresholds only on development/validation data, never the untouched set.

## F. New modules required

| Module | Contents |
|---|---|
| `mql5/Include/XARE/StateStore.mqh` | atomic state file save/load/reconcile (§20); pure encode/parse helpers + SELF_TESTable math |
| `mql5/Include/XARE/HealthCheck.mqh` | §21 component checks + verdict struct (checks executed by the EA; struct + aggregation pure) |

(Modified modules listed in K; no other new files.)

## G. New parameters (all documented hypotheses; defaults OFF or risk-reducing)

```
Adaptive risk:   InpFactorMin=0.5 (hard lower bound per factor); factors quality/regime/vol/
                 health/performance derived from existing evaluated context — no new magic numbers
Health state:    InpMaxConsecLosingDays=2; InpMinMarginLevelPct=200; InpDefensiveRiskMult=0.5
Profit lock:     InpProfitLockEnabled=false; InpLockMilestonePct=10; InpLockFloorPct=5
Stages:          InpStagesEnabled=true; boundaries 500/5000/50000 (MICRO/GROWTH/STANDARD/SCALE)
Weekend:         InpFridayCutoffMin=1200 (Fri 20:00 server); InpFridayCloseAll=false
Cooldowns:       InpPostSLCooldownBars=4; InpSlipCooldownPoints=150; InpSlipCooldownBars=4;
                 InpMaxTradesPerSession=2
News:            InpNewsSource=CALENDAR_IF_AVAILABLE (fallback CSV); importance=HIGH; ccy=XAU+USD
Breakout:        InpBreakoutBodyMinPct=50; InpBreakoutStrongATR=0.5
Health:          InpHealthCheck=true (blocks sends when BLOCKED)
```

## H. Test plan

1. **MQL5 SELF_TEST new groups:** T16 adaptive-risk bounds (each factor min/max, product clamp, never > base); T17 state encode/parse round-trip + atomic-write naming; T18 Friday-cutoff minute math + weekend state; T19 health aggregation READY/BLOCKED; T20 stage ladder + lock ladder; T21 matrix eligibility (incl. DEFENSIVE bans); T22 breakout strength banding edges. All pure fixtures.
2. **Python mirrors:** `test_hardening.py` — same fixtures as T16–T22.
3. **Execution-stress tests:** synthetic journal → stress deltas computed, deterministic seeds.
4. **Integration:** layout guard updated (2 new modules in the mandatory list); trade-path guard still passes (`OrderSend` only in ExecutionEngine); pytest full suite green.
5. **Compile gate:** MetaEditor 0 errors / 0 warnings after each phase.

## I. Regression-test plan

- Existing 134 tests must stay green (no behavior change to sizing/gating without a matching test update, and no update may weaken an invariant).
- New permanent guards: adaptive-risk product can never exceed base risk; state restore must never reset a live position's management flags to defaults; Friday cutoff must block `TrySendPlan` (asserted at unit level via the pure cutoff predicate).
- Bug-fix rule stays: every future defect in these modules gets a regression test.

## J. Broker-environment validation checklist (requires the user's MT5 — not executable here)

1. Copy includes + EA → compile in MetaEditor → 0/0.
2. `InpSelfTest=true` on M15 XAUUSDm chart → all groups PASS (incl. T13b real-spec fixtures).
3. Verify INIT log: symbol profile match line, `XARE HEALTH: READY`, news-engine state (CALENDAR | CSV | DISABLED-fail-safe).
4. SIGNAL_ONLY: DECISION/PLAN lines agree with dashboard; NO-TRADE reasons populated.
5. Restart test: attach with an open demo position → adoption line, no duplicate orders, management state restored from `MQL5\Files\XARE\state.json`.
6. Friday cutoff: verify first blocked entry after cutoff with `WEEKEND/Friday cutoff` reason.
7. Confirm server-time offset for session params (docs/parameters.md note).

## K. Files modified (exact)

`mql5/Include/XARE/Types.mqh` (health/stage enums, block reasons, snapshot fields) · `Config.mqh` (§G params + defaults) · `RiskEngine.mqh` (adaptive factors, DEFENSIVE, losing-days, stages, lock, session trade count) · `SafetyEngine.mqh` (new context fields: margin level, health, weekend, cooldown kinds) · `ExecutionEngine.mqh` (volume-refusal detail text; slippage readout) · `ExitEngine.mqh` (no change expected — verified) · `SignalEngine.mqh` (breakout strength criteria + matrix hook) · `Diagnostics.mqh` (dashboard rows) · `NewsFilter.mqh` (calendar source + failure detection) · `XARE.mq5` (wiring, inputs, SELF_TEST T16–T22, health check, state save/load, halted log lines) · `tests/integration/test_repo_layout.py` · `tests/regression/test_m1_safety_guards.py` (if needed) · `docs/parameters.md`, `docs/risk.md`, `docs/architecture.md`, `docs/changelog.md`.

## L. Files created (exact)

`mql5/Include/XARE/StateStore.mqh` · `mql5/Include/XARE/HealthCheck.mqh` · `tests/unit/test_hardening.py` · `python/xare/stress.py` · this document.

---

**Approved scope = C items 1–16. Implementation follows; optimization does NOT begin (§27/§30).**
