# Changelog

All notable changes to XARE. Format based on Keep a Changelog; versioning is
semantic (v0.x = research platform, v1.0.0 = production candidate, which
requires the full acceptance battery in `docs/testing.md`).

## [v0.14.0] — 2026-09-15 (M13–M18)

### Added
- **M13** `ResearchLogger.mqh`: per-closed-bar feature/verdict CSV (§37,
  features only — no future outcomes), RESEARCH mode only; explicit
  initialization of every verdict struct before `Evaluate` (fixed a latent
  M7-era uninitialized-read now exposed by the research row).
  `PerformanceTracker.mqh`: rolling closed-trade stats (§39 subset) + the
  §17 expectancy filter that **abstains below 30 trades and blocks only on
  clearly negative expectancy + PF<1** — never invents values.
- **M14** `python/xare/`: `metrics.py` (all §39 metrics incl. Sharpe,
  Sortino, recovery factor, drawdown %, streaks), `breakdown()` by
  regime/session/setup/direction, monthly/yearly returns; `warnings.py`
  (§44 sample-size/overfit/concentration/drawdown warnings + ROBUST /
  QUESTIONABLE / OVERFIT_RISK / FAIL classifier); `visualization.py`
  (headless equity/drawdown/R-histogram PNGs).
- **M15** `report.py`: full §55 report with every required metric and
  breakdown section; **explicit `NOT EXECUTED` status when no journal
  exists** — no fabricated numbers (§60). `cli.py`: `report`,
  `walk-forward`, `monte-carlo` commands over a real journal CSV.
- **M16** `walk_forward.py`: rolling TRAIN→TEST windows, every window
  reported (bad windows never hidden), explicit negative-window counts.
- **M17** `monte_carlo.py`: shuffle + bootstrap resampling with fixed seed,
  drawdown/streak/terminal-return percentiles, breach probability, and a
  mandatory disclaimer that it models randomness, not profitability.
- **M18** `stability.py`: neighbor-perturbation sensitivity over a caller
  supplied evaluator; plateau verdict (ROBUST / QUESTIONABLE /
  OVERFIT_RISK / NOT EVALUATED) — stable regions, not magic values.
- Tests: 25 new analytics tests (134 total passing).

### Honest status
- **No backtest has been executed.** The Python framework is fully
  exercised on synthetic deterministic fixtures; every real-data path is
  gated on a journal that does not exist yet, and reports render as
  `NOT EXECUTED` until then.

## [v0.12.0] — 2026-09-15 (M10–M12)

### Added
- `ExecutionEngine.mqh`: pure plan builder (`XareBuildTradePlan` — band
  gate, position/trade caps, SL from the LIVE entry, tick-grid-safe
  SL/TP, sizing, margin budget) + the live send layer (§29 validation
  chain, broker filling-mode query, deviation guard, duplicate-order
  protection per bar and per open position, fill/slippage recording,
  `ApplyManagement` with a tighten-only last line of defense).
- `PositionManager.mqh`: position state machine (§30) — poll by magic,
  close detection via history deals, exit classification (HARD_SL/TP by
  price, R multiple from the actual stop distance), duplicate guard.
- `ExitEngine.mqh`: pure management decisions (§22/§23) — break-even
  (with lock), ATR trailing (ratchet-only), one-shot partial, hard time
  exit (bars/minutes), regime-flip exit, signal-reversal exit; priority
  ordered, every order explainable.
- `SafetyEngine.mqh`: ONE GO/BLOCK gate (§33) with documented priority
  (emergency → switch → halt → daily → weekly → cooldown → exec-fail →
  data → quotes → symbol → equity → news → spread → margin) and the
  §51 emergency latch (sticky, first reason wins).
- `NewsFilter.mqh`: optional HIGH-impact calendar CSV in MQL5\Common;
  blackouts only when data exists, fail-safe clear when not (§14).
- EA: full order flow armed behind the gate — `TrySendPlan` (context
  assembly + send), `ManagePosition`, `CheckPositionClosed` (journal row
  + loss-streak feed), emergency triggers (cap breach, 5+ execution
  failures, volume-ceiling breach), daily-limit close (default off).
- SELF_TEST T14 (plan builder: 7 verified fixtures) and T15 (gate
  priority, emergency latch, news windows).
- Python mirrors: `test_execution_plan.py` (14),
  `test_exit_engine_contract.py` (15), `test_safety_contract.py` (16).

### Fixed
- Invented `POSITION_VOLUME_INITIAL` property caught by the compiler —
  replaced with tracked-context volume comparison (anti-hallucination).
- T14 fixtures had wrong expected math (would have failed in the tester
  despite compiling); rewritten with verified arithmetic.
- Trade-path guards refined: `OrderSend` confined to ExecutionEngine.mqh;
  word-boundary regex so `CheckPositionClosed` is not a false positive.

### Verified
- Compile: **0 errors, 0 warnings** (`reports/output/compile_m12.log`).
- Python suite: 109 passed. Trading still requires DEMO/PRODUCTION/BACKTEST
  mode AND the explicit switch; default install cannot trade.

## [v0.9.0] — 2026-09-15 (M9)

### Added
- `RiskEngine.mqh`: pure financial-math core + stateful risk tracker.
  - Point value per lot derived **only** from live broker properties
    (`tick_value × point / tick_size`) — nothing about XAUUSD contracts is
    assumed; invalid properties refuse sizing outright.
  - Volume-for-risk with **down-only snapping** to the broker volume step,
    min/max clamps, and an emergency hard lot ceiling; safe volume below the
    broker minimum ⇒ **trade skipped** (never padded up; §49 override off).
  - Drawdown state ladder (NORMAL/CAUTION/REDUCED/HALTED) from peak and
    daily drawdown; risk scaled **down only** per state; HALTED = zero risk.
  - Broker-server-time daily/weekly anchors and rollovers, trade counter,
    consecutive-loss streak with bar-based cooldown.
  - Stop distance (ATR / structure / hybrid-widest with hard floor) and TP
    distance (fixed-R / ATR) pure builders — no fixed dollar distances.
- EA: risk inputs (conservative defaults: 0.5% risk, 2% daily, 5% weekly,
  15% halt, 1 position, 0.5-lot emergency cap), risk refresh on every tick,
  live risk state + daily P/L + drawdown on the dashboard.
- SELF_TEST group T13: point value (standard + odd tick), sizing, below-min
  refusal, emergency cap, step snap-down, invalid properties, state ladder,
  effective-risk scaling, SL/TP builders incl. wrong-side structure and
  no-basis refusal, cooldown math.
- Python mirror tests `test_risk_math.py` (21 tests) incl. a regression:
  a 0.1-step account with raw 0.02 lots must be **refused**, not snapped to
  the minimum (which would exceed the configured risk).

### Fixed
- `Indicators.mqh`: `Last()` returned a never-written cache (features never
  copied into `m_cache` after `Update`) — latent M2 bug, found during M9
  review; dashboard feature display would have been zeros.

### Verified
- Compile: **0 errors, 0 warnings** (`reports/output/compile_m9.log`).
- Python suite: 64 passed. No trade paths yet (orders arrive in M10).

## [v0.8.0] — 2026-09-15 (M8)

### Added
- `ScoreEngine.mqh`: pure 0–100 weighted score with a full component
  breakdown (trend/mtf/structure/momentum/liquidity/volatility/session/setup,
  each earned-vs-max with a note) and band classification
  (NONE / CANDIDATE / TRADE / STRONG). The score is NOT a probability.
- Documented conflict policy: MIXED alignment scores 0 on the MTF component;
  counter-trend setups (range/sweep reversal) earn trend points only at a
  reduced 25% credit — conflicts always cost points.
- Volatility component driven by the regime engine's ATR percentile
  (exposed via `RegimeEngine.LastATRPercentile()`), not recomputed.
- Config: 8 weights (sum must equal 100 — enforced at init, EA refuses to
  start otherwise) + 4 band thresholds, all exposed as EA inputs.
- EA: SCORE log line with every component; DECISION line now carries
  score + band; dashboard shows the live score and regime label/confidence.
- SELF_TEST groups T11 (weight validator, band edges) and T12 (exact
  component arithmetic: aligned pullback = 79, counter-trend = 64,
  MIXED zeroes MTF, no-signal not scoreable).
- Python contract tests mirroring T11/T12 (15 tests).

### Verified
- Compile: **0 errors, 0 warnings** (`reports/output/compile_m8.log`).
- Python suite: 41 passed.
- No-trade audit: no OrderSend/CTrade/position-modify paths (grep-verified).

## [v0.7.0] — 2026-09-15 (M7)

### Added
- `SignalEngine.mqh`: pure decision module — six setup detectors
  (TREND_CONTINUATION, TREND_PULLBACK, BREAKOUT, BREAKOUT_RETEST,
  RANGE_REVERSAL, LIQUIDITY_SWEEP_REVERSAL), gated evaluation producing
  either a candidate (direction, setup, confidence, entry zone,
  invalidation, evidence) or NO_TRADE with a machine-readable reason
  (INSUFFICIENT_DATA, REGIME_INCOMPATIBLE, REGIME_CONFIDENCE,
  ALIGNMENT_CONFLICT, NO_SETUP_TRIGGER, SETUP_DISABLED).
- Documented gate order + detector priority; NEUTRAL alignment permits
  counter-move setups only; MIXED blocks everything.
- EA: DECISION line printed for **every new M15 candle** (signal-only mode,
  no orders); decision shown on dashboard.
- SELF_TEST groups T9 (gates) and T10 (detection, direction policy,
  disabled setups, conflicts) on synthetic contexts.
- Python contract tests mirroring the MQL5 semantics (8 tests).

### Fixed
- SELF_TEST T9a fixture itself could trigger pullback/continuation (would
  have failed in the tester); replaced with a genuinely non-triggering bar.

### Verified
- Compile: **0 errors, 0 warnings** (`reports/output/compile_m7.log`).
- Python suite: 26 passed.

## [v0.6.0] — 2026-09-15 (M6 + integration review)

### Added
- `SessionEngine.mqh`: Asian/London/NY windows in **broker server time**
  (minutes from midnight, configurable), overlap derived as London ∩ NY with
  documented priority, per-episode high/low/range accumulation from closed
  bars. Local time is never used.
- `LiquidityEngine.mqh`: objective liquidity levels (PDH/PDL via D1 shift 1,
  session episode extremes, recent confirmed swings) and sweep detection with
  explicit mechanics: wick through level by ≥ `sweep_atr_multiple`·ATR with
  close back on the origin side; close beyond = break, not sweep. Priority
  PD > session > swing. No smart-money claims.
- SELF_TEST groups T8 (session classifier priority) and T8b (sweep math incl.
  negative cases: close-beyond and shallow-wick are NOT sweeps).
- Config: session window minutes, `sweep_atr_multiple`, `sweep_reclaim_bars`
  (reserved), `swing_liquidity_lookback` + EA inputs.

### Integration review (M2–M6)
- Data-flow chain verified consistent: new-bar gate → closed bar → features →
  MTF → regime → structure → session → liquidity → logs/dashboard; each
  engine consumes only upstream verdicts; no downward or sideways coupling.
- Architecture doc updated with the implemented flow, module map additions,
  and explicit "known reserves" section.
- All threshold parameters now configurable in `Config.mqh` + EA inputs.

### Verified
- Compile: **0 errors, 0 warnings** (`reports/output/compile_m6.log`).
- EA contains no trade paths (regression-tested); nothing is validated as
  profitable — no backtest has been run yet.

## [v0.5.0] — 2026-09-15 (M5)

### Added
- `StructureEngine.mqh`: confirmed-fractal swing detection (pivot known only
  after `pivot_confirm` closed bars past it — exact rule documented in the
  module header), two most recent swing highs/lows, HH/HL/LH/LL trend labels
  (BULLISH/BEARISH/MIXED/NEUTRAL), BOS via close beyond last swing with CHoCH
  when BOS runs against the prevailing swing trend, and approximate S/R zones
  (capped per side).
- SELF_TEST group T7 (pivot confirmation math).
- Config: `pivot_lookback`, `pivot_confirm`, `structure_max_zones` + EA inputs.

### Verified
- Compile: **0 errors, 0 warnings** (`reports/output/compile_m5.log`).

## [v0.4.0] — 2026-09-15 (M4)

### Added
- `RegimeEngine.mqh`: 8-regime classification with documented priority
  (volatility overrides → breakout → trend → range → unknown), ATR
  percentile via rank over a 200-bar window, breakout test against the
  prior 20-bar range with a 0.10·ATR buffer, and counted-evidence
  confidence (0–100 score, explicitly not a probability).
- Pure classifier `XareClassifyRegime` + SELF_TEST group T6 covering every
  regime branch.
- Config: `trend_adx_min`, `high/low_vol_atr_pct`, `breakout_range_lookback`,
  `regime_conf_min`; EA inputs exposed.

### Fixed
- `SXareRegime` lacked the `valid` flag its sibling structs had (compiler
  caught every use) — added for consistency.

### Verified
- Compile: **0 errors, 0 warnings** (`reports/output/compile_m4.log`).

## [v0.3.0] — 2026-09-15 (M3)

### Added
- `MultiTimeframe.mqh`: per-TF context (H4 macro, H1 intermediate) with two
  cached EMA handles each; objective label rule BULL/BEAR/NEUTRAL; alignment
  classifier producing BULLISH / BEARISH / MIXED / NEUTRAL with evidence
  string; execution-TF label derived from the shared EMA rule on the chart TF.
- SELF_TEST group T5: alignment classifier cases incl. mixed-information
  behavior (H4 bull + H1 bear + M15 bull ⇒ MIXED, never a forced side).

### Fixed
- Types.mqh ordering: `SXareMTF` was declared before its enum dependencies
  (caught by compiler as error 149/154) — declaration order matters in MQL5.
- `->` is not an MQL5 operator; object pointers use `.` (error 223/237).

### Verified
- Compile: **0 errors, 0 warnings** (`reports/output/compile_m3.log`).

## [v0.2.0] — 2026-09-15 (M2)

### Added
- `MarketData.mqh`: symbol property capture (all §6 fields, `valid` verdict),
  new-bar detection with duplicate-processing guard, closed-bar copy with
  hard `shift<1` refusal, staleness calc, live spread/quotes, tick-grid price
  normalization.
- `Indicators.mqh`: EMA 20/50/200 + RSI + ADX(+DI/−DI) + ATR via handles
  created once and released on deinit; manual ROC; `EMPTY_VALUE`/warm-up
  guards; copy-out APIs (MQL5 cannot return references).
- `Types.mqh`: `SXareBar`, `SXareSymbolProps`, `SXareFeatures`.
- `Config.mqh` + EA inputs: indicator periods, `history_bars_min`.
- EA: new-bar → closed-bar → features pipeline with DEBUG feature log;
  SELF_TEST extended (ROC math, tick-grid normalization).

### Fixed
- error 229 (`reference cannot be used`): replaced reference-returning getters
  with copy-out methods — an MQL5 semantic discovered by the real compiler.
- long→datetime conversion warning in `IsNewBar`.

### Verified
- Compile: **0 errors, 0 warnings** (`reports/output/compile_m2.log`).
- Python suite: 12 passed (incl. new closed-bar/new-bar guards).

## [v0.1.0] — 2026-09-15

### Added
- Repository structure (mql5 / python / tests / docs / experiments / reports / scripts)
- M0: architecture docs, experiment registry, license, gitignore
- M1: EA skeleton — `XARE.mq5` orchestration, `Types`, `Config`, `Logger`,
  `Diagnostics` dashboard, operating modes incl. SIGNAL_ONLY default
- M2: `MarketData` (new-bar detection, spread, symbol property normalization),
  `Indicators` (EMA20/50/200, RSI, ROC, ADX, ATR with handle caching)
- M3: multi-timeframe alignment classification
- M4: `RegimeEngine` — 8 regimes, confidence, evidence, volatility classification
- M5: `StructureEngine` — pivots, HH/HL/LH/LL, BOS/CHoCH, S/R zones
- M6: `SessionEngine` (broker-time sessions) + `LiquidityEngine` (PDH/PDL,
  session extremes, sweep detection)
- M7: `SignalEngine` — 6 setups with confidence, invalidation, evidence
- M8: `ScoreEngine` — 0–100 weighted score with component breakdown
- M9: `RiskEngine` — equity-based sizing, daily/weekly loss limits, drawdown
  states, consecutive-loss cooldown, overtrading caps, min-lot skip policy
- M10: `ExecutionEngine` — full pre-trade validation, order send, result/slippage record
- M11: `PositionManager` (state machine, one-position rule) + `ExitEngine`
  (BE, partial, trailing, time, regime-flip, reversal exits)
- M12: `SafetyEngine` (centralized GO/BLOCK with reasons) + `NewsFilter`
  (fail-safe, optional CSV feed)
- M13: research CSV feature logger + trade journal + `PerformanceTracker`
  (streaks, expectancy from closed trades only)
- M14: Python analytics — metrics, breakdowns, equity/drawdown plots
- M15–M18: walk-forward, Monte Carlo, parameter-stability, overfitting
  heuristics, research report generator
- Python test suite (unit / integration / regression)

### Fixed (M1 review pass)
- Compilation achieved for real: **0 errors, 0 warnings** via MetaEditor64 CLI
  (`/compile` + `/inc`), `.ex5` produced; compile log kept in `reports/output/`.
- `#property version` set to `1.00` (display-only): this compiler build rejects
  `0.x` majors with warning 68 regardless of format; authoritative version
  remains **v0.1.0** (changelog + git tag).
- Separated AutoTrading permission from demo-account checks in init validation.
- Removed MQL4-only `#property strict` (was present at creation, fixed in review).
- Logger `Init` no longer branches on an undefined error constant after
  `FolderCreate`; failure handling is delegated to the `FileOpen` verdict.
- Diagnostics bool conversions made explicit (no implicit long→bool ternaries).

### Notes
- No performance claims; nothing is validated until it passes the acceptance battery.
- M1 audit: no trade APIs present (`OrderSend`/`CTrade`/position-modify), symbol
  never hard-coded (`_Symbol` only) — both locked by regression tests.
