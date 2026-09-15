"""Overfitting and sample-size warnings (spec §44, §56).

Every check returns a list of human-readable warnings. A warning is a
RESEARCH LABEL, never a guarantee of future behavior. The overall
classification (§44) is one of:

    ROBUST / QUESTIONABLE / OVERFIT_RISK / FAIL
"""
from __future__ import annotations

# --- configurable thresholds (documented hypotheses, docs/parameters.md) ---
MIN_TRADES = 100            # below: results are not meaningful
MIN_TRADES_HARD = 30        # below: automatic FAIL regardless of anything else
MAX_DRAWDOWN_PCT = 30.0     # beyond: catastrophic for the account
MIN_OUT_OF_SAMPLE_R = 0.0   # OOS expectancy (R) must exceed this
PF_DROP_WARN = 0.40         # OOS PF < 60% of IS PF -> stability warning
CONCENTRATION_WARN = 0.60   # one bucket holding >60% of net profit
MIN_BUCKETS = 3             # fewer profitable buckets -> dependence


def sample_size_warnings(trade_count: int) -> list[str]:
    w = []
    if trade_count < MIN_TRADES_HARD:
        w.append(f"FAIL: only {trade_count} trades (<{MIN_TRADES_HARD}) — "
                 f"sample is too small to support ANY conclusion")
    elif trade_count < MIN_TRADES:
        w.append(f"insufficient sample: {trade_count} trades (<{MIN_TRADES}) — "
                 f"treat every metric as provisional")
    return w


def overfit_warnings(train: dict, test: dict) -> list[str]:
    """Compare in-sample vs out-of-sample metric dicts (see metrics.compute_metrics)."""
    w = []
    if not train.get("ready") or not test.get("ready"):
        w.append("NOT EVALUATED: in-sample/out-of-sample comparison needs trades in both sets")
        return w
    if train["profit_factor"] > 0 and test["profit_factor"] > 0:
        drop = 1.0 - (test["profit_factor"] / train["profit_factor"])
        if drop > PF_DROP_WARN:
            w.append(f"profit factor collapses out-of-sample "
                     f"({train['profit_factor']:.2f} -> {test['profit_factor']:.2f}, "
                     f"-{drop * 100:.0f}%) — classic overfitting signature")
    if test.get("expectancy_r", test.get("expected_payoff", 0.0)) < MIN_OUT_OF_SAMPLE_R:
        w.append("out-of-sample expectancy is negative — edge did not survive")
    if train["trade_count"] > 0 and test["trade_count"] > 0:
        ratio = test["trade_count"] / max(1, train["trade_count"])
        if ratio < 0.25 or ratio > 4.0:
            w.append(f"trade frequency shifts drastically OOS "
                     f"(IS {train['trade_count']} vs OOS {test['trade_count']}) — "
                     f"regime-dependent behavior")
    return w


def concentration_warnings(breakdown_df) -> list[str]:
    """Warn when profit depends on one bucket (single period/session/regime)."""
    w = []
    if breakdown_df is None or len(breakdown_df) == 0:
        return w
    net = breakdown_df["net_profit"]
    total = net[net > 0].sum()
    if total <= 0:
        w.append("no profitable bucket at all — nothing to concentrate, but nothing works")
        return w
    if len(breakdown_df) < MIN_BUCKETS:
        w.append(f"only {len(breakdown_df)} buckets observed — dependence risk")
    top = net.max()
    if top > 0 and top / total > CONCENTRATION_WARN:
        w.append(f"top bucket holds {top / total * 100:.0f}% of gross profit — "
                 f"single-bucket dependence")
    return w


def drawdown_warnings(metrics: dict) -> list[str]:
    w = []
    if metrics.get("ready"):
        if abs(metrics["max_drawdown_pct"]) > MAX_DRAWDOWN_PCT:
            w.append(f"max drawdown {metrics['max_drawdown_pct']:.1f}% exceeds the "
                     f"{MAX_DRAWDOWN_PCT:.0f}% research ceiling — catastrophic risk")
        if metrics["recovery_factor"] < 1.0 and metrics["net_profit"] > 0:
            w.append("recovery factor below 1.0 — profit does not cover the drawdown")
    return w


def classify(train: dict, test: dict, stability_ok: bool | None = None) -> str:
    """Overall §44 label from the warning sets. Deterministic, conservative:
    any FAIL-level condition dominates; OVERFIT_RISK when OOS collapses;
    QUESTIONABLE when only sample/concentration warnings exist."""
    all_w = (sample_size_warnings(train.get("trade_count", 0)) +
             sample_size_warnings(test.get("trade_count", 0)))
    of = overfit_warnings(train, test)
    if any(x.startswith("FAIL:") for x in all_w):
        return "FAIL"
    if any("collapses" in x or "negative — edge did not survive" in x for x in of):
        return "OVERFIT_RISK"
    if stability_ok is False:
        return "OVERFIT_RISK"
    if all_w or of:
        return "QUESTIONABLE"
    if stability_ok is True and not all_w and not of:
        return "ROBUST"
    return "QUESTIONABLE"
