"""Regression guard: core project artifacts must exist (M0/M1).

If one of these disappears, the repository layout broke — fail loudly.
"""
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]

REQUIRED_FILES = [
    "README.md",
    "LICENSE",
    ".gitignore",
    "docs/architecture.md",
    "docs/strategy.md",
    "docs/risk.md",
    "docs/testing.md",
    "docs/parameters.md",
    "docs/changelog.md",
    "experiments/README.md",
    "experiments/experiment_registry.csv",
    "python/requirements.txt",
    "mql5/XARE.mq5",
    "mql5/Include/XARE/Types.mqh",
    "mql5/Include/XARE/Config.mqh",
    "mql5/Include/XARE/Logger.mqh",
    "mql5/Include/XARE/Diagnostics.mqh",
    "mql5/Include/XARE/MarketData.mqh",
    "mql5/Include/XARE/Indicators.mqh",
    "mql5/Include/XARE/MultiTimeframe.mqh",
    "mql5/Include/XARE/RegimeEngine.mqh",
    "mql5/Include/XARE/StructureEngine.mqh",
    "mql5/Include/XARE/SessionEngine.mqh",
    "mql5/Include/XARE/LiquidityEngine.mqh",
    "mql5/Include/XARE/SignalEngine.mqh",
    "mql5/Include/XARE/ScoreEngine.mqh",
    "mql5/Include/XARE/RiskEngine.mqh",
    "mql5/Include/XARE/ExecutionEngine.mqh",
    "mql5/Include/XARE/PositionManager.mqh",
    "mql5/Include/XARE/ExitEngine.mqh",
    "mql5/Include/XARE/SafetyEngine.mqh",
    "mql5/Include/XARE/NewsFilter.mqh",
    "mql5/Include/XARE/ResearchLogger.mqh",
    "mql5/Include/XARE/PerformanceTracker.mqh",
    "mql5/Include/XARE/StateStore.mqh",
    "mql5/Include/XARE/HealthCheck.mqh",
]


def test_required_files_exist():
    missing = [f for f in REQUIRED_FILES if not (REPO / f).is_file()]
    assert not missing, f"missing project files: {missing}"


def test_registry_header_intact():
    line = (REPO / "experiments/experiment_registry.csv").read_text(
        encoding="utf-8").splitlines()[0]
    for col in ("experiment_id", "code_version", "param_version",
                "robustness_label", "notes"):
        assert col in line, f"registry header lost column {col}"


def test_ea_defaults_are_safe():
    """Spec 63: defaults must never trade. Parse XARE.mq5 input defaults."""
    src = (REPO / "mql5/XARE.mq5").read_text(encoding="utf-8")
    assert "InpMode            = XARE_MODE_SIGNAL_ONLY" in src
    assert "InpTradingEnabled  = false" in src


def test_config_defaults_are_safe():
    """Spec 63 mirrored in Config.mqh defaults."""
    src = (REPO / "mql5/Include/XARE/Config.mqh").read_text(encoding="utf-8")
    assert "XARE_MODE_SIGNAL_ONLY" in src
    assert "c.trading_enabled        = false" in src


def test_no_mql4_strict_property():
    src = (REPO / "mql5/XARE.mq5").read_text(encoding="utf-8")
    assert "#property strict" not in src, "MQL4-only directive present"


def test_closed_bar_guard_in_data_layer():
    """M2: data layer must hard-refuse shift<1 reads (look-ahead protection)."""
    md = (REPO / "mql5/Include/XARE/MarketData.mqh").read_text(encoding="utf-8")
    assert "if(shift < 1)" in md
    ind = (REPO / "mql5/Include/XARE/Indicators.mqh").read_text(encoding="utf-8")
    assert "shift < 1" in ind


def test_new_bar_detection_exists():
    """M2: new-bar gate must exist with a duplicate guard anchor."""
    md = (REPO / "mql5/Include/XARE/MarketData.mqh").read_text(encoding="utf-8")
    assert "IsNewBar" in md
    assert "m_last_bar_time" in md


def test_mtf_mixed_alignment_is_distinct():
    """M3: conflicting TFs must classify as MIXED (never forced into a trade)."""
    mtf = (REPO / "mql5/Include/XARE/MultiTimeframe.mqh").read_text(encoding="utf-8")
    assert "XARE_ALIGN_MIXED" in mtf
    assert "ClassifyStatic" in mtf  # self-testable pure classifier


def test_sessions_use_broker_time():
    """M6: sessions must be broker-server-time based, never local time."""
    se = (REPO / "mql5/Include/XARE/SessionEngine.mqh").read_text(encoding="utf-8")
    assert "TimeToStruct" in se          # bar time decomposition
    assert "TimeLocal" not in se         # local time forbidden
    assert "TimeLocal" not in (REPO / "mql5/XARE.mq5").read_text(encoding="utf-8")


def test_liquidity_sweep_definition_is_objective():
    """M6: sweep = wick through + close back; close-beyond is a break."""
    le = (REPO / "mql5/Include/XARE/LiquidityEngine.mqh").read_text(encoding="utf-8")
    assert "bar_close < level" in le
    assert "bar_close > level" in le
    assert "SweepStatic" in le           # self-testable pure math


def test_pipeline_layering_order_in_ea():
    """M2-M6 integration: engines must be evaluated in dependency order."""
    ea = (REPO / "mql5/XARE.mq5").read_text(encoding="utf-8")
    pos = {k: ea.find(k) for k in (
        "g_ind.Update", "g_mtf.Evaluate", "g_regime.Evaluate",
        "g_struct.Evaluate", "g_sess.Evaluate", "g_liq.Evaluate")}
    order = sorted(pos.items(), key=lambda kv: kv[1])
    assert [k for k, _ in order] == [
        "g_ind.Update", "g_mtf.Evaluate", "g_regime.Evaluate",
        "g_struct.Evaluate", "g_sess.Evaluate", "g_liq.Evaluate"], \
        f"pipeline order broken: {pos}"
    assert all(v >= 0 for v in pos.values())


def test_structure_pivot_confirmation_documented():
    """M5: anti-look-ahead pivot rule must be explicit and use closed bars."""
    se = (REPO / "mql5/Include/XARE/StructureEngine.mqh").read_text(encoding="utf-8")
    assert "Pivot confirmation rule" in se
    assert "MinBarsForPivot" in se


def test_regime_uses_all_spec9_regimes():
    """M4: all spec-9 regimes must exist and confidence is score, not probability."""
    types_src = (REPO / "mql5/Include/XARE/Types.mqh").read_text(encoding="utf-8")
    for token in ("XARE_REGIME_TREND_UP", "XARE_REGIME_TREND_DOWN",
                  "XARE_REGIME_RANGE", "XARE_REGIME_BREAKOUT",
                  "XARE_REGIME_HIGH_VOLATILITY", "XARE_REGIME_LOW_VOLATILITY",
                  "XARE_REGIME_UNSAFE", "XARE_REGIME_UNKNOWN"):
        assert token in types_src
    eng = (REPO / "mql5/Include/XARE/RegimeEngine.mqh").read_text(encoding="utf-8")
    assert "not a probability" in eng or "NOT a probability" in eng


def test_no_trade_paths_exist():
    """M10+ invariant: OrderSend only in ExecutionEngine.mqh; no CTrade
    wrappers or convenience Buy()/Sell() anywhere."""
    import re
    for p in list((REPO / "mql5").rglob("*.mq5")) + \
            list((REPO / "mql5/Include/XARE").rglob("*.mqh")):
        src = p.read_text(encoding="utf-8", errors="replace")
        assert not re.search(r"\bCTrade\b|\bPositionOpen\b|\bPositionClose\b|\bPositionModify\b",
                             src), f"trade wrapper in {p.name}"
        if p.name != "ExecutionEngine.mqh":
            assert "OrderSend" not in src, \
                f"{p.name} sends orders outside the execution layer"


def test_safety_first_defaults_m9_m12():
    """M9-M12: trading path defaults must stay conservative (spec §63)."""
    src = (REPO / "mql5/Include/XARE/Config.mqh").read_text(encoding="utf-8")
    # one position per symbol (§32), min-lot override off (§49), no close-all
    assert "c.max_concurrent_positions= 1;" in src
    assert "c.allow_min_lot_override  = false;" in src
    assert "c.close_on_daily_limit    = false;" in src
    # risk limits present and ordered sensibly
    assert "c.risk_per_trade_pct      = 0.5;" in src
    assert "c.daily_loss_limit_pct    = 2.0;" in src
    assert "c.dd_halt_pct             = 15.0;" in src
    ea = (REPO / "mql5/XARE.mq5").read_text(encoding="utf-8")
    # trading modes gate on the explicit switch; signal-only default intact
    assert "ModeAllowsTrading" in ea
    assert 'InpTradingEnabled  = false' in ea


def test_score_weights_sum_to_100_in_config():
    """M8: scoring weights must total 100 and bands must be ordered."""
    import re
    src = (REPO / "mql5/Include/XARE/Config.mqh").read_text(encoding="utf-8")

    def grab(name):
        m = re.search(rf"c\.{name}\s*=\s*([0-9.]+)\s*;", src)
        assert m, f"{name} not found in Config.mqh"
        return float(m.group(1))

    weights = [grab(k) for k in ("w_trend", "w_mtf", "w_structure", "w_momentum",
                                 "w_liquidity", "w_volatility", "w_session", "w_setup")]
    assert abs(sum(weights) - 100.0) < 0.01, f"weights sum {sum(weights)}"
    bands = [grab(k) for k in ("score_min", "score_candidate", "score_trade",
                               "score_strong")]
    assert bands == sorted(bands), f"bands not ordered: {bands}"
