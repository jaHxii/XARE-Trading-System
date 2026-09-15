# XARE — XAUUSD Adaptive Risk Engine

Research-grade gold (XAUUSD) trading system: a native MetaTrader 5 Expert
Advisor (MQL5) plus a Python research stack. Primary symbol is the broker's
gold symbol (initially Exness `XAUUSDm`); primary execution timeframe is M15
with M5/H1/H4 as context.

> **Status: research platform under construction (v0.1.0).**
> XARE has **no proven edge yet**. Nothing here claims profitability. The
> purpose of this repository is to build a defensible process for finding out
> whether an edge exists — out-of-sample, walk-forward, parameter-stability,
> and Monte Carlo tests must pass before any live deployment.

## Philosophy

Layered, independently testable modules; every trade has a reason, a score,
and an exit reason; every risk decision is logged. Risk is controlled by
**stop distance and account equity**, never by lot size alone. One position
per symbol. Hard SL on every trade. No martingale. No uncontrolled grid.
Research logic is separated from execution logic.

## Layers

DATA → FEATURES → REGIME → STRUCTURE → SIGNALS → SCORING → RISK → EXECUTION →
POSITION MANAGEMENT → EXIT → SAFETY → LOGGING → REPORTING

See `docs/architecture.md` for the module map and `docs/strategy.md` for how
signals are built from regime + structure + liquidity + session context.

## Operating modes

| Mode | Behavior |
|---|---|
| RESEARCH | Logs features to CSV; never trades |
| SIGNAL_ONLY | Reports entries/SL/TP/score; never places orders |
| BACKTEST | Full pipeline inside MT5 Strategy Tester |
| DEMO | Full pipeline on a demo account (default) |
| PRODUCTION | Full pipeline on live account (requires explicit enable) |

Defaults are conservative: SIGNAL_ONLY, one position per symbol, hard SL,
daily-loss and drawdown protection on, spread filter on.

## Repository layout

```
XARE/
├── mql5/                  # Expert Advisor + Include/XARE/*.mqh modules
├── python/                # research, analytics, optimization, WF, Monte Carlo, reports
├── tests/                 # pytest suite (unit / integration / regression)
├── docs/                  # architecture, strategy, risk, testing, parameters, changelog
├── experiments/           # experiment registry (every run gets a row)
├── reports/               # generated research reports
└── scripts/               # utility scripts (mt5 export, sanity checks)
```

## Installation

### Python tooling

```bash
cd python
pip install -r requirements.txt
python -m pytest ../tests --rootdir=.. -q   # run the test suite
```

### MQL5 compilation (manual — MetaEditor required)

MetaEditor cannot be invoked from this environment, so compilation is a manual
step (verified limitation, see `docs/testing.md`):

1. Open MetaTrader 5 → `File → Open Data Folder`
2. Copy `mql5/Include/XARE` into `MQL5/Include/`
3. Copy `mql5/XARE.mq5` into `MQL5/Experts/`
4. Open `XARE.mq5` in MetaEditor, press **F7**
5. Target: `0 errors, 0 warnings`; report any issue as a bug (do not hand-patch
   the compiled product)

## Quick start (signal-only validation)

1. Compile and attach the EA to an XAUUSD M15 chart
2. Leave `InpMode = SIGNAL_ONLY` (default)
3. Watch the dashboard + Journal; confirm entries/SL/TP look sane for ≥ 1 week
4. Only then consider DEMO mode; PRODUCTION requires explicit enable

## Risk controls (summary)

- Position size from equity × risk% ÷ stop distance; never fixed lots
- Hard SL every trade; SL never widened; never moved beyond entry after BE
- Daily loss limit, weekly loss limit, max drawdown states, consecutive-loss
  cooldown, overtrading caps, spread filter, session/volatility gates
- Emergency stop on data corruption, execution failures, or limit breach

Full details: `docs/risk.md`. Parameter reference: `docs/parameters.md`.

## Limitations

- Requires real MT5 symbol/broker data; nothing is hard-coded to Exness specs
- News filter fails safe (blocks nothing it cannot verify; only acts on data
  actually provided)
- All thresholds are initial hypotheses pending validation — they are
  configurable, documented, and must pass the acceptance criteria in
  `docs/testing.md`
