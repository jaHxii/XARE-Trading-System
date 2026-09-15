# XARE — Testing Documentation

Version: v0.1.0

## Test pyramid

1. **Python unit/integration/regression tests** (`tests/`) — run on every change:
   `python -m pytest tests -q` from the repo root.
2. **Real MQL5 compilation** via MetaEditor CLI (see below) — currently part of
   the automated review on the dev machine; log kept in `reports/output/`.
3. **MQL5 self-tests** (`RunSelfTest` in `XARE.mq5`, mode `SELF_TEST`) — run in
   the Strategy Tester; asserts core arithmetic (sizing, normalization, score
   math) on any symbol as engines are added.
4. **Strategy Tester** — full EA backtests (see protocol below).
5. **Manual compile gate** — MetaEditor F7, 0 errors / 0 warnings target.

## Compilation

Compilation is automated via the MetaEditor CLI when available (verified on the
development machine with MetaEditor64 at `C:\Program Files\MetaTrader 5`):

```bash
MetaEditor64.exe /compile:"<repo>\mql5\XARE.mq5" \
                  /inc:"<repo>\mql5\Include" \
                  /log:"<repo>\reports\output\compile_m1.log"
```

The log is UTF-16LE; the `Result:` line reports errors/warnings. Current gate:
**0 errors, 0 warnings** (M1). Notes:

- `#property version` must be `x.yy`; this compiler build rejects `0.x` majors
  with warning 68 (MQL5 Market rule), so the property is display-only and the
  authoritative semver lives in `docs/changelog.md` + git tags.
- On machines without MetaEditor, follow the manual steps below.

Manual steps (any machine with MT5):

1. MT5 → `File → Open Data Folder` → copy `mql5/Include/XARE/` → `MQL5/Include/`
2. Copy `mql5/XARE.mq5` → `MQL5/Experts/`
3. MetaEditor → open `XARE.mq5` → **F7**
4. Expect `0 errors, 0 warnings`. Report every warning; do not ignore warnings.
5. SELF_TEST mode may be run in the Strategy Tester on any symbol to verify
   runtime sanity without trading.

## Backtest protocol

- Data splits (adjust to actual data availability; register in the experiment registry):
  - development: 2022–2024 · validation: 2025 · untouched test: 2026
- Never optimize on validation/test. Optimization happens on development only.
- Multiple regimes required: trend periods, range periods, high-vol periods
  (2022–2023 gold provides both; 2024–2026 differs — verify with actual data).
- Realistic assumptions: variable spread (or fixed = typical XAUUSDm spread —
  measure it first), no "0 spread" runs counted as evidence, delay/slippage
  stress runs documented.
- Minimum sample gates: a result with < 100 trades per split is QUESTIONABLE
  by default regardless of profit.

## Walk-forward

Rolling windows (initial: 12m train / 3m test, step 3m — hypothesis). Record
every window independently; the report shows all windows including failures.
Collapse on any single window ⇒ not robust.

## Monte Carlo

On closed-trade R multiples and P/L: randomized order (shuffle), N=1000 runs.
Outputs: DD distribution, losing-streak distribution, risk-of-ruin estimate,
return distribution. Monte Carlo tests sensitivity to trade *order*, not future
profitability — it cannot prove an edge.

## Parameter stability

For every sensitive parameter: ±2 steps around the chosen value, one at a time.
A parameter whose neighbors collapse (PF swings > configured threshold) is
marked UNSTABLE. Stable regions, not points, are preferred.

## Robustness labels

`ROBUST / QUESTIONABLE / OVERFIT_RISK / FAIL` assigned by
`python/analysis/robustness.py` heuristics from: train-vs-validation gap,
parameter sensitivity, sample size, single-session/direction dependence,
unrealistic profit density, drawdown.

## Acceptance criteria (v1.0.0 candidate)

All must hold on untouched data:
- positive expectancy out-of-sample
- maxDD ≤ configured acceptance threshold
- trade count ≥ configured minimum
- stable across ≥ 3 splits and ≥ 2 sessions
- parameter neighborhoods do not collapse
- Monte Carlo risk-of-ruin ≤ threshold at configured risk settings
- no look-ahead, no missing hard SL, no unbounded risk (audited in code review)

Thresholds live in `python/config/acceptance.yaml` and are documented, not
vibes. Failure of any criterion ⇒ not a candidate; label FAIL and record.

## Stress tests

- Spread ×2 / ×3 of typical value
- Slippage +X points per fill
- Small accounts ($50/$100/$500/$1000) with min-lot skip behavior verified
- Data holes / missing bars (EA must degrade to UNKNOWN regime, not trade blind)
