"""Execution stress testing (hardening item C15, spec §18).

Replays a trade journal under worse-than-average execution:
  - spread stress: entry costs scaled ×1.5 / ×2 (R losses grow, R wins shrink)
  - slippage stress: fixed points added against the trade on entry AND exit

A strategy that only survives with perfect historical execution must be
rejected; this module quantifies how much of the result execution quality
explains. Verdicts are RESEARCH LABELS, never guarantees.

Works on the XARE journal CSV (M13 schema) or any DataFrame with:
  r_multiple (float, required)
"""
from __future__ import annotations

from dataclasses import dataclass, field

import pandas as pd

from .metrics import compute_metrics  # single source of metric math

# --- stress parameters (documented hypotheses, docs/parameters.md) ---------
SPREAD_MULTIPLES = (1.5, 2.0)
SLIPPAGE_R_FRACTIONS = (0.05, 0.10)   # slip as a fraction of 1R per side


@dataclass
class StressVerdict:
    scenario: str
    n_trades: int
    profit_factor: float
    expectancy_r: float
    max_dd_r: float
    warnings: list[str] = field(default_factory=list)


def _pf_expectancy(r: pd.Series) -> tuple[float, float]:
    wins = r[r > 0]
    losses = r[r < 0]
    pf = (wins.sum() / abs(losses.sum())) if len(losses) and losses.sum() != 0 \
        else (float("inf") if len(wins) else 0.0)
    return pf, float(r.mean())


def _max_dd_r(r: pd.Series) -> float:
    eq = r.cumsum()
    peak = eq.cummax()
    return float((peak - eq).max()) if len(eq) else 0.0


def stress_r_series(r: pd.Series, spread_multiple: float = 1.0,
                    slippage_fraction: float = 0.0) -> pd.Series:
    """Apply execution stress to a per-trade R series.

    spread_multiple: round-trip cost multiplier. Baseline costs are already
    inside realized R; the stress scenario multiplies ONLY the baseline
    spread drag, approximated as (multiple - 1) × baseline_loss_unit where
    the baseline loss unit is the median losing trade's R magnitude capped
    at 1.0 (stop-out ≈ 1R by construction in XARE).
    slippage_fraction: extra R lost per side (entry + exit = 2× fraction).
    """
    r = pd.Series(r, dtype=float)
    if r.empty:
        return r
    drag = 0.0
    if spread_multiple > 1.0:
        losers = r[r < 0]
        base_unit = min(abs(float(losers.median())) if len(losers) else 1.0, 1.0)
        base_unit = base_unit if base_unit > 0 else 1.0
        drag += (spread_multiple - 1.0) * base_unit
    if slippage_fraction > 0:
        drag += 2.0 * slippage_fraction
    if drag <= 0:
        return r.copy()
    return r - drag


def run_stress(r_trades: pd.Series) -> list[StressVerdict]:
    """Full stress grid: baseline + spread multiples + slippage fractions."""
    r_trades = pd.Series(r_trades, dtype=float).dropna()
    verdicts: list[StressVerdict] = []

    scenarios: list[tuple[str, float, float]] = [("baseline", 1.0, 0.0)]
    scenarios += [(f"spread x{m}", m, 0.0) for m in SPREAD_MULTIPLES]
    scenarios += [(f"slippage {s:.0%}", 1.0, s) for s in SLIPPAGE_R_FRACTIONS]
    scenarios += [(f"spread x{m} + slip {s:.0%}", m, s)
                  for m in SPREAD_MULTIPLES for s in SLIPPAGE_R_FRACTIONS[:1]]

    base_pf = None
    for name, mult, slip in scenarios:
        r_s = stress_r_series(r_trades, mult, slip)
        pf, exp = _pf_expectancy(r_s)
        dd = _max_dd_r(r_s)
        v = StressVerdict(scenario=name, n_trades=len(r_s),
                          profit_factor=pf, expectancy_r=exp, max_dd_r=dd)
        if name != "baseline":
            if base_pf is None:
                base_pf = verdicts[0].profit_factor
            if base_pf and base_pf != float("inf") and pf < base_pf * 0.5:
                v.warnings.append("profit factor halves under stress")
            if exp <= 0:
                v.warnings.append("expectancy non-positive under stress")
        verdicts.append(v)
    return verdicts


def stress_frame(r_trades: pd.Series) -> pd.DataFrame:
    rows = [vars(v) for v in run_stress(r_trades)]
    df = pd.DataFrame(rows)
    df["warnings"] = df["warnings"].apply(lambda w: "; ".join(w))
    return df
