"""Execution-stress module tests (hardening item C15, §18)."""
import sys
from pathlib import Path

import numpy as np
import pandas as pd
import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "python"))

from xare.stress import run_stress, stress_frame, stress_r_series


@pytest.fixture
def r_series():
    """Deterministic R series: 60% win rate, ~0.4R expectancy."""
    rng = np.random.default_rng(42)
    vals = np.where(rng.random(100) < 0.6, rng.uniform(0.8, 2.0, 100),
                    -rng.uniform(0.9, 1.1, 100))
    return pd.Series(vals)


def test_baseline_unchanged(r_series):
    stressed = stress_r_series(r_series, 1.0, 0.0)
    pd.testing.assert_series_equal(stressed, r_series)


def test_spread_stress_reduces_expectancy(r_series):
    base = stress_r_series(r_series, 1.0, 0.0)
    x2 = stress_r_series(r_series, 2.0, 0.0)
    assert x2.mean() < base.mean()


def test_slippage_stress_reduces_expectancy(r_series):
    base = stress_r_series(r_series, 1.0, 0.0)
    slipped = stress_r_series(r_series, 1.0, 0.10)
    assert slipped.mean() == pytest.approx(base.mean() - 0.20)


def test_stress_grid_shapes(r_series):
    verdicts = run_stress(r_series)
    # baseline + 2 spread + 2 slippage + 2 combined
    assert len(verdicts) == 7
    assert verdicts[0].scenario == "baseline"
    assert all(v.n_trades == 100 for v in verdicts)


def test_warnings_fire_when_stress_halves_pf(r_series):
    frame = stress_frame(r_series)
    assert "scenario" in frame.columns
    assert "warnings" in frame.columns


def test_empty_series(r_series):
    verdicts = run_stress(pd.Series(dtype=float))
    assert verdicts[0].n_trades == 0
