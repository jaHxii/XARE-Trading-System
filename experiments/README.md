# XARE Experiment Registry

Every backtest, optimization, walk-forward run, or Monte Carlo batch **must**
get a row in `experiment_registry.csv`. If a result is not registered, it does
not exist as far as this project is concerned.

## Rules

1. Register the experiment **before** analyzing results (fill in what you know; update after the run).
2. `code_version` = git commit hash of `mql5/` + `python/` at run time.
3. `param_version` = name of the `.set` file or config JSON used (see `docs/parameters.md`).
4. `robustness_label` ∈ {ROBUST, QUESTIONABLE, OVERFIT_RISK, FAIL} — assigned by the
   overfitting heuristics in `python/analysis/robustness.py`, never by eye alone.
5. Never delete rows. A failed experiment is still an experiment; it protects
   future-you from re-running it.

## Column reference

| Column | Meaning |
|---|---|
| experiment_id | Short stable id, e.g. `EXP-0001` |
| date | UTC date of the run |
| code_version | git hash or tag (e.g. `v0.3.0+g1a2b3c`) |
| param_version | `.set`/config name, e.g. `defaults_v1` |
| symbol | Broker symbol tested (e.g. `XAUUSDm`) |
| timeframe | Primary TF, always `M15` for execution |
| date_range | e.g. `2022-01..2024-12` |
| initial_balance | Deposited balance for the run |
| spread_assumptions | `fixed:<points>` / `variable_m1` / `raw_ticks` |
| result_summary | One line: net, PF, maxDD, trades |
| robustness_label | ROBUST / QUESTIONABLE / OVERFIT_RISK / FAIL |
| notes | Anything a future reader needs: deviations, surprises, bugs found |
