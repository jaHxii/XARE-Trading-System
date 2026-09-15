"""M18: parameter stability analysis (spec §42).

A robust strategy must not collapse when one parameter moves by one unit.
The evaluator receives a FUNCTION that maps a parameter dict to a metrics
dict (e.g. re-running a backtest), so this module makes no assumptions
about how parameters are applied. It perturbs each parameter +/-delta and
measures the degradation spread.

Outputs a per-parameter sensitivity table and an overall plateau verdict:
stable regions (plateaus), not magical single values, are the goal.
"""
from __future__ import annotations

import numpy as np

from . import warnings as xw


def _flatten(metrics: dict) -> dict:
    return {k: float(metrics.get(k, 0.0) or 0.0)
            for k in ("net_profit", "profit_factor", "expected_payoff",
                      "max_drawdown_pct", "win_rate")}


def sensitivity(evaluate,
                base_params: dict,
                deltas: dict[str, list] | None = None,
                min_trades: int = xw.MIN_TRADES_HARD) -> dict:
    """Evaluate neighbor parameter sets.

    evaluate: callable(dict) -> metrics dict (as from metrics.compute_metrics)
    base_params: {"ema_fast": 20, ...}
    deltas: {"ema_fast": [18, 19, 21, 22], ...} — explicit neighbor values;
            when omitted, +/-1 and +/-2 are used for int/float params.
    """
    deltas = deltas or {}
    base = evaluate(dict(base_params))
    bm = _flatten(base)
    rows = []
    for name, value in base_params.items():
        neighbors = deltas.get(name, [value - 2, value - 1, value + 1, value + 2])
        for nv in neighbors:
            if nv == value:
                continue
            p = dict(base_params)
            p[name] = nv
            m = _flatten(evaluate(p))
            pf_drop = (bm["profit_factor"] - m["profit_factor"])
            rows.append({
                "parameter": name, "base": value, "neighbor": nv,
                "net_profit": m["net_profit"],
                "profit_factor": m["profit_factor"],
                "pf_drop_vs_base": round(pf_drop, 4),
                "max_dd_pct": m["max_drawdown_pct"],
                "trades": int(m.get("trade_count", 0)),
            })
    ok = bool(base.get("ready")) and base.get("trade_count", 0) >= min_trades
    return {
        "ready": ok,
        "base": bm,
        "base_trades": int(base.get("trade_count", 0)),
        "neighbors": rows,
        "note": ("ready=False means the base run had too few trades or no "
                 "data — sensitivity labels would be meaningless"),
    }


def plateau_verdict(sens: dict,
                    pf_collapse_drop: float = 0.5,
                    min_profitable_frac: float = 0.6) -> str:
    """Classify the neighborhood (§42/§44 spirit):
    ROBUST / QUESTIONABLE / OVERFIT_RISK / NOT EVALUATED."""
    if not sens.get("ready"):
        return "NOT EVALUATED"
    rows = sens["neighbors"]
    if not rows:
        return "QUESTIONABLE"     # no neighbors evaluated: cannot claim stability
    pf_base = sens["base"]["profit_factor"]
    collapses = [r for r in rows
                 if pf_base > 0 and r["pf_drop_vs_base"] / pf_base > pf_collapse_drop]
    profitable = [r for r in rows if r["net_profit"] > 0]
    if len(collapses) > len(rows) * (1.0 - min_profitable_frac):
        return "OVERFIT_RISK"     # most neighbors collapse: knife-edge optimum
    if len(profitable) / len(rows) >= min_profitable_frac and not collapses:
        return "ROBUST"
    return "QUESTIONABLE"
