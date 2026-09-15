"""Safety-engine contract tests (M12).

Python mirrors of the SafetyEngine gate priority, emergency latch, news
blackout windows, and the R-multiple exit classifier from PositionManager.
Authoritative logic is MQL5.
"""
from dataclasses import dataclass


@dataclass
class Ctx:
    """Mirror of SXareSafetyContext."""
    trading_enabled: bool = True
    halted: bool = False
    daily_breach: bool = False
    weekly_breach: bool = False
    cooldown_active: bool = False
    exec_fail_streak: bool = False
    spread_points: int = 150
    max_spread_points: int = 350
    abnormal_spread_points: int = 600
    news_clear: bool = True
    news_reason: str = ""
    quotes_ok: bool = True
    data_ok: bool = True
    symbol_trade_full: bool = True
    equity: float = 1000.0
    margin_ok: bool = True


class SafetyGate:
    """Mirror of CXareSafetyEngine::Go() check order + emergency latch."""

    def __init__(self):
        self.emergency = False
        self.emergency_reason = ""

    def arm_emergency(self, reason):
        if not self.emergency:
            self.emergency = True
            self.emergency_reason = reason

    def go(self, c):
        """Returns (go: bool, reason: str)."""
        if self.emergency:
            return False, "EMERGENCY"
        if not c.trading_enabled:
            return False, "TRADING_OFF"
        if c.halted:
            return False, "RISK_HALTED"
        if c.daily_breach:
            return False, "DAILY_LOSS"
        if c.weekly_breach:
            return False, "WEEKLY_LOSS"
        if c.cooldown_active:
            return False, "COOLDOWN_LOSSES"
        if c.exec_fail_streak:
            return False, "EXEC_FAILURE"
        if not c.data_ok:
            return False, "DATA_STALE"
        if not c.quotes_ok:
            return False, "NO_QUOTES"
        if not c.symbol_trade_full:
            return False, "SYMBOL_STATE"
        if c.equity <= 0:
            return False, "DATA_STALE"
        if not c.news_clear:
            return False, "NEWS"
        if c.spread_points < 0:
            return False, "SPREAD"
        if c.abnormal_spread_points > 0 and c.spread_points >= c.abnormal_spread_points:
            return False, "SPREAD_ABNORMAL"
        if c.max_spread_points > 0 and c.spread_points >= c.max_spread_points:
            return False, "SPREAD"
        if not c.margin_ok:
            return False, "MARGIN"
        return True, "NONE"


def classify_exit(direction, entry, sl, tp, exit_price):
    """Mirror of PositionManager::ClassifyExit (price-based)."""
    if direction > 0:
        if exit_price <= sl:
            return "HARD_SL"
        if exit_price >= tp:
            return "TP"
    elif direction < 0:
        if exit_price >= sl:
            return "HARD_SL"
        if exit_price <= tp:
            return "TP"
    return "NONE"


def in_blackout(now, event, before_min, after_min):
    """Mirror of XareInBlackout: inclusive window, guards on bad input."""
    if event <= 0 or before_min <= 0 or after_min <= 0:
        return False
    return event - before_min * 60 <= now <= event + after_min * 60


class TestGatePriority:
    def test_all_clear_is_go(self):
        go, reason = SafetyGate().go(Ctx())
        assert go and reason == "NONE"

    def test_emergency_outranks_everything(self):
        g = SafetyGate()
        g.arm_emergency("dd breach")
        go, reason = g.go(Ctx())          # every other check green
        assert not go and reason == "EMERGENCY"

    def test_trading_off_beats_halted_beats_daily(self):
        g = SafetyGate()
        go, reason = g.go(Ctx(trading_enabled=False, halted=True, daily_breach=True))
        assert reason == "TRADING_OFF"
        go, reason = g.go(Ctx(halted=True, daily_breach=True))
        assert reason == "RISK_HALTED"
        go, reason = g.go(Ctx(daily_breach=True))
        assert reason == "DAILY_LOSS"

    def test_weekly_and_cooldown(self):
        _, reason = SafetyGate().go(Ctx(weekly_breach=True))
        assert reason == "WEEKLY_LOSS"
        _, reason = SafetyGate().go(Ctx(cooldown_active=True))
        assert reason == "COOLDOWN_LOSSES"

    def test_data_and_quotes_before_spread(self):
        _, reason = SafetyGate().go(Ctx(data_ok=False))
        assert reason == "DATA_STALE"
        _, reason = SafetyGate().go(Ctx(quotes_ok=False))
        assert reason == "NO_QUOTES"

    def test_spread_normal_abnormal(self):
        _, reason = SafetyGate().go(Ctx(spread_points=400))
        assert reason == "SPREAD"
        _, reason = SafetyGate().go(Ctx(spread_points=700))
        assert reason == "SPREAD_ABNORMAL"

    def test_news_blocks_only_when_set(self):
        _, reason = SafetyGate().go(Ctx(news_clear=False, news_reason="FOMC"))
        assert reason == "NEWS"


class TestEmergencyLatch:
    def test_latch_is_sticky(self):
        g = SafetyGate()
        g.arm_emergency("x")
        g.arm_emergency("y")   # first reason wins; cannot silently re-arm
        assert g.emergency and g.emergency_reason == "x"


class TestNewsWindow:
    EVENT = 1767639000  # arbitrary epoch seconds

    def test_inclusive_edges(self):
        assert in_blackout(self.EVENT - 30 * 60, self.EVENT, 30, 30)
        assert in_blackout(self.EVENT + 30 * 60, self.EVENT, 30, 30)

    def test_outside_window(self):
        assert not in_blackout(self.EVENT - 31 * 60, self.EVENT, 30, 30)
        assert not in_blackout(self.EVENT + 31 * 60, self.EVENT, 30, 30)

    def test_bad_inputs_fail_safe_clear(self):
        assert not in_blackout(self.EVENT, 0, 30, 30)
        assert not in_blackout(self.EVENT, self.EVENT, 0, 30)


class TestExitClassifier:
    def test_long_sl_and_tp(self):
        assert classify_exit(1, 2000, 1994, 2012, 1994.0) == "HARD_SL"
        assert classify_exit(1, 2000, 1994, 2012, 2012.0) == "TP"

    def test_short_sl_and_tp(self):
        assert classify_exit(-1, 2000, 2006, 1988, 2006.0) == "HARD_SL"
        assert classify_exit(-1, 2000, 2006, 1988, 1988.0) == "TP"

    def test_unknown_close_reports_none(self):
        assert classify_exit(1, 2000, 1994, 2012, 2003.0) == "NONE"
