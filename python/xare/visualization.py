"""M14: visualization (spec §38) — equity curve, drawdown, distributions.

All functions save PNG files under reports/output/ and return the path;
they never display interactive windows (headless-safe, Agg backend).
"""
from __future__ import annotations

from pathlib import Path

import matplotlib
matplotlib.use("Agg")           # headless: no display server assumed
import matplotlib.pyplot as plt  # noqa: E402
import pandas as pd              # noqa: E402


def _out(path: str) -> Path:
    p = Path(path)
    p.parent.mkdir(parents=True, exist_ok=True)
    return p


def equity_curve(journal_df: pd.DataFrame, out: str = "reports/output/equity_curve.png") -> str:
    """Cumulative net P/L over close order (§38)."""
    pl = journal_df.sort_values("close_time")["pl_money"].cumsum()
    fig, ax = plt.subplots(figsize=(10, 4))
    ax.plot(journal_df["close_time"].sort_values(), pl.values, lw=1.2)
    ax.set_title("XARE equity curve (cumulative net P/L)")
    ax.set_ylabel("money"); ax.grid(alpha=0.3)
    fig.tight_layout(); fig.savefig(_out(out), dpi=120); plt.close(fig)
    return out


def drawdown_curve(journal_df: pd.DataFrame, out: str = "reports/output/drawdown_curve.png") -> str:
    """Drawdown from running peak, in money (§38)."""
    pl = journal_df.sort_values("close_time")["pl_money"].cumsum()
    dd = pl - pl.cummax()
    t = journal_df["close_time"].sort_values()
    fig, ax = plt.subplots(figsize=(10, 3))
    ax.fill_between(t, dd.values, 0, color="tab:red", alpha=0.4)
    ax.set_title("Drawdown from peak (money)"); ax.grid(alpha=0.3)
    fig.tight_layout(); fig.savefig(_out(out), dpi=120); plt.close(fig)
    return out


def r_distribution(journal_df: pd.DataFrame, out: str = "reports/output/r_distribution.png") -> str:
    """Histogram of R multiples (trade quality shape)."""
    fig, ax = plt.subplots(figsize=(7, 4))
    ax.hist(journal_df["r_multiple"], bins=30, color="tab:blue", alpha=0.7)
    ax.axvline(0, color="k", lw=1)
    ax.set_title("R-multiple distribution"); ax.set_xlabel("R"); ax.grid(alpha=0.3)
    fig.tight_layout(); fig.savefig(_out(out), dpi=120); plt.close(fig)
    return out
