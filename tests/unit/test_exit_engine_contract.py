"""Exit-engine contract tests (M11).

Python mirrors of the pure management decisions in ExitEngine.mqh:
break-even, trailing, partial, time exit, regime flip, signal reversal,
and the tighten-only stop policy. Authoritative logic is MQL5.
"""
import pytest
from dataclasses import dataclass, field


@dataclass
class Pos:
    """Numeric mirror of SXarePosition for exit decisions."""
    direction: int = 1
    entry_price: float = 2000.0
    sl_price: float = 1994.0          # 6.00 risk dist
    tp_price: float = 2012.0
    volume_initial: float = 0.08
    bars_in_trade: int = 0
    be_done: bool = False
    partial_done: bool = False
    open_time: int = 0


CFG_BE_TRIGGER_R = 1.0
CFG_BE_LOCK_PTS = 50               # points -> 0.50 px at point 0.01
CFG_TRAIL_TRIGGER_R = 1.0
CFG_TRAIL_ATR_MULT = 2.0
CFG_PARTIAL_TRIGGER_R = 1.5
CFG_PARTIAL_PCT = 50.0


def should_break_even(pos, price, point=0.01):
    if pos.be_done or pos.direction == 0 or point <= 0:
        return None
    profit = (price - pos.entry_price) if pos.direction > 0 else (pos.entry_price - price)
    trigger = CFG_BE_TRIGGER_R * abs(pos.entry_price - pos.sl_price)
    if trigger <= 0 or profit < trigger:
        return None
    lock = CFG_BE_LOCK_PTS * point
    new_sl = pos.entry_price + lock if pos.direction > 0 else pos.entry_price - lock
    tightens = (pos.sl_price < new_sl) if pos.direction > 0 else (pos.sl_price > new_sl or pos.sl_price == 0.0)
    return new_sl if tightens else None


def should_trail(pos, price, atr):
    if pos.direction == 0 or atr <= 0:
        return None
    profit = (price - pos.entry_price) if pos.direction > 0 else (pos.entry_price - price)
    trigger = CFG_TRAIL_TRIGGER_R * abs(pos.entry_price - pos.sl_price)
    if profit < trigger:
        return None
    dist = atr * CFG_TRAIL_ATR_MULT
    new_sl = price - dist if pos.direction > 0 else price + dist
    tightens = (new_sl > pos.sl_price) if pos.direction > 0 else (new_sl < pos.sl_price or pos.sl_price == 0.0)
    return new_sl if tightens else None


def should_partial(pos, price):
    if pos.partial_done or pos.direction == 0:
        return None
    profit = (price - pos.entry_price) if pos.direction > 0 else (pos.entry_price - price)
    trigger = CFG_PARTIAL_TRIGGER_R * abs(pos.entry_price - pos.sl_price)
    if trigger <= 0 or profit < trigger:
        return None
    return pos.volume_initial * CFG_PARTIAL_PCT / 100.0


def should_time_exit(pos, max_bars, max_minutes=0, now=0):
    if pos.direction == 0:
        return False
    if max_bars > 0 and pos.bars_in_trade >= max_bars:
        return True
    if max_minutes > 0 and pos.open_time > 0 and (now - pos.open_time) // 60 >= max_minutes:
        return True
    return False


def should_regime_exit(pos, regime):
    if pos.direction == 0 or regime == "UNKNOWN":
        return False
    return ((pos.direction > 0 and regime == "TREND_DOWN") or
            (pos.direction < 0 and regime == "TREND_UP"))


def should_reversal_exit(pos, new_dir):
    if pos.direction == 0 or new_dir == 0:
        return False
    return new_dir != pos.direction


class TestBreakEven:
    def test_triggers_at_1r(self):
        # 1R = 6.00 -> price 2006.00; BE lock 50pt = 0.50 above entry
        assert should_break_even(Pos(), 2006.0) == 2000.50

    def test_not_before_trigger(self):
        assert should_break_even(Pos(), 2005.99) is None

    def test_one_shot_only(self):
        p = Pos(be_done=True)
        assert should_break_even(p, 2010.0) is None

    def test_never_loosens_stop(self):
        # SL already beyond the BE level ( trailed past) -> no backward move
        p = Pos(sl_price=2001.0)
        assert should_break_even(p, 2010.0) is None

    def test_short_mirror(self):
        p = Pos(direction=-1, entry_price=2000.0, sl_price=2006.0)
        assert should_break_even(p, 1994.0) == 1999.50


class TestTrailing:
    def test_trails_at_2xatr_after_trigger(self):
        # trigger 1R=6 -> price 2006; ATR 2 -> dist 4.00 -> SL 2002.00
        assert should_trail(Pos(), 2006.0, 2.0) == 2002.0

    def test_tighten_only(self):
        # price fell back; trail SL would be below current SL -> no move
        assert should_trail(Pos(), 2005.0, 0.1) is None

    def test_ratchets_upward(self):
        p = Pos(sl_price=2002.0)
        assert should_trail(p, 2010.0, 2.0) == pytest.approx(2006.0)

    def test_not_before_trigger(self):
        assert should_trail(Pos(), 2004.0, 2.0) is None


class TestPartial:
    def test_half_at_1_5r(self):
        # 1.5R = 9.00 -> price 2009; half of 0.08 = 0.04
        assert should_partial(Pos(), 2009.0) == 0.04

    def test_not_before_trigger(self):
        assert should_partial(Pos(), 2008.99) is None

    def test_one_shot_only(self):
        assert should_partial(Pos(partial_done=True), 2020.0) is None


class TestHardExits:
    def test_time_exit_at_max_bars(self):
        assert should_time_exit(Pos(bars_in_trade=48), max_bars=48)
        assert not should_time_exit(Pos(bars_in_trade=47), max_bars=48)

    def test_time_exit_never_fires_when_disabled(self):
        assert not should_time_exit(Pos(bars_in_trade=1000), max_bars=0)

    def test_regime_flip_exit(self):
        assert should_regime_exit(Pos(direction=1), "TREND_DOWN")
        assert should_regime_exit(Pos(direction=-1), "TREND_UP")
        assert not should_regime_exit(Pos(direction=1), "TREND_UP")
        assert not should_regime_exit(Pos(direction=1), "RANGE")
        assert not should_regime_exit(Pos(direction=1), "UNKNOWN")

    def test_reversal_exit(self):
        assert should_reversal_exit(Pos(direction=1), -1)
        assert should_reversal_exit(Pos(direction=-1), 1)
        assert not should_reversal_exit(Pos(direction=1), 1)
        assert not should_reversal_exit(Pos(direction=1), 0)
