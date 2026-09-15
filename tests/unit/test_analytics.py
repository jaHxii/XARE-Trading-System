"""Tests for the M14-M18 analytics modules (metrics, warnings, report,
walk-forward, monte-carlo, stability). All fixtures are synthetic and
deterministic — no fabricated "real" results anywhere."""
import numpy as np
import pandas as pd
import pytest

import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "python"))

from xare import metrics, monte_carlo, report, stability, walk_forward, warnings as xw


def make_journal(n=120, seed=7, win_rate=0.55, win=1.8, loss=-1.0):
    """Deterministic synthetic trade journal with journal-style columns."""
    rng = np.random.default_rng(seed)
    rows = []
    t0 = pd.Timestamp("2024-01-01 10:00", tz=None)
    for i in range(n):
        r = win if rng.random() < win_rate else loss
        pl = r * 10.0
        rows.append({
            "close_time": t0 + pd.Timedelta(hours=8 * i),
            "ticket": 1000 + i,
            "symbol": "TEST",
            "direction": 1 if i % 2 else -1,
            "setup": ["TREND_PULLBACK", "BREAKOUT", "RANGE_REVERSAL"][i % 3],
            "regime": ["TREND_UP", "RANGE", "TREND_DOWN"][i % 3],
            "session": ["LONDON", "NEWYORK", "OVERLAP"][i % 3],
            "score": 70 + (i % 20),
            "risk_pct": 0.5,
            "volume": 0.01,
            "entry": 2000 + i * 0.1, "sl": 1994, "tp": 2012,
            "exit_price": 2000 + i * 0.1 + r,
            "exit_reason": "TP" if r > 0 else "HARD_SL",
            "pl_money": pl,
            "r_multiple": r,
            "bars_in_trade": 3 + i % 10,
            "slippage_points": 1.0,
            "open_reason": "test",
        })
    return pd.DataFrame(rows)


class TestMetrics:
    def test_all_required_metrics_present(self):
        m = metrics.compute_metrics(make_journal())
        for k in ("net_profit", "profit_factor", "expected_payoff", "max_drawdown",
                  "max_drawdown_pct", "recovery_factor", "sharpe", "sortino",
                  "win_rate", "trade_count", "largest_win", "largest_loss",
                  "max_consecutive_losses", "max_consecutive_wins"):
            assert k in m
        assert m["ready"] and m["trade_count"] == 120

    def test_empty_is_ready_false_not_crash(self):
        m = metrics.compute_metrics(pd.DataFrame())
        assert not m["ready"] and m["trade_count"] == 0

    def test_metric_values_are_consistent(self):
        # fully deterministic frame: WLWL... -> exact sums (no rng noise)
        df = pd.DataFrame({
            "close_time": pd.date_range("2024-01-01", periods=10, freq="8h"),
            "pl_money": [10.0, -10.0] * 5,
            "r_multiple": [1.0, -1.0] * 5,
        })
        m = metrics.compute_metrics(df)
        assert m["gross_profit"] == pytest.approx(50.0)
        assert m["gross_loss"] == pytest.approx(50.0)
        assert m["profit_factor"] == pytest.approx(1.0)
        assert m["net_profit"] == pytest.approx(0.0)
        assert m["win_rate"] == pytest.approx(50.0)
        assert m["max_drawdown"] <= 0
        assert m["max_consecutive_losses"] == 1

    def test_breakdown_groups(self):
        df = make_journal()
        b = metrics.breakdown(df, "regime")
        assert set(b.index) == {"TREND_UP", "RANGE", "TREND_DOWN"}
        assert b["trades"].sum() == 120

    def test_breakdown_missing_column_raises(self):
        with pytest.raises(KeyError):
            metrics.breakdown(make_journal(), "nonexistent")

    def test_monthly_yearly(self):
        s = metrics.monthly_returns(make_journal())
        assert len(s) >= 1 and (s != 0).all()


class TestWarnings:
    def test_fail_on_tiny_sample(self):
        w = xw.sample_size_warnings(10)
        assert any(x.startswith("FAIL:") for x in w)

    def test_insufficient_sample_warning(self):
        w = xw.sample_size_warnings(60)
        assert w and not w[0].startswith("FAIL:")

    def test_no_warning_on_good_sample(self):
        assert xw.sample_size_warnings(300) == []

    def test_overfit_detection(self):
        train = dict(metrics.compute_metrics(make_journal(200, win_rate=0.7)))
        test = dict(metrics.compute_metrics(make_journal(60, win_rate=0.3)))
        w = xw.overfit_warnings(train, test)
        assert any("collapses" in x or "did not survive" in x for x in w)

    def test_classification_labels(self):
        good = dict(metrics.compute_metrics(make_journal(300, win_rate=0.6)))
        assert xw.classify(good, good, stability_ok=True) == "ROBUST"
        assert xw.classify({"trade_count": 5, "ready": False},
                           {"trade_count": 5, "ready": False}) == "FAIL"
        bad_test = dict(metrics.compute_metrics(make_journal(60, win_rate=0.2)))
        good_tr = dict(metrics.compute_metrics(make_journal(200, win_rate=0.7)))
        assert xw.classify(good_tr, bad_test) == "OVERFIT_RISK"


class TestReport:
    def test_not_executed_report_is_explicit(self):
        rep = report.build_report(None)
        assert rep["status"] == "NOT EXECUTED"
        assert rep["classification"] == "NOT EXECUTED"
        assert not rep["executed"]
        md = report.render(rep)
        assert "NOT EXECUTED" in md and "no performance is claimed" in md

    def test_executed_report_has_all_sections(self):
        rep = report.build_report(make_journal())
        for key in ("profit_factor", "expected_payoff", "max_drawdown",
                    "recovery_factor", "sharpe", "sortino", "win_rate",
                    "trade_count", "largest_loss", "largest_win",
                    "max_consecutive_losses"):
            assert key in rep["metrics"]
        for key in ("regime_performance", "session_performance", "setup_performance"):
            assert rep[key] is not None and len(rep[key]) == 3
        md = report.render(rep)
        for word in ("Net profit", "Profit factor", "Sharpe", "Sortino",
                     "Win rate", "regime", "session", "setup", "Warnings"):
            assert word in md


class TestWalkForward:
    def test_windows_are_all_reported(self):
        df = make_journal(240)   # ~2 months of 8h-spaced trades
        res = walk_forward.run_walk_forward(df, train_months=1, test_months=1,
                                            step_months=1)
        assert len(res) >= 2
        # every window carries both halves + flags; nothing hidden
        for r in res:
            assert "train" in r and "test" in r and "flags" in r

    def test_summary_counts_negative_windows(self):
        df = make_journal(240)
        res = walk_forward.run_walk_forward(df, train_months=1, test_months=1,
                                            step_months=1)
        s = walk_forward.summarize(res)
        assert s["ready"]
        assert s["oos_positive_windows"] + s["oos_negative_windows"] == s["windows_evaluated"]

    def test_empty_framework_note(self):
        s = walk_forward.summarize([])
        assert not s["ready"] and "not run" in s["note"]


class TestMonteCarlo:
    def test_deterministic_with_seed(self):
        pl = make_journal(150)["pl_money"]
        a = monte_carlo.run_monte_carlo(pl, seed=11)
        b = monte_carlo.run_monte_carlo(pl, seed=11)
        assert a == b and a["ready"]

    def test_distributions_are_sane(self):
        pl = make_journal(200)["pl_money"]
        r = monte_carlo.run_monte_carlo(pl, n_sims=800, seed=3)
        assert r["max_dd_pct_p99"] >= r["max_dd_pct_p50"] >= 0
        assert r["worst_losing_streak_p99"] >= r["worst_losing_streak_p50"]
        assert 0 <= r["prob_dd_breach_pct"] <= 100

    def test_insufficient_trades_refused(self):
        r = monte_carlo.run_monte_carlo([1.0], n_sims=10)
        assert not r["ready"]


class TestStability:
    def evaluator(win_rate):
        """Synthetic 'backtest': metrics depend on the win-rate parameter."""
        def ev(params):
            wr = min(0.95, max(0.05, win_rate + params.get("wiggle", 0.0)))
            return metrics.compute_metrics(make_journal(200, win_rate=wr))
        return ev

    def test_robust_plateau(self):
        sens = stability.sensitivity(TestStability.evaluator(0.55),
                                     {"wiggle": 0.0},
                                     deltas={"wiggle": [-0.04, -0.02, 0.02, 0.04]})
        assert sens["ready"]
        assert stability.plateau_verdict(sens) in ("ROBUST", "QUESTIONABLE")

    def test_knife_edge_flagged(self):
        # a parameter that flips the sign of expectancy when nudged
        def ev(params):
            wr = 0.5 + (0.35 if abs(params["wiggle"]) < 1e-9 else 0.0)
            return metrics.compute_metrics(make_journal(200, win_rate=wr))
        sens = stability.sensitivity(ev, {"wiggle": 0.0},
                                     deltas={"wiggle": [-0.01, 0.01]})
        assert stability.plateau_verdict(sens) == "OVERFIT_RISK"

    def test_not_evaluated_without_data(self):
        sens = stability.sensitivity(lambda p: metrics.compute_metrics(pd.DataFrame()),
                                     {"wiggle": 0.0}, deltas={"wiggle": [1]})
        assert not sens["ready"] and stability.plateau_verdict(sens) == "NOT EVALUATED"
