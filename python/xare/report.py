"""M15: report assembly (spec §55).

`build_report()` produces the complete research report dict; `render()`
writes it as Markdown. If no trade data is supplied, the report is
explicitly marked NOT EXECUTED — the framework never fabricates results
(spec §60).
"""
from __future__ import annotations

import datetime as _dt

import pandas as pd

from . import metrics, warnings as xw

REQUIRED_SECTIONS = (
    "profit", "profit_factor", "expected_payoff", "drawdown", "drawdown_pct",
    "recovery_factor", "sharpe", "sortino", "win_rate", "trade_count",
    "largest_loss", "largest_win", "consecutive_losses",
    "regime_performance", "session_performance", "setup_performance",
)


def build_report(journal_df: pd.DataFrame | None,
                 title: str = "XARE Research Report",
                 data_period: str = "not specified",
                 parameters: str = "defaults (docs/parameters.md)",
                 notes: str = "") -> dict:
    """Assemble the full report. journal_df=None -> NOT EXECUTED report."""
    rep: dict = {
        "title": title,
        "generated_utc": _dt.datetime.now(_dt.timezone.utc).isoformat(timespec="seconds"),
        "data_period": data_period,
        "parameters": parameters,
        "notes": notes,
        "executed": journal_df is not None and len(journal_df) > 0,
    }

    if not rep["executed"]:
        rep["status"] = "NOT EXECUTED"
        rep["status_note"] = (
            "No backtest has been run and no trade journal exists yet. "
            "These fields describe the framework, not any measured result — "
            "no performance is claimed (spec §60)."
        )
        rep["metrics"] = metrics.compute_metrics(pd.DataFrame())
        rep["regime_performance"] = None
        rep["session_performance"] = None
        rep["setup_performance"] = None
        rep["warnings"] = ["NOT EXECUTED: no real test data was supplied"]
        rep["classification"] = "NOT EXECUTED"
        return rep

    rep["status"] = "EXECUTED"
    m = metrics.compute_metrics(journal_df)
    rep["metrics"] = m
    rep["regime_performance"] = (
        metrics.breakdown(journal_df, "regime") if "regime" in journal_df.columns else None)
    rep["session_performance"] = (
        metrics.breakdown(journal_df, "session") if "session" in journal_df.columns else None)
    rep["setup_performance"] = (
        metrics.breakdown(journal_df, "setup") if "setup" in journal_df.columns else None)

    warns = (xw.sample_size_warnings(m["trade_count"]) +
             xw.drawdown_warnings(m) +
             xw.concentration_warnings(rep["regime_performance"]))
    rep["warnings"] = warns
    rep["classification"] = xw.classify(m, m)  # single-period report: no OOS split yet
    return rep


def render(rep: dict) -> str:
    """Markdown rendering of a report dict from build_report()."""
    lines: list[str] = [f"# {rep['title']}", "",
                        f"- Generated: {rep['generated_utc']}",
                        f"- Data period: {rep['data_period']}",
                        f"- Parameters: {rep['parameters']}",
                        f"- Status: **{rep['status']}**", ""]
    if not rep["executed"]:
        lines += [f"> {rep['status_note']}", ""]
    m = rep["metrics"]
    lines += [
        "## Headline metrics", "",
        f"| Metric | Value |", f"|---|---|",
        f"| Net profit | {m['net_profit']:.2f} |",
        f"| Profit factor | {m['profit_factor']:.2f} |",
        f"| Expected payoff | {m['expected_payoff']:.2f} |",
        f"| Max drawdown | {m['max_drawdown']:.2f} |",
        f"| Max drawdown % | {m['max_drawdown_pct']:.2f}% |",
        f"| Recovery factor | {m['recovery_factor']:.2f} |",
        f"| Sharpe (per-trade, annualized proxy) | {m['sharpe']:.2f} |",
        f"| Sortino | {m['sortino']:.2f} |",
        f"| Win rate | {m['win_rate']:.1f}% |",
        f"| Trade count | {m['trade_count']} |",
        f"| Largest win | {m['largest_win']:.2f} |",
        f"| Largest loss | {m['largest_loss']:.2f} |",
        f"| Max consecutive losses | {m['max_consecutive_losses']} |",
        f"| Max consecutive wins | {m['max_consecutive_wins']} |",
        "",
    ]
    for key, label in (("regime_performance", "By regime"),
                       ("session_performance", "By session"),
                       ("setup_performance", "By setup")):
        t = rep.get(key)
        if t is not None and len(t):
            lines += [f"## {label}", "", t.to_markdown(), ""]
    if rep.get("warnings"):
        lines += ["## Warnings", ""]
        lines += [f"- {w}" for w in rep["warnings"]]
        lines.append("")
    lines += [f"## Classification: **{rep.get('classification', 'N/A')}**", "",
              "_Research label only — not a guarantee of future behavior (§44)._"]
    return "\n".join(lines)
