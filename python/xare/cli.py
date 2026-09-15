"""XARE CLI (M15 runner).

Examples:
    python -m xare.cli report --journal MQL5/Files/XARE/trade_journal.csv
    python -m xare.cli report                       # -> NOT EXECUTED report
    python -m xare.cli walk-forward --journal J.csv --train-months 12
    python -m xare.cli monte-carlo --journal J.csv --sims 5000

The CLI only ever reads real journals. With no journal it still produces
the report skeleton explicitly marked NOT EXECUTED (spec §60) so the
workflow is visible without fabricating any number.
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

import pandas as pd

from . import metrics, monte_carlo, report, walk_forward


def _load(args) -> pd.DataFrame | None:
    if not args.journal:
        return None
    p = Path(args.journal)
    if not p.is_file():
        print(f"journal not found: {p} — producing NOT EXECUTED report", file=sys.stderr)
        return None
    return metrics.load_journal(p)


def _cmd_report(args) -> int:
    df = _load(args)
    rep = report.build_report(
        df,
        title=args.title or "XARE Research Report",
        data_period=args.period or ("journal range" if df is not None else "not specified"),
        parameters=args.parameters or "defaults (docs/parameters.md)",
    )
    md = report.render(rep)
    out = Path(args.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(md, encoding="utf-8")
    print(md)
    return 0


def _cmd_walk_forward(args) -> int:
    df = _load(args)
    if df is None or len(df) == 0:
        print("walk-forward NOT RUN: no journal data supplied (framework ready)")
        return 0
    results = walk_forward.run_walk_forward(df, args.train_months, args.test_months,
                                            args.step_months)
    summary = walk_forward.summarize(results)
    print(json.dumps(summary, indent=2))
    for r in results:
        print(f"\nwindow {r['window']}: train {r['train_period']} | "
              f"test {r['test_period']} | OOS net {r['test']['net_profit']:.2f} "
              f"| flags: {r['flags'] or 'none'}")
    return 0


def _cmd_monte_carlo(args) -> int:
    df = _load(args)
    if df is None or len(df) < 2:
        print("monte-carlo NOT RUN: fewer than 2 trades supplied (framework ready)")
        return 0
    res = monte_carlo.run_monte_carlo(df["pl_money"], n_sims=args.sims,
                                      start_equity=args.start_equity,
                                      ruin_pct=args.ruin_pct, seed=args.seed)
    print(json.dumps(res, indent=2))
    return 0


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(prog="xare", description="XARE research analytics")
    sub = ap.add_subparsers(dest="cmd", required=True)

    def common(p):
        p.add_argument("--journal", help="path to trade_journal.csv (optional)")
        p.add_argument("--out", default="reports/output/xare_report.md")
        p.add_argument("--title", default=None)
        p.add_argument("--period", default=None)
        p.add_argument("--parameters", default=None)

    common(sub.add_parser("report", help="full §55 report (NOT EXECUTED without a journal)"))
    wf = sub.add_parser("walk-forward", help="M16 rolling windows")
    common(wf)
    wf.add_argument("--train-months", type=int, default=12)
    wf.add_argument("--test-months", type=int, default=3)
    wf.add_argument("--step-months", type=int, default=3)
    mc = sub.add_parser("monte-carlo", help="M17 resampling")
    common(mc)
    mc.add_argument("--sims", type=int, default=5000)
    mc.add_argument("--start-equity", type=float, default=10_000.0)
    mc.add_argument("--ruin-pct", type=float, default=20.0)
    mc.add_argument("--seed", type=int, default=42)
    args = ap.parse_args(argv)
    return {"report": _cmd_report,
            "walk-forward": _cmd_walk_forward,
            "monte-carlo": _cmd_monte_carlo}[args.cmd](args)


if __name__ == "__main__":
    raise SystemExit(main())
