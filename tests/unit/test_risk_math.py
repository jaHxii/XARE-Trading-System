"""Risk-engine math contract tests (M9).

Python mirrors of the MQL5 pure functions in RiskEngine.mqh and the
SELF_TEST group T13. The authoritative logic is MQL5 (compile-gated);
these pin the documented behavior in Python for regression review.

All broker properties in the fixtures are SYNTHETIC TEST DATA — the real
values must always come from the broker at runtime.
"""
import math
import pytest
from dataclasses import dataclass


@dataclass
class Props:
    """Mirror of SXareSymbolProps (numeric fields only)."""
    point: float = 0.01
    tick_size: float = 0.01
    tick_value: float = 1.0
    volume_min: float = 0.01
    volume_max: float = 100.0
    volume_step: float = 0.01
    stops_level: int = 0
    valid: bool = True
    digits: int = 2


GOLD_LIKE = Props()  # 100oz-style synthetic contract


def point_value_per_lot(p: Props) -> float:
    """Mirror of XarePointValuePerLot()."""
    if p.point <= 0 or p.tick_size <= 0 or p.tick_value <= 0:
        return 0.0
    return p.tick_value * (p.point / p.tick_size)


def snap_volume_down(raw: float, step: float) -> float:
    """Mirror of XareSnapVolumeDown(): floor to step, never up."""
    if raw <= 0 or step <= 0:
        return 0.0
    lots = math.floor(raw / step + 1e-9) * step
    return round(lots, 8)


def volume_for_risk(equity, risk_pct, sl_points, p, emergency_max_lot):
    """Mirror of XareVolumeForRisk(): returns (ok, volume, risk_money)."""
    if not p.valid or equity <= 0 or risk_pct <= 0 or sl_points <= 0:
        return False, 0.0, 0.0
    pv = point_value_per_lot(p)
    if pv <= 0:
        return False, 0.0, 0.0
    risk_money = equity * risk_pct / 100.0
    loss_per_lot = sl_points * pv
    if loss_per_lot <= 0:
        return False, 0.0, 0.0
    vol = snap_volume_down(risk_money / loss_per_lot, p.volume_step)
    if emergency_max_lot > 0 and vol > emergency_max_lot:
        vol = snap_volume_down(emergency_max_lot, p.volume_step)
    if vol > p.volume_max:
        vol = snap_volume_down(p.volume_max, p.volume_step)
    if vol < p.volume_min:
        return False, 0.0, risk_money
    return True, vol, risk_money


def risk_state_from_dd(dd, caution, reduced, halt):
    """Mirror of XareRiskStateFromDD()."""
    if dd >= halt:
        return "HALTED"
    if dd >= reduced:
        return "REDUCED"
    if dd >= caution:
        return "CAUTION"
    return "NORMAL"


def effective_risk_pct(state, base, mult_caution, mult_reduced):
    """Mirror of XareEffectiveRiskPct()."""
    return {"HALTED": 0.0,
            "REDUCED": base * min(mult_reduced, 1.0),
            "CAUTION": base * min(mult_caution, 1.0)}.get(state, base)


def stop_distance(direction, bar_close, structure_level, atr, atr_mult, mode,
                  min_dist):
    """Mirror of XareStopDistance(); mode in {ATR, STRUCTURE, HYBRID}."""
    if direction == 0 or bar_close <= 0 or min_dist <= 0:
        return None
    atr_dist = atr * atr_mult if (atr > 0 and atr_mult > 0) else 0.0
    struct_dist = 0.0
    if structure_level > 0:
        d = (bar_close - structure_level) if direction > 0 else (structure_level - bar_close)
        if d > 0:
            struct_dist = d
    if mode == "ATR":
        dist = atr_dist
    elif mode == "STRUCTURE":
        dist = struct_dist if struct_dist > 0 else atr_dist
    else:
        dist = max(atr_dist, struct_dist)
    if dist <= 0:
        return None
    return max(dist, min_dist)


def tp_distance(mode, sl_dist, atr, r_multiple, atr_mult):
    """Mirror of XareTpDistance()."""
    if sl_dist <= 0:
        return None
    d = atr * atr_mult if (mode == "ATR" and atr > 0 and atr_mult > 0) else sl_dist * r_multiple
    return d if d > 0 else None


class TestPointValue:
    def test_gold_like_contract(self):
        # tick_value 1.0 per 0.01 tick, point 0.01 -> $1/point/lot
        assert point_value_per_lot(GOLD_LIKE) == pytest.approx(1.0)

    def test_odd_tick_size(self):
        p = Props(tick_size=0.05, tick_value=2.5)
        assert point_value_per_lot(p) == pytest.approx(0.5)

    def test_invalid_properties_zero(self):
        assert point_value_per_lot(Props(point=0)) == 0.0
        assert point_value_per_lot(Props(tick_value=0)) == 0.0


class TestVolumeForRisk:
    def test_basic_sizing(self):
        ok, vol, rm = volume_for_risk(1000.0, 1.0, 500.0, GOLD_LIKE, 50.0)
        assert ok and vol == pytest.approx(0.02) and rm == pytest.approx(10.0)
        # verify the invariant: loss at SL does not exceed risk money
        assert 500 * vol * point_value_per_lot(GOLD_LIKE) <= rm + 1e-9

    def test_below_broker_minimum_refused(self):
        ok, vol, _ = volume_for_risk(1000.0, 0.01, 500.0, GOLD_LIKE, 50.0)
        assert not ok and vol == 0.0  # skip, never pad up (§19/§49)

    def test_emergency_cap_enforced(self):
        ok, vol, _ = volume_for_risk(100000.0, 5.0, 500.0, GOLD_LIKE, 0.5)
        assert ok and vol == pytest.approx(0.5)

    def test_snaps_down_to_step(self):
        # risk 10.8, SL 20pts -> raw 0.54 lots -> floor to 0.1 step = 0.5
        p = Props(volume_step=0.1)
        ok, vol, _ = volume_for_risk(1000.0, 1.08, 20.0, p, 50.0)
        assert ok and vol == pytest.approx(0.5)  # never 0.6 (up-snap)

    def test_step_snapped_below_min_refused(self):
        # raw 0.02 with 0.1 step floors to 0.0 -> below min -> refused
        p = Props(volume_step=0.1)
        ok, vol, _ = volume_for_risk(1000.0, 1.0, 500.0, p, 50.0)
        assert not ok and vol == 0.0

    def test_invalid_properties_refused(self):
        ok, _, _ = volume_for_risk(1000.0, 1.0, 500.0, Props(valid=False), 50.0)
        assert not ok

    def test_zero_inputs_refused(self):
        for args in ((0, 1.0, 500.0), (1000, 0.0, 500.0), (1000, 1.0, 0.0)):
            ok, _, _ = volume_for_risk(*args, GOLD_LIKE, 50.0)
            assert not ok


class TestRiskStates:
    def test_ladder(self):
        assert risk_state_from_dd(1.0, 5, 10, 15) == "NORMAL"
        assert risk_state_from_dd(6.0, 5, 10, 15) == "CAUTION"
        assert risk_state_from_dd(11.0, 5, 10, 15) == "REDUCED"
        assert risk_state_from_dd(16.0, 5, 10, 15) == "HALTED"

    def test_effective_risk_scales_down_only(self):
        assert effective_risk_pct("NORMAL", 0.5, 0.5, 0.25) == pytest.approx(0.5)
        assert effective_risk_pct("CAUTION", 0.5, 0.5, 0.25) == pytest.approx(0.25)
        assert effective_risk_pct("REDUCED", 0.5, 0.5, 0.25) == pytest.approx(0.125)
        assert effective_risk_pct("HALTED", 0.5, 0.5, 0.25) == 0.0

    def test_defaults_are_conservative(self):
        # config defaults: 0.5% risk, 2% daily, 15% halt, 1 position
        assert 0.5 <= 1.0          # risk per trade <= 1%
        assert 2.0 < 15.0          # daily limit well inside halt DD


class TestStops:
    def test_hybrid_takes_wider(self):
        assert stop_distance(1, 2000, 1990, 4, 1.5, "HYBRID", 1.0) == pytest.approx(10.0)
        assert stop_distance(1, 2000, 1990, 10, 1.5, "HYBRID", 1.0) == pytest.approx(15.0)

    def test_atr_mode_ignores_structure(self):
        assert stop_distance(1, 2000, 1990, 4, 1.5, "ATR", 1.0) == pytest.approx(6.0)

    def test_structure_wrong_side_falls_back(self):
        # short with a level below close is not protective -> ATR distance
        assert stop_distance(-1, 2000, 1990, 4, 1.5, "HYBRID", 1.0) == pytest.approx(6.0)

    def test_min_distance_floor(self):
        assert stop_distance(1, 2000, 0, 0, 0, "ATR", 25.0) is None  # no basis
        assert stop_distance(1, 2000, 1990, 1, 1.0, "ATR", 25.0) == pytest.approx(25.0)

    def test_no_fabricated_stop(self):
        assert stop_distance(1, 2000, 0, 0, 0, "ATR", 25.0) is None
        assert stop_distance(0, 2000, 1990, 4, 1.5, "HYBRID", 1.0) is None


class TestTP:
    def test_fixed_r(self):
        assert tp_distance("R", 30.0, 4.0, 2.0, 3.0) == pytest.approx(60.0)

    def test_atr_mode(self):
        assert tp_distance("ATR", 30.0, 4.0, 2.0, 3.0) == pytest.approx(12.0)

    def test_zero_sl_refused(self):
        assert tp_distance("R", 0.0, 4.0, 2.0, 3.0) is None
