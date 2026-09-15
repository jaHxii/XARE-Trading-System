"""Hardening-pass contract tests (v0.17.0).

Python mirrors of the MQL5 SELF_TEST groups T16–T22 and the new pure
functions: adaptive-risk bounds, state encode/parse, Friday/weekend
predicate, health aggregation, stage ladder, profit-lock floor, regime-
strategy matrix, breakout strength banding, and min-lot risk (§7).
The authoritative logic is MQL5 (compile-gated); these pin the documented
behavior for regression.
"""
import json
import math

import pytest

FACTOR_MIN = 0.5


# --- mirrors -------------------------------------------------------------
def adaptive_risk_pct(base, quality, regime, volatility, health,
                      drawdown, performance, stage, factor_min=FACTOR_MIN):
    """Mirror of XareAdaptiveRiskPct: product of clamped factors, never > base."""
    if base <= 0:
        return 0.0
    lo = factor_min if factor_min > 0 else 0.0
    product = 1.0
    for f in (quality, regime, volatility, health, drawdown, performance, stage):
        if f <= 0:
            continue
        product *= max(lo, min(1.0, f))
    return min(base, base * product)


def stage_for_equity(equity, micro_max, growth_max, standard_max, defensive):
    if defensive:
        return "DEFENSIVE"
    if equity < micro_max:
        return "MICRO"
    if equity < growth_max:
        return "GROWTH"
    if equity < standard_max:
        return "STANDARD"
    return "SCALE"


def stage_risk_factor(stage, defensive_mult):
    if stage == "DEFENSIVE":
        return min(max(defensive_mult, 0.0), 1.0)
    return 1.0


def weekend_state(day_of_week, minute_of_day, friday_cutoff, sunday_open=0):
    if day_of_week == 5:
        return "FRIDAY_CUTOFF" if minute_of_day >= friday_cutoff else "NONE"
    if day_of_week == 6:
        return "WEEKEND"
    if day_of_week == 0 and sunday_open > 0 and minute_of_day < sunday_open:
        return "WEEKEND"
    return "NONE"


def health_aggregate(checks):
    """checks: list of (ok, reason). Empty -> UNKNOWN."""
    if not checks:
        return "UNKNOWN", ""
    fails = [r for ok, r in checks if not ok]
    return ("BLOCKED" if fails else "READY"), "; ".join(fails)


def lock_floor_value(init_equity, milestone_pct, floor_pct):
    if init_equity <= 0 or milestone_pct <= 0 or floor_pct <= 0:
        return 0.0
    gain = init_equity * (milestone_pct / 100.0)
    return init_equity + gain * (floor_pct / 100.0)


def setup_allowed_in_regime(setup, regime, health):
    untradeable = {"UNSAFE", "UNKNOWN", "HIGH_VOLATILITY", "LOW_VOLATILITY"}
    if regime in untradeable:
        return False
    if health in ("DEFENSIVE", "HALTED"):
        return setup in ("TREND_CONTINUATION", "TREND_PULLBACK",
                         "BREAKOUT", "BREAKOUT_RETEST")
    if setup == "RANGE_REVERSAL":
        return regime == "RANGE"
    return True


def breakout_strength(beyond_atr, strong_atr):
    if beyond_atr <= 0:
        return 0
    if strong_atr > 0 and beyond_atr >= strong_atr:
        return 2
    if beyond_atr >= 0.25:
        return 1
    return 0


def breakout_body_ok(open_, high, low, close, body_min_pct):
    rng = high - low
    if rng <= 0 or body_min_pct <= 0:
        return False
    return abs(close - open_) / rng * 100.0 >= body_min_pct


def min_lot_risk_pct(equity, sl_points, volume_min, point, tick_size, tick_value):
    """Mirror of XareMinLotRiskPct + XarePointValuePerLot."""
    if equity <= 0 or sl_points <= 0 or point <= 0 or tick_size <= 0 or tick_value <= 0:
        return 0.0
    point_value = tick_value * (point / tick_size)
    return volume_min * sl_points * point_value / equity * 100.0


def effective_risk_pct(state, base, mult_caution, mult_reduced, mult_defensive):
    return {
        "HALTED": 0.0,
        "DEFENSIVE": base * min(mult_defensive, 1.0),
        "REDUCED": base * min(mult_reduced, 1.0),
        "CAUTION": base * min(mult_caution, 1.0),
    }.get(state, base)


# --- T16: adaptive risk bounds -------------------------------------------
class TestAdaptiveRisk:
    def test_identity(self):
        assert adaptive_risk_pct(0.5, 1, 1, 1, 1, 1, 1, 1) == pytest.approx(0.5)

    def test_halving(self):
        assert adaptive_risk_pct(0.5, 0.5, 1, 1, 1, 1, 1, 1) == pytest.approx(0.25)

    def test_quarter(self):
        assert adaptive_risk_pct(0.5, 0.5, 0.5, 1, 1, 1, 1, 1) == pytest.approx(0.125)

    def test_floor_clamp(self):
        assert adaptive_risk_pct(0.5, 0.2, 1, 1, 1, 1, 1, 1) == pytest.approx(0.25)

    def test_never_amplifies(self):
        assert adaptive_risk_pct(0.5, 2.0, 1, 1, 1, 1, 1, 1) == pytest.approx(0.5)

    def test_na_factors_skipped(self):
        assert adaptive_risk_pct(0.5, 0, 0, 0, 0.5, 0, 0, 1.0) == pytest.approx(0.25)

    def test_zero_base(self):
        assert adaptive_risk_pct(0.0, 1, 1, 1, 1, 1, 1, 1) == 0.0

    def test_invariant_never_above_base(self):
        for q in (0.3, 0.5, 0.7, 1.0, 2.0):
            assert adaptive_risk_pct(0.5, q, 1, 1, 1, 1, 1, 1) <= 0.5 + 1e-12


# --- T17: state round-trip ------------------------------------------------
class TestStateRoundTrip:
    def test_json_round_trip(self):
        state = {
            "day_key": 20000, "trades_today": 2, "consec_losses": 1,
            "consec_losing_days": 1, "lock_floor": 105.5,
            "session_name": "LONDON", "friday_close_done": 1,
            "pos_ticket": 123456789, "pos_direction": 1,
            "pos_volume_initial": 0.08, "pos_entry_price": 2000.55,
            "pos_open_reason": 'reason with "quotes" and \\ slash',
            "pos_setup": 3, "pos_be_done": 1,
        }
        text = json.dumps(state)
        parsed = json.loads(text)
        for key, value in state.items():
            assert parsed[key] == value

    def test_corrupt_rejected(self):
        with pytest.raises(json.JSONDecodeError):
            json.loads('{"garbage": true')


# --- T18: Friday/weekend ---------------------------------------------------
class TestWeekend:
    def test_friday_before_cutoff(self):
        assert weekend_state(5, 1199, 1200) == "NONE"

    def test_friday_at_cutoff(self):
        assert weekend_state(5, 1200, 1200) == "FRIDAY_CUTOFF"

    def test_saturday(self):
        assert weekend_state(6, 600, 1200) == "WEEKEND"

    def test_sunday_no_floor(self):
        assert weekend_state(0, 100, 1200, 0) == "NONE"

    def test_wednesday(self):
        assert weekend_state(3, 500, 1200) == "NONE"


# --- T19: health aggregation ----------------------------------------------
class TestHealth:
    def test_all_pass_ready(self):
        verdict, why = health_aggregate([(True, "")] * 12)
        assert verdict == "READY" and why == ""

    def test_one_fail_blocked(self):
        verdict, why = health_aggregate(
            [(True, "")] * 3 + [(False, "BROKER: down")] + [(True, "")] * 8)
        assert verdict == "BLOCKED"
        assert "BROKER: down" in why

    def test_empty_unknown(self):
        verdict, _ = health_aggregate([])
        assert verdict == "UNKNOWN"


# --- T20: stages + lock -----------------------------------------------------
class TestStagesAndLock:
    def test_ladder(self):
        assert stage_for_equity(100, 500, 5000, 50000, False) == "MICRO"
        assert stage_for_equity(999, 500, 5000, 50000, False) == "GROWTH"
        assert stage_for_equity(5001, 500, 5000, 50000, False) == "STANDARD"
        assert stage_for_equity(60000, 500, 5000, 50000, False) == "SCALE"

    def test_defensive_overrides(self):
        assert stage_for_equity(60000, 500, 5000, 50000, True) == "DEFENSIVE"

    def test_factors(self):
        assert stage_risk_factor("DEFENSIVE", 0.5) == pytest.approx(0.5)
        assert stage_risk_factor("GROWTH", 0.5) == 1.0

    def test_lock_floor(self):
        assert lock_floor_value(100, 10, 50) == pytest.approx(105.0)

    def test_lock_off(self):
        assert lock_floor_value(100, 0, 50) == 0.0


# --- T21: regime-strategy matrix --------------------------------------------
class TestMatrix:
    def test_breakout_in_trend(self):
        assert setup_allowed_in_regime("BREAKOUT", "TREND_UP", "NORMAL")

    def test_range_reversal_not_in_trend(self):
        assert not setup_allowed_in_regime("RANGE_REVERSAL", "TREND_UP", "NORMAL")

    def test_unsafe_blocks_all(self):
        assert not setup_allowed_in_regime("BREAKOUT", "UNSAFE", "NORMAL")

    def test_defensive_bans_counter_trend(self):
        assert not setup_allowed_in_regime(
            "LIQUIDITY_SWEEP_REVERSAL", "RANGE", "DEFENSIVE")

    def test_defensive_allows_trend(self):
        assert setup_allowed_in_regime("TREND_PULLBACK", "TREND_UP", "DEFENSIVE")


# --- T22: breakout bands + min-lot risk --------------------------------------
class TestBreakoutAndMicro:
    def test_strength_bands(self):
        assert breakout_strength(0.05, 0.5) == 0
        assert breakout_strength(0.30, 0.5) == 1
        assert breakout_strength(0.60, 0.5) == 2
        assert breakout_strength(0.60, 0.0) == 1

    def test_body_criterion(self):
        assert breakout_body_ok(2000, 2006, 1999, 2005.5, 50.0)
        assert not breakout_body_ok(2000, 2006, 1999, 2003.0, 50.0)

    def test_min_lot_risk_real_profile(self):
        # XAUUSDm: point 0.001, tick 0.001/$0.10, min 0.01 lot.
        # SL 3000pt (3.000 price) -> 0.01*3000*0.10 = $3.00 = 6% of $50
        assert min_lot_risk_pct(50, 3000, 0.01, 0.001, 0.001, 0.10) == \
            pytest.approx(6.0)

    def test_effective_risk_ladder(self):
        assert effective_risk_pct("HALTED", 0.5, 0.5, 0.25, 0.5) == 0.0
        assert effective_risk_pct("DEFENSIVE", 0.5, 0.5, 0.25, 0.5) == \
            pytest.approx(0.25)
        assert effective_risk_pct("REDUCED", 0.5, 0.5, 0.25, 0.5) == \
            pytest.approx(0.125)
        assert effective_risk_pct("NORMAL", 0.5, 0.5, 0.25, 0.5) == \
            pytest.approx(0.5)
