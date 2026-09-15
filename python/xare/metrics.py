"""Core performance metrics (spec §39).

Every function is pure and operates on a trade journal DataFrame with the
columns written by CXareLogger (M1) / journal CSV:

    close_time, ticket, symbol, direction, setup, regime, score,
    risk_pct, volume, entry, sl, tp, exit_price, exit_reason, session,
    pl_money, r_multiple, bars_in_trade, slippage_points, open_reason

No metric here is a prediction. They describe the supplied trades only.
"""
from __future__ import annotations

import numpy as np
import pandas as pd

REQUIRED_COLUMNS = (
    "close_time", "ticket", "direction", "setup", "regime", "score",
    "volume", "entry", "sl", "tp", "exit_price", "exit_reason", "session",
    "pl_money", "r_multiple", "bars_in_trade", "open_reason",
)

RISK_FREE_ANNUAL = 0.0   # configurable hypothesis; documented, not assumed


def load_journal(path) -> pd.DataFrame:
    """Load and clean a XARE trade journal CSV (§38 cleaning)."""
    df = pd.read_csv(path)
    df.columns = [c.strip() for c in df.columns]
    missing = [c for c in ("close_time", "pl_money", "r_multiple") if c not in df.columns]
    if missing:
        raise ValueError(f"journal missing required columns: {missing}")
    df["close_time"] = pd.to_datetime(df["close_time"], errors="coerce")
    for col in ("pl_money", "r_multiple", "score", "risk_pct", "bars_in_trade"):
        if col in df.columns:
            df[col] = pd.to_numeric(df[col], errors="coerce")
    df = df.dropna(subset=["close_time"]).sort_values("close_time").reset_index(drop=True)
    return df


def _max_consecutive(mask: pd.Series) -> int:
    """Longest run of True in a boolean series."""
    best = cur = 0
    for v in mask:
        cur = cur + 1 if v else 0
        best = max(best, cur)
    return best


def compute_metrics(df: pd.DataFrame, periods_per_year: int = 252) -> dict:
    """All §39 metrics from a journal DataFrame. Empty input -> zeroed dict
    with ready=False so callers can report honestly instead of crashing."""
    out = {
        "ready": False,
        "trade_count": 0,
        "net_profit": 0.0, "gross_profit": 0.0, "gross_loss": 0.0,
        "profit_factor": 0.0, "expected_payoff": 0.0,
        "win_rate": 0.0, "average_win": 0.0, "average_loss": 0.0,
        "largest_win": 0.0, "largest_loss": 0.0,
        "max_drawdown": 0.0, "max_drawdown_pct": 0.0,
        "recovery_factor": 0.0, "sharpe": 0.0, "sortino": 0.0,
        "average_holding_bars": 0.0,
        "max_consecutive_wins": 0, "max_consecutive_losses": 0,
    }
    if df is None or len(df) == 0:
        return out

    pl = df["pl_money"].astype(float)
    wins, losses = pl[pl > 0], pl[pl < 0]

    out["ready"] = True
    out["trade_count"] = int(len(df))
    out["net_profit"] = float(pl.sum())
    out["gross_profit"] = float(wins.sum())
    out["gross_loss"] = float(-losses.sum())
    out["profit_factor"] = (
        round(out["gross_profit"] / out["gross_loss"], 4)
        if out["gross_loss"] > 0 else (999.0 if out["gross_profit"] > 0 else 0.0)
    )
    out["expected_payoff"] = float(pl.mean())
    out["win_rate"] = round(100.0 * len(wins) / len(df), 2)
    out["average_win"] = float(wins.mean()) if len(wins) else 0.0
    out["average_loss"] = float(losses.mean()) if len(losses) else 0.0
    out["largest_win"] = float(pl.max())
    out["largest_loss"] = float(pl.min())

    # --- equity curve on close order (§38); drawdown in money and %
    eq = pl.cumsum()
    peak = eq.cummax()
    dd = eq - peak
    out["max_drawdown"] = float(dd.min())
    # % against the running peak equity; base starts at the first peak proxy
    denom = peak.replace(0, np.nan)
    out["max_drawdown_pct"] = float((dd / denom).min() * 100.0) if denom.notna().any() else 0.0

    out["recovery_factor"] = (
        round(out["net_profit"] / abs(out["max_drawdown"]), 4)
        if out["max_drawdown"] < 0 else 0.0
    )

    # --- per-trade Sharpe/Sortino scaled by sqrt(trades/year proxy)
    r = df["r_multiple"].astype(float)
    if len(r) > 1 and r.std(ddof=1) > 0:
        scale = np.sqrt(periods_per_year)
        out["sharpe"] = round(float(r.mean() / r.std(ddof=1) * scale), 4)
        downside = r[r < 0].std(ddof=1)
        out["sortino"] = round(float(r.mean() / downside * scale), 4) if downside and downside > 0 else 0.0

    if "bars_in_trade" in df.columns:
        out["average_holding_bars"] = float(df["bars_in_trade"].mean())

    out["max_consecutive_wins"] = _max_consecutive((pl > 0).tolist())
    out["max_consecutive_losses"] = _max_consecutive((pl < 0).tolist())
    return out


def breakdown(df: pd.DataFrame, by: str) -> pd.DataFrame:
    """Profit broken down by a categorical column (regime/session/setup/
    direction/exit_reason per §39). Requires the column to exist."""
    if by not in df.columns:
        raise KeyError(f"journal has no '{by}' column")
    g = df.groupby(df[by].fillna("UNKNOWN"), dropna=False)
    out = pd.DataFrame({
        "trades": g.size(),
        "net_profit": g["pl_money"].sum(),
        "win_rate_pct": g["pl_money"].apply(lambda s: 100.0 * (s > 0).mean() if len(s) else 0.0),
        "expectancy": g["pl_money"].mean(),
        "expectancy_r": g["r_multiple"].mean(),
        "profit_factor": g["pl_money"].apply(
            lambda s: (s[s > 0].sum() / -s[s < 0].sum())
            if (s < 0).any() and s[s < 0].sum() != 0
            else (999.0 if (s > 0).any() else 0.0)),
    })
    return out.round(4).sort_values("net_profit")


def monthly_returns(df: pd.DataFrame) -> pd.Series:
    """Net P/L by calendar month (§39)."""
    m = df.set_index("close_time")["pl_money"].resample("ME").sum()
    return m[m != 0]


def yearly_returns(df: pd.DataFrame) -> pd.Series:
    y = df.set_index("close_time")["pl_money"].resample("YE").sum()
    return y[y != 0]
