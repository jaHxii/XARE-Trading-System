# Changelog

All notable changes to XARE. Format based on Keep a Changelog; versioning is
semantic (v0.x = research platform, v1.0.0 = production candidate, which
requires the full acceptance battery in `docs/testing.md`).

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
