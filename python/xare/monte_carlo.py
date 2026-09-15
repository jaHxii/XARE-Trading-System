"""M17: Monte Carlo analysis on trade results (spec §43).

Resamples the observed trade P/L series (shuffle with replacement=OFF for
order randomization; bootstrap WITH replacement for drawdown robustness —
both are reported). Estimates drawdown distribution, losing-streak
distribution, risk-of-ruin style breach probability, and return spread.

This tests robustness under MODELED randomness only. It does NOT prove
future profitability (§43) — every output is a statement about the
supplied trade sample, and the header of any rendered report says so.
"""
from __future__ import annotations

import numpy as np


def run_monte_carlo(pl_series,
                    n_sims: int = 5000,
                    start_equity: float = 10_000.0,
                    ruin_pct: float = 20.0,
                    seed: int = 42) -> dict:
    """Simulate `n_sims` reorderings/bootstrap paths of the trade series.

    Returns percentiles of max drawdown, worst losing streak, terminal
    return, and the probability of breaching the ruin threshold.
    """
    pl = np.asarray(list(pl_series), dtype=float)
    out = {
        "ready": False,
        "n_sims": 0,
        "note": ("Monte Carlo reorders/bootstrap-resamples the SUPPLIED trades; "
                 "it models randomness, it does not validate an edge (§43)."),
    }
    if len(pl) < 2:
        out["note"] = "insufficient trades (<2) — Monte Carlo not run"
        return out

    rng = np.random.default_rng(seed)
    n = len(pl)
    mdd_pct = np.empty(n_sims)
    worst_streak = np.empty(n_sims, dtype=int)
    terminal_ret = np.empty(n_sims)

    for i in range(n_sims):
        # alternate between order shuffle (no replacement) and bootstrap
        path = rng.permutation(pl) if i % 2 == 0 else rng.choice(pl, size=n, replace=True)
        eq = start_equity + np.cumsum(path)
        peak = np.maximum.accumulate(eq)
        dd = (peak - eq) / peak * 100.0
        mdd_pct[i] = dd.max()
        losses = path < 0
        # longest run of consecutive losses in this path
        best = cur = 0
        for v in losses:
            cur = cur + 1 if v else 0
            best = max(best, cur)
        worst_streak[i] = best
        terminal_ret[i] = (eq[-1] / start_equity - 1.0) * 100.0

    def pct(arr, q):
        return float(np.percentile(arr, q))

    breach = float((mdd_pct >= ruin_pct).mean() * 100.0)
    out.update({
        "ready": True,
        "n_sims": n_sims,
        "n_trades": n,
        "start_equity": start_equity,
        "ruin_pct": ruin_pct,
        "seed": seed,
        "max_dd_pct_p50": pct(mdd_pct, 50), "max_dd_pct_p90": pct(mdd_pct, 90),
        "max_dd_pct_p99": pct(mdd_pct, 99),
        "worst_losing_streak_p50": int(np.percentile(worst_streak, 50)),
        "worst_losing_streak_p99": int(np.percentile(worst_streak, 99)),
        "terminal_return_p05": pct(terminal_ret, 5),
        "terminal_return_p50": pct(terminal_ret, 50),
        "terminal_return_p95": pct(terminal_ret, 95),
        "prob_dd_breach_pct": round(breach, 2),
    })
    return out
