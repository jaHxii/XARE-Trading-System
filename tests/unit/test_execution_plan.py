"""Execution plan-builder contract tests (M10).

Python mirrors of XareBuildTradePlan() (ExecutionEngine.mqh) and the
SELF_TEST group T14 fixtures. The builder is pure: gates run in documented
order (band -> position caps -> quotes -> SL -> TP -> sizing -> margin),
SL/TP land on the safe side of the tick grid, sizing reuses the M9 risk
math. Authoritative logic is MQL5; these pin it for regression.

All broker properties in fixtures are SYNTHETIC TEST DATA.
"""
import math
import sys
from pathlib import Path
import pytest
from dataclasses import dataclass, field

sys.path.insert(0, str(Path(__file__).resolve().parent))
from test_risk_math import (Props, point_value_per_lot, snap_volume_down,
                            volume_for_risk, stop_distance, tp_distance)


@dataclass
class Cfg:
    """Numeric mirror of the config fields the plan builder reads."""
    score_min: float = 60.0
    score_candidate: float = 70.0
    score_trade: float = 80.0
    score_strong: float = 85.0
    max_concurrent_positions: int = 1
    max_trades_per_day: int = 3
    sl_mode: str = "HYBRID"
    sl_atr_mult: float = 1.5
    tp_mode: str = "R"
    tp_r_multiple: float = 2.0
    tp_atr_mult: float = 3.0
    emergency_max_lot_x1000: int = 500
    max_margin_pct: float = 50.0


def band_of(score, cfg):
    if score < cfg.score_min:
        return "NONE"
    if score < cfg.score_candidate:
        return "CANDIDATE"
    if score < cfg.score_trade:
        return "TRADE"
    return "STRONG"


def build_plan(direction, score, bid, ask, props, cfg, eff_risk, atr,
               swing_low, swing_high, open_positions, trades_today,
               equity, free_margin, margin_per_lot):
    """Mirror of XareBuildTradePlan() gate order + math.

    Returns (actionable, block_reason, dict-of-plan-fields).
    Block reasons use the MQL5 enum names for easy cross-checking.
    """
    if bid <= 0 or ask <= 0:
        return False, "NO_QUOTES", {}
    if band_of(score, cfg) not in ("TRADE", "STRONG"):
        return False, "NO_TRADE_BAND", {}
    if open_positions >= cfg.max_concurrent_positions:
        return False, "MAX_POSITIONS", {}
    if trades_today >= cfg.max_trades_per_day:
        return False, "MAX_TRADES_DAY", {}

    is_buy = direction > 0
    entry = ask if is_buy else bid
    swing = swing_low if is_buy else swing_high
    spread_px = ask - bid
    min_dist = props.stops_level * props.point + spread_px
    if min_dist <= 0:
        min_dist = 1.0

    sl_dist = stop_distance(direction, entry, swing, atr, cfg.sl_atr_mult,
                            cfg.sl_mode, min_dist)
    if sl_dist is None:
        return False, "SL_INVALID", {}

    tp_dist = tp_distance(cfg.tp_mode, sl_dist, atr, cfg.tp_r_multiple,
                          cfg.tp_atr_mult)
    if tp_dist is None:
        return False, "TP_INVALID", {}

    step = props.tick_size if props.tick_size > 0 else props.point
    sl_px = entry - sl_dist if is_buy else entry + sl_dist
    tp_px = entry + tp_dist if is_buy else entry - tp_dist
    if is_buy:
        sl_px = math.floor(sl_px / step) * step
        tp_px = math.floor(tp_px / step) * step
    else:
        sl_px = math.ceil(sl_px / step) * step
        tp_px = math.ceil(tp_px / step) * step

    sl_pts = abs(entry - sl_px) / props.point
    tp_pts = abs(tp_px - entry) / props.point

    ok, vol, risk_money = volume_for_risk(
        equity, eff_risk, sl_pts, props,
        cfg.emergency_max_lot_x1000 / 1000.0)
    if not ok:
        if eff_risk <= 0:
            return False, "DRAWDOWN_STATE", {}
        return False, "VOLUME", {}

    margin_need = margin_per_lot * vol if margin_per_lot > 0 else 0.0
    if margin_need > free_margin * cfg.max_margin_pct / 100.0:
        return False, "MARGIN", {}

    return True, "NONE", {
        "direction": direction, "entry": entry,
        "sl_price": round(sl_px, props.digits + 2),
        "tp_price": round(tp_px, props.digits + 2),
        "volume": vol, "risk_pct": eff_risk, "risk_money": risk_money,
        "sl_points": sl_pts, "tp_points": tp_pts,
        "planned_r": tp_pts / sl_pts if sl_pts > 0 else 0.0,
    }


# --- the T14 synthetic fixture (identical numbers to the MQL5 SELF_TEST) ---
PP = Props()
PC = Cfg()


def plan_basic():
    return build_plan(1, 84.0, 1999.0, 2000.0, PP, PC, 0.5, 4.0,
                      1999.0, 2050.0, 0, 0, 10000.0, 10000.0, 0.0)


class TestPlanBasic:
    def test_full_pass_plan(self):
        ok, reason, p = plan_basic()
        assert ok, reason
        assert p["direction"] == 1
        # SL: hybrid picks ATR 4x1.5=6.00px over structure 1.00px
        assert p["sl_price"] == pytest.approx(1994.0)
        assert p["tp_price"] == pytest.approx(2012.0)   # +2R
        assert p["planned_r"] == pytest.approx(2.0)
        # sizing: $50 risk / $6-per-lot (600pt x $1) -> 0.0833 -> 0.08
        assert p["volume"] == pytest.approx(0.08)
        assert p["risk_money"] == pytest.approx(50.0)

    def test_sl_loss_at_volume_never_exceeds_risk(self):
        ok, _, p = plan_basic()
        assert ok
        loss = p["sl_points"] * p["volume"] * point_value_per_lot(PP)
        assert loss <= p["risk_money"] + 1e-9


class TestGates:
    def test_band_gate_blocks_candidate_score(self):
        ok, reason, _ = build_plan(1, 65.0, 1999.0, 2000.0, PP, PC, 0.5, 4.0,
                                   1999.0, 2050.0, 0, 0, 10000.0, 10000.0, 0.0)
        assert not ok and reason == "NO_TRADE_BAND"

    def test_position_cap(self):
        ok, reason, _ = build_plan(1, 84.0, 1999.0, 2000.0, PP, PC, 0.5, 4.0,
                                   1999.0, 2050.0, 1, 0, 10000.0, 10000.0, 0.0)
        assert not ok and reason == "MAX_POSITIONS"

    def test_trades_per_day_cap(self):
        ok, reason, _ = build_plan(1, 84.0, 1999.0, 2000.0, PP, PC, 0.5, 4.0,
                                   1999.0, 2050.0, 0, 3, 10000.0, 10000.0, 0.0)
        assert not ok and reason == "MAX_TRADES_DAY"

    def test_no_quotes(self):
        ok, reason, _ = build_plan(1, 84.0, 0.0, 0.0, PP, PC, 0.5, 4.0,
                                   1999.0, 2050.0, 0, 0, 10000.0, 10000.0, 0.0)
        assert not ok and reason == "NO_QUOTES"


class TestRiskGates:
    def test_halted_blocks(self):
        ok, reason, _ = build_plan(1, 84.0, 1999.0, 2000.0, PP, PC, 0.0, 4.0,
                                   1999.0, 2050.0, 0, 0, 10000.0, 10000.0, 0.0)
        assert not ok and reason == "DRAWDOWN_STATE"

    def test_small_account_skips_never_pads(self):
        # $50 @ 0.05% = $0.025 -> raw 0.00004 lots -> skip, not min-lot
        ok, reason, _ = build_plan(1, 84.0, 1999.0, 2000.0, PP, PC, 0.05, 4.0,
                                   1999.0, 2050.0, 0, 0, 50.0, 50.0, 0.0)
        assert not ok and reason == "VOLUME"

    def test_margin_budget_blocks(self):
        # $7000/lot x 0.08 = $560 > 50% of free 1000 = $500
        ok, reason, _ = build_plan(1, 84.0, 1999.0, 2000.0, PP, PC, 0.5, 4.0,
                                   1999.0, 2050.0, 0, 0, 10000.0, 1000.0, 7000.0)
        assert not ok and reason == "MARGIN"

    def test_margin_within_budget_passes(self):
        # $7000/lot x 0.08 = $560 <= 60% of free 1000 = $600
        ok, reason, _ = build_plan(1, 84.0, 1999.0, 2000.0, PP, PC, 0.5, 4.0,
                                   1999.0, 2050.0, 0, 0, 10000.0, 1000.0, 7000.0)
        # default max_margin_pct is 50 -> recompute with 60
        cfg = Cfg(max_margin_pct=60.0)
        ok2, reason2, p2 = build_plan(1, 84.0, 1999.0, 2000.0, PP, cfg, 0.5,
                                      4.0, 1999.0, 2050.0, 0, 0, 10000.0,
                                      1000.0, 7000.0)
        assert not ok and reason == "MARGIN"
        assert ok2 and p2["volume"] == pytest.approx(0.08)


class TestStopsFloor:
    def test_stops_level_forces_wider_sl(self):
        # stops_level 100 -> min_dist = 1.00px + spread 1.00px = 2.00px;
        # ATR 0.15px and structure 1.00px both below -> SL = 2.00px = 200pt
        ok, reason, p = build_plan(1, 84.0, 1999.0, 2000.0,
                                   Props(stops_level=100), PC, 0.5, 0.1,
                                   1999.0, 2050.0, 0, 0, 10000.0, 10000.0, 0.0)
        assert ok and p["sl_points"] >= 200.0


class TestShortSide:
    def test_short_plan_mirrors_long(self):
        # sell at bid 1999 with swing_high 2003 (structure 4px) and ATR 4:
        # hybrid takes max(4x1.5=6px, 4px) = 6px -> mirrors the long fixture
        ok, reason, p = build_plan(-1, 84.0, 1999.0, 2000.0, PP, PC, 0.5, 4.0,
                                   1950.0, 2003.0, 0, 0, 10000.0, 10000.0, 0.0)
        assert ok, reason
        assert p["direction"] == -1
        assert p["sl_price"] == pytest.approx(2005.0)   # 1999 + 6.00
        assert p["tp_price"] == pytest.approx(1987.0)   # -2R = -12.00

    def test_short_uses_wider_structure_when_far(self):
        # swing_high 2050 -> structure 51px beats ATR 6px; volume then falls
        # below broker min and the plan must REFUSE rather than pad (§49)
        ok, reason, _ = build_plan(-1, 84.0, 1999.0, 2000.0, PP, PC, 0.5, 4.0,
                                   1950.0, 2050.0, 0, 0, 10000.0, 10000.0, 0.0)
        assert not ok and reason == "VOLUME"
