# XARE — Parameter Reference

Version: v0.1.0. All defaults are **initial hypotheses**, chosen to be sensible
and explainable, not optimized. Change them only with an experiment row.

EA inputs are prefixed `Inp` and mirror these groups. One source of truth in
code: `mql5/Include/XARE/Config.mqh`.

## General

| Parameter | Default | Notes |
|---|---|---|
| Mode | SIGNAL_ONLY | RESEARCH / SIGNAL_ONLY / BACKTEST / DEMO / PRODUCTION / SELF_TEST |
| TradingEnabled | false | global risk switch (must be true for DEMO/PRODUCTION to trade) |
| MagicNumber | 860001 | identifies XARE positions/orders |
| Comment | "XARE" | order comment |
| DashboardEnabled | true | chart panel (SIGNAL_ONLY/DEMO/PRODUCTION) |

## Market Data

| Parameter | Default | Notes |
|---|---|---|
| UseClosedBarsOnly | true | no intrabar signal decisions |
| MaxSpreadPoints | 350 | block entries above (XAUUSDm typical ≈ 100–200pt; measure!) |
| AbnormalSpreadPoints | 600 | abnormal condition gate |
| MaxBarsWithoutData | 3 | degrade to UNSAFE if history is stale |

## Indicators

EMA 20/50/200 · RSI 14 · ROC 10 · ADX 14 · ATR 14 · ATR percentile window 200
(periods configurable; no separate inputs in v0.1 to limit search space).

## Regime

| Parameter | Default | Notes |
|---|---|---|
| TrendADXMin | 22 | ADX above ⇒ trend-capable |
| HighVolATRPct | 80 | ATR percentile above ⇒ HIGH_VOLATILITY |
| LowVolATRPct | 20 | below ⇒ LOW_VOLATILITY |
| BreakoutRangeLookback | 20 | bars defining the pre-breakout range |
| ConfidenceMin | 55 | below ⇒ UNKNOWN treated as no-trend |

## Structure

| Parameter | Default | Notes |
|---|---|---|
| PivotLookback | 3 | bars each side of a pivot |
| PivotConfirmBars | 2 | bars after pivot before it counts (anti-look-ahead) |
| MaxZonesPerSide | 4 | S/R zones kept per side |

## Liquidity

| Parameter | Default | Notes |
|---|---|---|
| SweepATRMultiple | 0.25 | penetration depth ≥ this ⇒ sweep candidate |
| SweepReclaimBars | 3 | close back within N bars ⇒ sweep confirmed |
| SwingLiquidityLookback | 40 | bars scanned for recent swing extremes |

## Sessions (broker server time, minutes from midnight)

Asian 0:00–8:00 · London 7:00–16:00 · NewYork 12:30–21:00 · Overlap 12:30–16:00.
Verify broker offset with `scripts/check_broker_time.py` before trusting.

## Signals

| Parameter | Default | Notes |
|---|---|---|
| EnabledSetups | all 6 | bitmask |
| PullbackEMAZone | 1.2 | ATR distance multiplier for EMA20/50 zone |
| BreakoutBufferATR | 0.10 | close beyond range edge by ≥ this |
| MinRegimeConfidence | 55 | setups require this regime confidence |
| MinSetupConfidence | 55 | setup-level floor |

## Scoring

Weights (sum 100): trend 20 · MTF 15 · structure 15 · momentum 10 ·
liquidity 15 · volatility 10 · session 5 · setup 10.
Thresholds: MinScore 60 · CandidateScore 70 · StrongScore 80.

## Risk

| Parameter | Default | Notes |
|---|---|---|
| RiskPercent | 0.5 | % equity per trade |
| AllowMinLotOverride | false | high-risk override; default SKIP |
| MaxDailyLossPct | 3.0 | realized+floating |
| CloseOnDailyBreach | false | flatten on daily breach (off by default) |
| MaxWeeklyLossPct | 6.0 | |
| MaxTotalDDPct | 20.0 | HALTED latch |
| CautionDDPct | 10.0 | CAUTION from |
| ReducedRiskDDPct | 15.0 | REDUCED_RISK from (risk × ReducedRiskFactor) |
| ReducedRiskFactor | 0.5 | |
| MaxConsecutiveLosses | 3 | cooldown trigger |
| CooldownHours | 4 | pause after streak |
| StreakRiskFactor | 0.5 | bounded risk reduction after streak (≤1 enforced) |
| MaxTradesPerDay | 5 | |
| MaxTradesPerSession | 2 | |
| MinMinutesBetweenTrades | 60 | |
| MaxLotHardCap | 0.50 | emergency max regardless of calc |

## Position Management / Exits

| Parameter | Default | Notes |
|---|---|---|
| SLMode | HYBRID | ATR / STRUCTURE / HYBRID |
| SLLowATR | 1.5 | ATR multiplier floor for SL |
| TPMode | R_MULTIPLE | R_MULTIPLE / ATR / STRUCTURE (v0.1: R_MULTIPLE) |
| TPMultipleR | 2.0 | |
| BreakEvenAtR | 1.0 | 0 disables |
| BreakEvenLockPoints | 20 | locked profit after BE |
| PartialAtR | 0 disables partial — use 1.5 to enable; PartialFraction 0.3 | |
| TrailStartR | 1.5 | 0 disables |
| TrailATRMultiple | 2.0 | |
| MaxBarsInTrade | 96 | 96 × M15 = 24h |
| MaxHoursInTrade | 30 | |
| TimeExitMinR | 0.2 | exit if below this R at time limit |
| RegimeFlipExit | true | strong opposed regime ⇒ exit |
| ReversalExitScore | 75 | opposite setup score to trigger reversal exit |

## Safety / News

| Parameter | Default | Notes |
|---|---|---|
| NewsFilterEnabled | false | requires a CSV feed; fails safe when absent |
| NewsBlackoutBeforeMin | 30 | |
| NewsBlackoutAfterMin | 30 | |
| EmergencyStopOnFailures | 3 | repeated execution failures ⇒ stop |
| NewsUseCalendar | true | MT5 Economic Calendar (HIGH, USD/XAU); CSV fallback; fail-safe clear on failure |

## Hardening v0.17 (all defaults OFF or risk-reducing; HYPOTHESES)

| Parameter | Default | Notes |
|---|---|---|
| FactorMin | 0.5 | adaptive-risk hard lower bound per factor (§6) |
| MaxConsecLosingDays | 2 | consecutive losing days ⇒ DEFENSIVE (0=off) (§10) |
| MinMarginLevel | 200% | margin-level floor ⇒ DEFENSIVE (0=off) (§10) |
| ProfitLockEnabled | **false** | UNVALIDATED capital floor (§9) — do not enable before walk-forward evidence |
| LockMilestonePct | 10 | equity gain% that arms a floor |
| LockFloorPct | 50 | protected % of the gain |
| StagesEnabled | true | capital-stage research labels (§8); risk factor reduce-only |
| StageBoundaries | 500 / 5000 / 50000 | MICRO/GROWTH/STANDARD/SCALE equity bounds |
| FridayCutoffMin | 1200 | 20:00 server: last entry START (§15) |
| FridayCloseAll | **false** | optional close-all at cutoff |
| PostSLCooldown | 4 bars | pause after any SL loser (§12) |
| SlipCooldownPoints | 150 | abnormal slippage trigger (§12) |
| SlipCooldownBars | 4 | pause length after abnormal slippage |
| MaxTradesPerSession | 2 | per-session cap (0=off) (§12) |
| BreakoutBodyMinPct | 50 | breakout candle body ≥ % of range (§2) |
| BreakoutStrongATR | 0.5 | STRONG band threshold in ATR beyond level (§2) |
| HealthCheckEnabled | true | BLOCKED verdict blocks sends (§21) |

Breakout strength bands (§2, hypotheses): WEAK < 0.25 ATR ≤ NORMAL < strong_atr ≤ STRONG.
Confidence bumps: band +0/+10/+15, body +5, DI-momentum +5, tick-activity +5 (max 80+20).

## Logging / Research

| Parameter | Default | Notes |
|---|---|---|
| LogLevel | INFO | DEBUG / INFO / WARN / ERROR |
| ResearchCSVEnabled | true in RESEARCH mode | per-bar feature rows |
| JournalCSVEnabled | true | trade journal |
| JournalDir | MQL5\Files\XARE | also holds state.json (§20 persistence) |

## Session-specific and future knobs

See `docs/testing.md` for acceptance thresholds and
`python/config/acceptance.yaml` for research gates.
Stress-scenario parameters (§18) live in `python/xare/stress.py`:
spread ×1.5/×2, slippage 5%/10% of R per side.
