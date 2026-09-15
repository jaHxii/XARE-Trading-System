# XARE — Architecture

Version: v0.1.0 · Last updated: 2026-09-15

## Design principles

1. **Layered** — each layer consumes only the outputs of lower layers.
2. **Independently testable** — every module compiles and can be exercised alone.
3. **Explainable** — every decision (trade, skip, block, exit) carries a reason string.
4. **Configurable** — no magic numbers in module code; all tunables live in `Config`.
5. **Safe by default** — ambiguous state ⇒ do nothing and say why.

## Module map (`mql5/Include/XARE/`)

| Module | Responsibility | Consumes | Produces |
|---|---|---|---|
| `Types.mqh` | All enums/structs shared across layers | — | vocabulary |
| `Config.mqh` | All parameters, grouped; loaded from inputs | — | configuration |
| `Logger.mqh` | Structured journal + CSV trade journal | everything | logs |
| `MarketData.mqh` | Bar/tick access, new-bar detection, spread, symbol props | terminal | OHLCV, spread, props |
| `Indicators.mqh` | EMA20/50/200, RSI, ROC, ADX, ATR handles + cached reads | MarketData | feature values |
| `RegimeEngine.mqh` | Regime classification + confidence + evidence (incl. volatility classes) | Indicators, MarketData | regime verdict |
| `StructureEngine.mqh` | Swings, HH/HL/LH/LL, BOS/CHoCH, S/R zones | MarketData | structure verdict |
| `LiquidityEngine.mqh` | PDH/PDL, session H/L, sweep/false-break detection | MarketData, SessionEngine | liquidity state |
| `SessionEngine.mqh` | Asian/London/NY/overlap windows in broker time | MarketData | session verdict |
| `SignalEngine.mqh` | 6 setup detectors; returns setup or NO_TRADE | Regime, Structure, Liquidity, Session | candidate setups |
| `ScoreEngine.mqh` | 0–100 weighted score + component breakdown | all above | score + evidence |
| `RiskEngine.mqh` | Sizing, exposure caps, loss limits, drawdown states, streaks | Config, account, journal | permission + volume |
| `ExecutionEngine.mqh` | Pre-trade validation, order send, fill/slippage record | RiskEngine | tickets/results |
| `PositionManager.mqh` | Position state machine, one-position rule, management steps | Execution, Indicators | state transitions |
| `ExitEngine.mqh` | BE / partial / trailing / time / regime / reversal exits | PositionManager, Indicators | exit decisions |
| `SafetyEngine.mqh` | Centralized blocking of trades with reasons | everything | GO / BLOCK(reason) |
| `NewsFilter.mqh` | Optional news blackout; fails safe without data | file/API feed if present | clearance |
| `PerformanceTracker.mqh` | Win/loss stats, streaks, expectancy (closed trades) | journal | statistics |
| `Diagnostics.mqh` | Chart dashboard (optional) | everything | panel |
| `XARE.mq5` | OnInit/OnTick orchestration only | all modules | EA behavior |

## Data flow (one M15 bar close)

```
OnTick ──► MarketData.OnTick (new bar?)
             └─► Indicators.Refresh(closed bars only)
                   └─► RegimeEngine.Evaluate
                         └─► StructureEngine.Update
                               └─► SessionEngine.Update ─► LiquidityEngine.Update
                                     └─► SignalEngine.Evaluate (if flat)
                                           └─► ScoreEngine.Score
                                                 └─► SafetyEngine.CanTrade
                                                       └─► RiskEngine.Evaluate (risk state, caps, size)
                                                             └─► ExecutionEngine.TryOpen
                                                                   └─► PositionManager (state machine)
                                                         (if in position)
                                                           └─► ExitEngine.Manage ─► PositionManager
```

Execution logic never calls signal logic; signals never place orders. The only
bridge is the explicit decision object passed down the chain.

## Look-ahead discipline

- Signals evaluate **closed bars only** (shift ≥ 1) unless a module documents an
  explicit intrabar need (none in v0.1).
- Swing confirmation: a pivot at bar `i` is confirmed only when `InpPivotConfirm`
  bars have closed after it; until then it is not a swing.
- Daily/session boundaries use **broker server time**, never local time.
- The expectancy filter uses only closed-trade history accumulated by this EA.

## Multi-timeframe policy

H4 = macro direction, H1 = intermediate trend, M15 = setup/execution, M5 =
optional refinement. Alignment is classified (BULL/BEAR/MIXED/NEUTRAL); mixed
alignment suppresses trend setups rather than forcing a trade.

## Risk state machine

NORMAL → CAUTION → REDUCED_RISK → HALTED (see `docs/risk.md` for thresholds).
HALTED requires manual EA re-init to clear (safety latch).

## Failure policy

Any invalid market data, execution error, or safety breach moves the EA toward
"do nothing" — never toward "force a trade". Repeated execution failures trip
the emergency stop.

## Future interfaces (not implemented in v0.1)

- ML adapter: a model may later supply `signal probability`, `regime label`,
  `trade quality` — consumed as extra ScoreEngine evidence, never as bypass.
- Adaptive engine: regime-specific parameter sets selected from a **static**
  library; the EA never rewrites its own parameters/source.
