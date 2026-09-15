"""M16: walk-forward analysis (spec §41).

Rolling TRAIN -> TEST windows over a time-ordered journal. Every window is
reported independently — bad windows are never hidden (§41). Window
boundaries are passed explicitly by the caller (configurable, not magic).
"""
from __future__ import annotations

import pandas as pd

from . import metrics, warnings as xw


def run_walk_forward(df: pd.DataFrame,
                     train_months: int = 12,
                     test_months: int = 3,
                     step_months: int = 3) -> list[dict]:
    """Anchored/rolling walk-forward windows.

    Window w covers [start, start+train) for training and
    [start+train, start+train+test) for testing, advancing by step_months.
    Windows with zero trades in either half are recorded as NOT EVALUATED
    (still reported — nothing hidden).
    """
    if df is None or len(df) == 0:
        return []
    start = df["close_time"].min()
    end = df["close_time"].max()
    results: list[dict] = []
    idx = 0
    cur = pd.Timestamp(start)

    while True:
        tr_end = cur + pd.DateOffset(months=train_months)
        te_end = tr_end + pd.DateOffset(months=test_months)
        if tr_end > end and te_end > end:
            break
        tr = df[(df["close_time"] >= cur) & (df["close_time"] < tr_end)]
        te = df[(df["close_time"] >= tr_end) & (df["close_time"] < te_end)]
        trm = metrics.compute_metrics(tr)
        tem = metrics.compute_metrics(te)
        win = {
            "window": idx,
            "train_period": f"{cur.date()} .. {min(tr_end, end).date()}",
            "test_period": f"{tr_end.date()} .. {min(te_end, end).date()}",
            "train": trm,
            "test": tem,
            "oos_positive": bool(tem["ready"] and tem["net_profit"] > 0),
        }
        win["flags"] = (xw.sample_size_warnings(tem["trade_count"]) +
                        xw.overfit_warnings(trm, tem))
        results.append(win)
        idx += 1
        cur += pd.DateOffset(months=step_months)
        if cur >= end:
            break
    return results


def summarize(results: list[dict]) -> dict:
    """Aggregate walk-forward summary. None of it hides failing windows:
    the count of negative OOS windows is explicit."""
    if not results:
        return {"ready": False,
                "note": "walk-forward not run — no data (framework only)"}
    te = [r["test"] for r in results]
    oos_pos = sum(1 for t in te if t["ready"] and t["net_profit"] > 0)
    evaluated = [t for t in te if t["ready"]]
    return {
        "ready": True,
        "windows": len(results),
        "windows_evaluated": len(evaluated),
        "oos_positive_windows": oos_pos,
        "oos_negative_windows": sum(1 for t in evaluated if t["net_profit"] <= 0),
        "oos_win_rate_pct": round(100.0 * oos_pos / len(evaluated), 1) if evaluated else 0.0,
        "avg_oos_expectancy": (sum(t["expected_payoff"] for t in evaluated) / len(evaluated)
                               if evaluated else 0.0),
        "windows_flagged": sum(1 for r in results if r["flags"]),
    }
