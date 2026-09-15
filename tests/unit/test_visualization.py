"""Visualization tests (M14): headless rendering must produce files."""
import sys
from pathlib import Path

import pandas as pd

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "python"))

from xare import visualization as viz


def _tiny_journal():
    return pd.DataFrame({
        "close_time": pd.date_range("2024-01-01", periods=20, freq="8h"),
        "pl_money": [5.0, -3.0] * 10,
        "r_multiple": [1.5, -1.0] * 10,
    })


def test_equity_curve_png(tmp_path):
    out = viz.equity_curve(_tiny_journal(), out=str(tmp_path / "eq.png"))
    assert Path(out).is_file() and Path(out).stat().st_size > 1000


def test_drawdown_curve_png(tmp_path):
    out = viz.drawdown_curve(_tiny_journal(), out=str(tmp_path / "dd.png"))
    assert Path(out).is_file() and Path(out).stat().st_size > 1000


def test_r_distribution_png(tmp_path):
    out = viz.r_distribution(_tiny_journal(), out=str(tmp_path / "r.png"))
    assert Path(out).is_file() and Path(out).stat().st_size > 1000
